# Three-peer convergence smoke for the PathId migration.
#
# Spawns three Syncordian peers, exchanges a handful of inserts and a delete,
# waits for the broadcast loop to settle, and dumps each peer's document to disk.
# Used as the end-of-session smoke for the A1 + A2 (vector-clock + PathId) work.
#
# Run from `code/` as:
#
#     mix run scripts/three_peer_smoke.exs
#
# After it completes, run:
#
#     diff debug/documents/syncordian/document_peer_0 debug/documents/syncordian/document_peer_1
#     diff debug/documents/syncordian/document_peer_0 debug/documents/syncordian/document_peer_2
#
# Both diffs should be empty.

alias Syncordian.Peer

# Make sure the output directory exists; save_content writes into it directly.
File.mkdir_p!("debug/documents/syncordian")

network_size = 3
peer_ids = [0, 1, 2]

IO.puts("Starting #{network_size} Syncordian peers…")

peers =
  Enum.map(peer_ids, fn id ->
    pid = Peer.start(id, network_size)
    {id, pid}
  end)

# Give the peers a moment to register the (absent) supervisor and complete init.
Process.sleep(200)

# Helper: send an insert, then wait briefly so the broadcast can fan out.
insert = fn {_id, pid}, content, git_index ->
  Peer.insert(pid, content, 0, git_index, 0, 0)
  Process.sleep(400)
end

delete = fn {_id, pid}, git_index ->
  Peer.delete_line(pid, 0, git_index, 0, 0)
  Process.sleep(400)
end

[p0, p1, p2] = peers

IO.puts("Issuing edits…")
insert.(p0, "alpha from peer 0", 0)
insert.(p1, "beta from peer 1", 1)
insert.(p2, "gamma from peer 2", 2)
insert.(p0, "delta from peer 0", 1)
insert.(p1, "epsilon from peer 1", 0)
delete.(p2, 2)
insert.(p0, "zeta from peer 0", 3)

# Settle.
IO.puts("Settling network for 3s…")
Process.sleep(3_000)

IO.puts("Saving per-peer documents…")
Enum.each(peers, fn {_id, pid} -> Peer.save_content(pid) end)
Process.sleep(500)

IO.puts("Done. Compare with: diff debug/documents/syncordian/document_peer_0 debug/documents/syncordian/document_peer_{1,2}")
