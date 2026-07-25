# Three-way repair cascade, with and without a concurrent delete
# (sec:formal-intention, theo:nonint, lem:no-resurrection).
#
# Run from `Code/` as:
#
#     mix run --no-start scripts/cascade_smoke.exs
#
# Phase A, the cascade. Three peers author overlapping edit blocks concurrently into the same
# parent interval, so BOTH lower-priority writers must re-place, and a move can land next to a
# block its writer has not seen yet. The phase asserts what the repair protocol guarantees:
# every replica converges byte for byte, each writer's block is contiguous at quiescence, every
# line settles, and no content is duplicated. This is the workload the rank induction of
# sec:interleavings bounds.
#
# Phase B, the delete race. The same three blocks, plus a delete aimed at a line of the
# lowest-priority block while the moves are in flight. The phase asserts convergence, that the
# deleted content is absent at every replica whichever order the delete and the moves arrived
# in, that no replica ever held two live copies of moved content, and that the repair reached a
# fixpoint. It deliberately does NOT assert contiguity: a delete inside a block splits that
# block's live remnant, and the remnant is anchored on the deleted line, so it no longer shares
# an authored interval with the block it overlaps and detection leaves it alone. That is the
# stated incompleteness of the same-interval rule (see Syncordian.Interleaving and
# sec:interleavings); the phase reports it rather than hiding it.
#
# Concurrency is forced by widening the broadcast delay so each peer authors its whole block
# before the others' inserts arrive.

alias Syncordian.Peer
require Syncordian.Metadata

File.mkdir_p!("debug/documents/syncordian")
Application.put_env(:syncordian, :broadcast_delay, 300..300)

network_size = 3
block_size = 4
prefixes = %{0 => "apple", 1 => "berry", 2 => "cherry"}

contents =
  Map.new(prefixes, fn {id, prefix} -> {id, for(i <- 1..block_size, do: "#{prefix}-#{i}")} end)

read_document = fn pid ->
  send(pid, {:request_live_view_document, self()})

  receive do
    {:receive_live_view_document, document, _handler} -> document
  after
    3_000 -> []
  end
end

live_lines = fn document ->
  Enum.filter(document, fn line ->
    Syncordian.Line_Object.get_line_status(line) != :tombstone and
      not Syncordian.PathId.sentinel?(Syncordian.Line_Object.get_line_id(line))
  end)
end

collect_metadata = fn pids ->
  :global.register_name(:supervisor, self())

  metadata =
    Map.new(pids, fn {id, pid} ->
      send(pid, {:register_supervisor_pid})
      Process.sleep(50)
      send(pid, {:supervisor_request_metadata})

      receive do
        {:receive_metadata_from_peer, record, _pid} ->
          {id, record |> Syncordian.Metadata.metadata() |> Enum.into(%{})}
      after
        3_000 -> {id, %{}}
      end
    end)

  :global.unregister_name(:supervisor)
  metadata
end

# Authors the three blocks concurrently and returns the peer pids by id. The index is i + 1
# because a local edit lands before the live position it names, counting the infimum as 0 (see
# scripts/interleaving_smoke.exs), so this appends and each block is ONE authored chain.
author_blocks = fn ->
  pids = Map.new([0, 1, 2], fn id -> {id, Peer.start(id, network_size)} end)
  Process.sleep(200)

  Enum.each([0, 1, 2], fn id ->
    contents
    |> Map.fetch!(id)
    |> Enum.with_index()
    |> Enum.each(fn {content, i} -> Peer.insert(Map.fetch!(pids, id), content, 0, i + 1, 0, 0) end)
  end)

  pids
end

teardown = fn pids ->
  Enum.each(pids, fn {id, pid} ->
    Process.exit(pid, :kill)
    :global.unregister_name(id)
  end)

  Process.sleep(200)
end

report = fn label, ok? ->
  IO.puts("#{String.pad_trailing(label, 32)}: #{ok?}")
  ok?
end

# --- phase A: the cascade ----------------------------------------------------------------

IO.puts("\n=== phase A: three-way cascade ===")
IO.puts("Concurrently authoring three #{block_size}-line blocks in the same interval…")
pids_a = author_blocks.()
IO.puts("Settling network (cascade + convergence)…")
Process.sleep(10_000)

docs_a = Map.new(pids_a, fn {id, pid} -> {id, read_document.(pid)} end)

content_a =
  Map.new(docs_a, fn {id, doc} ->
    {id, doc |> live_lines.() |> Enum.map(&Syncordian.Line_Object.get_content/1)}
  end)

reference_a = Map.fetch!(content_a, 0)
IO.puts("\n--- converged document ---")
Enum.each(reference_a, &IO.puts/1)

runs_a = reference_a |> Enum.map(&(&1 |> String.split("-") |> hd())) |> Enum.dedup()

statuses_a =
  docs_a
  |> Enum.flat_map(fn {_id, doc} -> live_lines.(doc) end)
  |> Enum.map(&Syncordian.Line_Object.get_line_status/1)
  |> Enum.uniq()

metadata_a = collect_metadata.(pids_a)

IO.puts("\n--- per-peer repair metadata ---")

Enum.each([0, 1, 2], fn id ->
  m = Map.fetch!(metadata_a, id)

  IO.puts(
    "peer #{id}: conflicts=#{m[:conflict_detected_counter]} " <>
      "reissued=#{m[:replacement_issued_counter]} aliases=#{m[:alias_entries]} " <>
      "live_duplicates_max=#{m[:live_duplicates_max]}"
  )
end)

IO.puts("")

a_ok =
  [
    report.("convergent across 3 peers", Enum.all?(content_a, fn {_id, c} -> c == reference_a end)),
    report.("per-writer contiguity", length(runs_a) == length(Enum.uniq(runs_a))),
    report.(
      "all lines present",
      Enum.sort(reference_a) == contents |> Map.values() |> List.flatten() |> Enum.sort()
    ),
    report.("every live line settled", statuses_a == [:settled]),
    report.("no duplicated content", length(Enum.uniq(reference_a)) == length(reference_a)),
    report.(
      "no repair pending",
      Syncordian.Interleaving.detect_replacements(Map.fetch!(docs_a, 0)) == []
    ),
    report.(
      "live_duplicates_max == 0",
      Enum.all?([0, 1, 2], fn id -> Map.fetch!(metadata_a, id)[:live_duplicates_max] == 0 end)
    )
  ]
  |> Enum.all?()

IO.puts("phase A: #{if a_ok, do: "PASS ✅", else: "FAIL ❌"}  (block runs: #{inspect(runs_a)})")
teardown.(pids_a)

# --- phase B: a delete racing the moves ---------------------------------------------------

IO.puts("\n=== phase B: delete racing the re-placement ===")
deleted = "cherry-2"
pids_b = author_blocks.()

# Peer 2 holds the lowest-priority block, so its block is the one the priority rule moves.
# Deleting its own second line while its inserts are still in flight puts the delete and the
# re-placement of that very content in flight together.
IO.puts("Deleting #{deleted} concurrently with the re-placement…")
Peer.delete_line(Map.fetch!(pids_b, 2), 2, 2, 0, 0)

IO.puts("Settling network…")
Process.sleep(10_000)

docs_b = Map.new(pids_b, fn {id, pid} -> {id, read_document.(pid)} end)

content_b =
  Map.new(docs_b, fn {id, doc} ->
    {id, doc |> live_lines.() |> Enum.map(&Syncordian.Line_Object.get_content/1)}
  end)

reference_b = Map.fetch!(content_b, 0)
IO.puts("\n--- converged document ---")
Enum.each(reference_b, &IO.puts/1)

statuses_b =
  docs_b
  |> Enum.flat_map(fn {_id, doc} -> live_lines.(doc) end)
  |> Enum.map(&Syncordian.Line_Object.get_line_status/1)
  |> Enum.uniq()

expected_b = contents |> Map.values() |> List.flatten() |> Enum.reject(&(&1 == deleted))
metadata_b = collect_metadata.(pids_b)

IO.puts("\n--- per-peer repair metadata ---")

Enum.each([0, 1, 2], fn id ->
  m = Map.fetch!(metadata_b, id)

  IO.puts(
    "peer #{id}: conflicts=#{m[:conflict_detected_counter]} " <>
      "reissued=#{m[:replacement_issued_counter]} aliases=#{m[:alias_entries]} " <>
      "delete_followed_alias=#{m[:delete_followed_alias]} " <>
      "reissue_superseded_deleted=#{m[:reissue_superseded_deleted]} " <>
      "live_duplicates_max=#{m[:live_duplicates_max]}"
  )
end)

runs_b = reference_b |> Enum.map(&(&1 |> String.split("-") |> hd())) |> Enum.dedup()
IO.puts("")

b_ok =
  [
    report.("convergent across 3 peers", Enum.all?(content_b, fn {_id, c} -> c == reference_b end)),
    report.("deleted content absent", Enum.all?(content_b, fn {_id, c} -> deleted not in c end)),
    report.("all other lines present", Enum.sort(reference_b) == Enum.sort(expected_b)),
    report.("every live line settled", statuses_b == [:settled]),
    report.("no duplicated content", length(Enum.uniq(reference_b)) == length(reference_b)),
    report.(
      "no repair pending",
      Syncordian.Interleaving.detect_replacements(Map.fetch!(docs_b, 0)) == []
    ),
    report.(
      "live_duplicates_max == 0",
      Enum.all?([0, 1, 2], fn id -> Map.fetch!(metadata_b, id)[:live_duplicates_max] == 0 end)
    )
  ]
  |> Enum.all?()

# Reported, not asserted: the delete splits the moving block, and the remnant is anchored on
# the deleted line, so the same-interval rule no longer pairs it with the block it overlaps.
IO.puts(
  "per-writer contiguity (reported)  : #{length(runs_b) == length(Enum.uniq(runs_b))}" <>
    "  (block runs: #{inspect(runs_b)})"
)

IO.puts("phase B: #{if b_ok, do: "PASS ✅", else: "FAIL ❌"}")
teardown.(pids_b)

IO.puts("\n================ RESULT ================")

if a_ok and b_ok do
  IO.puts("PASS ✅  cascade repaired; deleted content stayed deleted; replicas converged")
else
  IO.puts("FAIL ❌")
  System.halt(1)
end
