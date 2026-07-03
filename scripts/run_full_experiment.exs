# Headless run of the paper's full Syncordian evaluation.
#
# Drives the same `Syncordian.Supervisor` the `/supervisor` LiveView normally drives,
# replays the whole mainline git log of the configured tracked file (see
# `Syncordian.GitLog` — repo/file are overridable via `SYNCORDIAN_REPO_PATH` /
# `SYNCORDIAN_TRACKED_FILE`, defaulting to the OhMyZsh README) across one author peer
# per author found in that log and 0 Byzantine peers (mirroring the default LiveView
# selection), then writes each peer's materialized document to
# `debug/documents/syncordian/document_peer_N`.
#
# Since this is meant to be pointed at different repos (not just the OhMyZsh log this
# codebase was developed against), the script prints the repo/file, author (peer)
# count, commit count, and the hash of the last replayed commit up front — that hash
# is what `git show <hash>:<tracked file>` in the target repo must byte-match for the
# run to have converged correctly, so it's what to check manually if something looks off.
#
# Run from `code/` as:
#
#     mix run --no-start scripts/run_full_experiment.exs
#
# Pass `--observer` (in addition to, or instead of, the byzantine-count argument, in
# either order) to also launch the Erlang :observer GUI right before the peers spawn, so
# you can watch peer process count/mailbox/memory live while the replay runs:
#
#     mix run --no-start scripts/run_full_experiment.exs --observer
#     mix run --no-start scripts/run_full_experiment.exs 5 --observer
#
# :observer needs a display (X11/Wayland/etc.) and an Erlang build with :wx compiled in —
# if either is missing, starting it raises and the script prints why, then continues the
# experiment without it. With --observer, the script pauses after finishing and waits for
# Enter before exiting, so the window stays open for you to inspect at your own pace
# instead of disappearing the instant the run completes.
#
# Approximate wall time: ~3 min for the 71-commit OhMyZsh log (71 commits × ~2s
# dispatch + settle time); scales with however many commits the configured repo/file has.
# After it completes, the script invokes scripts/identical.sh, which exits 0
# iff every dumped peer document is byte-identical.

defmodule FullExperiment do
  def run(byzantine_count, observer?) do
    out_dir = "debug/documents/syncordian"
    IO.puts("Cleaning #{out_dir}/document_peer_* …")
    File.mkdir_p!(out_dir)

    Path.wildcard(Path.join(out_dir, "document_peer_*"))
    |> Enum.each(&File.rm!/1)

    print_source_summary()
    if observer?, do: start_observer()

    IO.puts("Initializing supervisor with crdt=:syncordian, byzantine=#{byzantine_count} …")
    sup_pid = Syncordian.Supervisor.init(byzantine_count, :syncordian)
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
    settle_ms = 10_000
    IO.puts("Settling network for #{div(settle_ms, 1000)}s before reading dumps…")
    Process.sleep(settle_ms)

    # Re-issue the dump explicitly in case some peers missed the supervisor's self-send
    # because they were still processing broadcasts at that moment.
    IO.puts("Re-issuing {:write_current_peers_document} as a belt-and-braces…")
    send(sup_pid, {:write_current_peers_document})
    Process.sleep(2_000)

    files = Path.wildcard(Path.join(out_dir, "document_peer_*")) |> Enum.sort()
    IO.puts("Dumped #{length(files)} peer documents:")
    Enum.each(files, &IO.puts("  #{&1}"))

    IO.puts("\nRunning scripts/identical.sh from code/ …")
    # identical.sh is written assuming CWD = code/scripts and FOLDER=../debug/documents,
    # so it walks debug/documents/* at the top level. To make it check the Syncordian
    # subtree specifically, we do the byte-equality check inline instead.
    verify_convergence(files, observer?)
  end

  # Starts the Erlang :observer GUI (process list, mailbox sizes, memory, etc.) so peer
  # activity can be watched live during the replay. Requires an Erlang build with :wx and
  # a display to render to; failures here are non-fatal to the experiment itself.
  defp start_observer do
    IO.puts("Starting :observer …")

    case Application.ensure_all_started(:observer) do
      {:ok, _} ->
        :observer.start()
        IO.puts("Observer launched — look under the \"Processes\" tab for the peer PIDs.")

      {:error, reason} ->
        IO.puts(
          "Could not start :observer (#{inspect(reason)}) — continuing without it. " <>
            "This usually means the Erlang build lacks :wx or there is no display available."
        )
    end
  rescue
    error ->
      IO.puts("Could not start :observer (#{Exception.message(error)}) — continuing without it.")
  end

  # With --observer, keep the VM (and the Observer window) alive until the user is done
  # looking, instead of System.halt-ing the instant the run finishes.
  defp finish(code, observer?) do
    if observer? do
      IO.gets("\nObserver is still running — press Enter here to exit… ")
    end

    System.halt(code)
  end

  # Reads the same live git source Syncordian.Supervisor.init/2 is about to replay, and
  # reports repo/file, author (peer) count, commit count, and the last commit's hash —
  # the manual reference point for `git show <hash>:<file>` when eyeballing an unfamiliar
  # repo's converged document.
  defp print_source_summary do
    repo = Syncordian.GitLog.repo_path()
    file = Syncordian.GitLog.tracked_file()
    log_lines = Syncordian.GitLog.log_lines()

    commits = Syncordian.GitParser.commits_from_lines(log_lines)

    {_, authors_list} =
      log_lines |> Syncordian.GitParser.parse_lines() |> Syncordian.GitParser.group_by_author()

    last_commit = List.last(commits)

    IO.puts("Source repo:      #{Path.expand(repo)}")
    IO.puts("Tracked file:     #{file}")
    IO.puts("Author peers:     #{length(authors_list)}")
    IO.puts("Commits to replay: #{length(commits)}")
    IO.puts("Last commit hash: #{last_commit}")
    IO.puts("  (verify manually with: git -C #{repo} show #{last_commit}:#{file})")
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

  defp verify_convergence([], observer?) do
    IO.puts("ERROR: no peer documents found")
    finish(2, observer?)
  end

  defp verify_convergence([single], observer?) do
    IO.puts("Only one peer document (#{single}) — trivially identical.")
    finish(0, observer?)
  end

  defp verify_convergence([ref | rest], observer?) do
    ref_bytes = File.read!(ref)
    ref_sha = :crypto.hash(:sha256, ref_bytes) |> Base.encode16(case: :lower)

    IO.puts(
      "Reference: #{ref}  sha256=#{String.slice(ref_sha, 0, 12)}…  size=#{byte_size(ref_bytes)}"
    )

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
        finish(0, observer?)

      true ->
        IO.puts("\nMISMATCHES (#{length(mismatches)} of #{length(rest)} peers diverged):")

        Enum.each(mismatches, fn {path, sha, size} ->
          IO.puts("  #{path}  sha256=#{String.slice(sha, 0, 12)}…  size=#{size}")
        end)

        IO.puts("\n#{ok} peers matched the reference.")
        finish(1, observer?)
    end
  end
end

# CLI arguments (either order): an optional integer = number of Byzantine peers
# (default 0), and an optional `--observer` flag to launch the :observer GUI. With
#   mix run --no-start scripts/run_full_experiment.exs 3
# the supervisor spawns author peers plus 3 Byzantine peers; the convergence check still
# ranges over the honest author documents (Byzantine peers hold no document and write no
# dump), so byte-identity to the 0-Byzantine baseline shows every forged message was
# dropped at admission.
{flags, positional} = Enum.split_with(System.argv(), &(&1 in ["--observer", "-o"]))
observer? = flags != []

byzantine_count =
  case positional do
    [n | _] -> String.to_integer(n)
    _ -> 0
  end

FullExperiment.run(byzantine_count, observer?)
