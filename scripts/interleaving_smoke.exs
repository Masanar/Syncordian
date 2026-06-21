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
#     ASDF_ELIXIR_VERSION=1.18.4-otp-28 ASDF_ERLANG_VERSION=28.5 mix run --no-start scripts/interleaving_smoke.exs

alias Syncordian.Peer

File.mkdir_p!("debug/documents/syncordian")
File.mkdir_p!("debug/documents/syncordian/raw")

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

# Each peer appends its block (git index = current block length) so the lines form one
# authored chain anchored between the sentinels. Both command streams are queued before the
# 300 ms broadcast delay elapses, so neither peer has seen the other when it authors.
apples
|> Enum.with_index()
|> Enum.each(fn {content, i} -> Peer.insert(p0, content, 0, i, 0, 0) end)

berries
|> Enum.with_index()
|> Enum.each(fn {content, i} -> Peer.insert(p1, content, 0, i, 0, 0) end)

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

IO.puts("\n================ RESULT ================")
IO.puts("convergent (peer_0 == peer_1) : #{converged?}")
IO.puts("all 8 lines present           : #{all_present?}")
IO.puts("per-author contiguity         : #{contiguous?}  (block runs: #{inspect(runs)})")

if converged? and contiguous? and all_present? do
  IO.puts("PASS ✅  no interleaving remains; documents converged")
else
  IO.puts("FAIL ❌")
  System.halt(1)
end
