# Headless run of the paper's full Syncordian evaluation.
#
# Drives the same `Syncordian.Supervisor` the `/supervisor` LiveView normally drives,
# replays the entire 71-commit OhMyZsh README git log across 30 author peers and
# 0 Byzantine peers (mirroring the default LiveView selection), then writes each
# peer's materialized document to `debug/documents/syncordian/document_peer_N`.
#
# Run from `code/` as:
#
#     ASDF_ELIXIR_VERSION=1.18.4-otp-28 ASDF_ERLANG_VERSION=28.5 \
#       mix run --no-start scripts/run_full_experiment.exs
#
# Approximate wall time: ~3 min (71 commits × ~2s dispatch + settle time).
# After it completes, the script invokes scripts/identical.sh, which exits 0
# iff every dumped peer document is byte-identical.

defmodule FullExperiment do
  def run do
    out_dir = "debug/documents/syncordian"
    IO.puts("Cleaning #{out_dir}/document_peer_* …")
    File.mkdir_p!(out_dir)

    Path.wildcard(Path.join(out_dir, "document_peer_*"))
    |> Enum.each(&File.rm!/1)

    IO.puts("Initializing supervisor with crdt=:syncordian, byzantine=0 …")
    sup_pid = Syncordian.Supervisor.init(0, :syncordian)
    IO.puts("Supervisor pid: #{inspect(sup_pid)}")

    # Give peers a moment to fully register with :global and bind to the supervisor.
    Process.sleep(500)

    IO.puts("Sending {:send_all_commits, self, 0} — replaying full git log…")
    send(sup_pid, {:send_all_commits, self(), 0})

    # The supervisor sends {:limit_reached, _} to live_view_pid (= self()) when done.
    # It also queues a {:write_current_peers_document} to itself at completion.
    wait_for_limit_reached()

    # After {:limit_reached}, the supervisor self-sends {:write_current_peers_document},
    # which fans out save_content/1 to all peers. Allow time for: (a) any in-flight
    # broadcasts from the last commit to settle into stash/document, (b) save_content
    # to actually write each file.
    settle_ms = 30_000
    IO.puts("Settling network for #{div(settle_ms, 1000)}s before reading dumps…")
    Process.sleep(settle_ms)

    # Re-issue the dump explicitly in case some peers missed the supervisor's self-send
    # because they were still processing broadcasts at that moment.
    IO.puts("Re-issuing {:write_current_peers_document} as a belt-and-braces…")
    send(sup_pid, {:write_current_peers_document})
    Process.sleep(5_000)

    files = Path.wildcard(Path.join(out_dir, "document_peer_*")) |> Enum.sort()
    IO.puts("Dumped #{length(files)} peer documents:")
    Enum.each(files, &IO.puts("  #{&1}"))

    IO.puts("\nRunning scripts/identical.sh from code/ …")
    # identical.sh is written assuming CWD = code/scripts and FOLDER=../debug/documents,
    # so it walks debug/documents/* at the top level. To make it check the Syncordian
    # subtree specifically, we do the byte-equality check inline instead.
    verify_convergence(files)
  end

  defp wait_for_limit_reached do
    receive do
      {:limit_reached, msg} ->
        IO.puts(">>> Supervisor signalled limit_reached: #{inspect(msg)}")
        :ok

      _other ->
        # Drain any unrelated metadata-forwarding messages without action.
        wait_for_limit_reached()
    after
      # Generous timeout: 71 × 2s dispatch + per-commit broadcast settle. 10 min cap.
      600_000 ->
        raise "Timeout waiting for {:limit_reached, _} from supervisor"
    end
  end

  defp verify_convergence([]) do
    IO.puts("ERROR: no peer documents found")
    System.halt(2)
  end

  defp verify_convergence([single]) do
    IO.puts("Only one peer document (#{single}) — trivially identical.")
    System.halt(0)
  end

  defp verify_convergence([ref | rest]) do
    ref_bytes = File.read!(ref)
    ref_sha = :crypto.hash(:sha256, ref_bytes) |> Base.encode16(case: :lower)
    IO.puts("Reference: #{ref}  sha256=#{String.slice(ref_sha, 0, 12)}…  size=#{byte_size(ref_bytes)}")

    {ok, mismatches} =
      Enum.reduce(rest, {0, []}, fn path, {ok_count, bad} ->
        bytes = File.read!(path)

        if bytes == ref_bytes do
          {ok_count + 1, bad}
        else
          sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          {ok_count, [{path, sha, byte_size(bytes)} | bad]}
        end
      end)

    cond do
      mismatches == [] ->
        IO.puts("\nALL #{length(rest) + 1} PEER DOCUMENTS ARE BYTE-IDENTICAL.")
        System.halt(0)

      true ->
        IO.puts("\nMISMATCHES (#{length(mismatches)} of #{length(rest)} peers diverged):")

        Enum.each(mismatches, fn {path, sha, size} ->
          IO.puts("  #{path}  sha256=#{String.slice(sha, 0, 12)}…  size=#{size}")
        end)

        IO.puts("\n#{ok} peers matched the reference.")
        System.halt(1)
    end
  end
end

FullExperiment.run()
