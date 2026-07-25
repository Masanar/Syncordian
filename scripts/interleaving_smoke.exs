# Interleaving re-placement smoke (sec:formal-intention, theo:nonint).
#
# Forces two peers to author overlapping edit blocks *concurrently* into the same parent
# interval — the interleaving anomaly Syncordian must resolve — and checks that the network
# (1) converges byte-for-byte and (2) leaves each author's block contiguous (no line of one
# block left between two lines of the other).
#
# Concurrency is forced by widening the broadcast delay so each peer authors its whole block
# before the other's inserts arrive; the lower-priority writer (greater peer id) then
# re-issues its block into a disjoint sub-interval.
#
# Run from `code/` as:
#
#     mix run --no-start scripts/interleaving_smoke.exs

require Syncordian.Metadata
alias Syncordian.Peer

File.mkdir_p!("debug/documents/syncordian")
File.mkdir_p!("debug/documents/syncordian/raw")

# This is the only driver in the tree that reliably produces a real interleaving, so it is
# also where the instrumentation of transient interleaving and repair is checked. The git
# replays serialize authoring behind a per-commit barrier, so two writers there never
# allocate into the same empty interval and every conflict counter stays at zero: a run that
# reports no interleaving is describing its workload, not the repair protocol.
Syncordian.OpTimes.create()

# Delay cross-peer broadcasts so both peers author their full blocks concurrently, before
# either sees the other. Re-placement traffic issued afterwards rides the same delay and
# still settles within the wait below.
Application.put_env(:syncordian, :broadcast_delay, 300..300)

network_size = 2
[p0, p1] = Enum.map([0, 1], fn id -> Peer.start(id, network_size) end)
Process.sleep(200)

block_size = 4
apples = for i <- 1..block_size, do: "apple-#{i}"
berries = for i <- 1..block_size, do: "berry-#{i}"

IO.puts("Concurrently authoring two #{block_size}-line blocks in the same interval…")

# Each peer appends its block so the lines form ONE authored chain (each line naming the
# previous as its left parent) anchored between the sentinels. Both command streams are
# queued before the 300 ms broadcast delay elapses, so neither peer has seen the other when
# it authors.
#
# The index is `i + 1`, not `i`: a local edit lands BEFORE the live position it names,
# counting the infimum as position 0, so appending the i-th line of a block means naming
# position i + 1. Passing `i` instead inserts every line before the previous one, which
# anchors the chain on the writer's own first line rather than on the document bound. Two
# writers doing that produce blocks in *different* authored intervals, which the detector
# leaves alone by its same-interval rule, so the run exercised no re-placement at all and
# passed or failed with the random position digits.
apples
|> Enum.with_index()
|> Enum.each(fn {content, i} -> Peer.insert(p0, content, 0, i + 1, 0, 0) end)

berries
|> Enum.with_index()
|> Enum.each(fn {content, i} -> Peer.insert(p1, content, 0, i + 1, 0, 0) end)

IO.puts("Settling network (re-placement + convergence)…")
Process.sleep(6_000)

# Dump filtered documents (the materialized text) and raw documents (with statuses, so
# re-placement tombstones are visible).
Enum.each([p0, p1], fn pid -> Peer.save_content(pid) end)
# Raw dump of peer 0 (statuses included) so re-placement tombstones are observable.
send(p0, {:write_raw_document})
Process.sleep(500)

doc0 = File.read!("debug/documents/syncordian/document_peer_0")
doc1 = File.read!("debug/documents/syncordian/document_peer_1")

raw0 = File.read!("debug/documents/syncordian/raw/document")
tombstones = raw0 |> String.split(":tombstone") |> length() |> Kernel.-(1)
IO.puts("re-placement tombstones in peer 0 raw doc: #{tombstones}")

IO.puts("\n--- peer 0 document ---\n" <> doc0)
IO.puts("--- peer 1 document ---\n" <> doc1)

converged? = doc0 == doc1

lines = doc0 |> String.split("\n", trim: true)

# Contiguity: each author's lines (apple-* / berry-*) must form a single consecutive run.
runs =
  lines
  |> Enum.map(fn l -> if String.starts_with?(l, "apple"), do: :a, else: :b end)
  |> Enum.dedup()

contiguous? = length(runs) <= 2 and length(Enum.uniq(runs)) == length(runs)
all_present? = Enum.sort(lines) == Enum.sort(apples ++ berries)

# Collect what each peer measured, and merge into the network-wide view the supervisor would
# report. Every peer answers with its own record, so a field that only one replica can see
# (the mover's repair counters, the observer's conflict gauges) is still present in the sum.
metadata =
  Enum.reduce([p0, p1], Syncordian.Metadata.metadata(), fn pid, acc ->
    send(pid, {:request_metadata, self()})

    receive do
      {:receive_metadata_from_peer, peer_metadata, _pid} ->
        Syncordian.Metadata.merge_metadata(acc, peer_metadata)
    after
      2_000 -> acc
    end
  end)

measured = Syncordian.Metadata.to_map(metadata)
latency = Syncordian.OpTimes.samples()

mean = fn
  [] -> nil
  values -> Float.round(Enum.sum(values) / length(values), 2)
end

IO.puts("\n=============== MEASURED ===============")

IO.puts(
  "interleavings observed        : #{measured["conflicts_observed"]} " <>
    "(most held at once: #{measured["max_concurrent_conflicts"]}, " <>
    "unresolved now: #{measured["concurrent_conflicts"]})"
)

IO.puts(
  "repairs completed             : #{length(measured["repair_latency_edits"])} " <>
    "(mean #{inspect(mean.(measured["repair_latency_edits"]))} edits, " <>
    "#{inspect(mean.(measured["repair_latency_ms"]))} ms)"
)

IO.puts(
  "lines re-issued per repair    : #{inspect(measured["reissued_lines_per_conflict"])} " <>
    "(live duplicates: #{measured["live_duplicates_max"]})"
)

IO.puts(
  "wire bytes by kind            : insert #{measured["bytes_insert"]}/#{measured["msgs_insert"]} msg, " <>
    "delete #{measured["bytes_delete"]}/#{measured["msgs_delete"]} msg, " <>
    "ack #{measured["bytes_ack"]}/#{measured["msgs_ack"]} msg"
)

IO.puts(
  "authenticator calls           : doc #{measured["mac_calls_doc"]}, ins #{measured["mac_calls_ins"]}, " <>
    "del #{measured["mac_calls_del"]}, ack #{measured["mac_calls_ack"]}, " <>
    "adm #{measured["mac_calls_adm"]} (#{measured["mac_sampled_calls"]} timed)"
)

IO.puts(
  "position depth               : max #{measured["pid_depth_max"]} over " <>
    "#{measured["pid_depth_lines"]} lines"
)

IO.puts(
  "operation latency            : #{latency.operations} issued, " <>
    "#{latency.applies} applies (mean #{inspect(mean.(latency.apply_latency_us))} us), " <>
    "#{latency.settles} settles (mean #{inspect(mean.(latency.settle_latency_us))} us)"
)

# The instrumentation is only worth reporting if it actually fired. This smoke forces one
# interleaving, so a run that measures none has lost the measurement, not the anomaly.
measured_interleaving? =
  measured["conflicts_observed"] > 0 and measured["repair_latency_edits"] != [] and
    measured["reissued_lines_per_conflict"] != []

measured_cost? =
  measured["bytes_insert"] > 0 and measured["bytes_ack"] > 0 and
    measured["mac_calls_ins"] > 0 and measured["pid_depth_max"] > 0 and
    latency.applies > 0

IO.puts("\n================ RESULT ================")
IO.puts("convergent (peer_0 == peer_1) : #{converged?}")
IO.puts("all 8 lines present           : #{all_present?}")
IO.puts("per-author contiguity         : #{contiguous?}  (block runs: #{inspect(runs)})")
IO.puts("interleaving instrumented     : #{measured_interleaving?}")
IO.puts("cost instrumented             : #{measured_cost?}")

if converged? and contiguous? and all_present? and measured_interleaving? and measured_cost? do
  IO.puts("PASS ✅  no interleaving remains; documents converged; metrics recorded")
else
  IO.puts("FAIL ❌")
  System.halt(1)
end
