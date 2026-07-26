# One run of the evaluation, headless.
#
# Drives the same `Syncordian.Supervisor` the `/supervisor` control panel drives, replays
# the whole mainline history of the configured tracked file (see `Syncordian.GitLog`), and
# checks that every peer converged, both to every other peer and to the file git holds at
# the last replayed commit.
#
# One invocation is one run, in the sense the evaluation reports: one seed, one delay
# model, one scenario, one adversary count. Repetitions are separate invocations, each in
# its own operating system process, driven by scripts/run_repetitions.exs. Running them in
# one virtual machine would let global names, the boundary secret, and the operation-time
# table of one repetition reach the next.
#
# Run from `Code/` as:
#
#     mix run --no-start scripts/run_full_experiment.exs
#     mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50
#     mix run --no-start scripts/run_full_experiment.exs --adversaries 5 --scenario reorder_storm
#
# Options:
#
#   --seed N          fixes every random choice the protocol and the environment make.
#                     Without it the run is unseeded and cannot be reproduced.
#   --delay SPEC      "none" or "uniform:<low_ms>:<high_ms>". A reported run must not use
#                     "none": see scripts/run_repetitions.exs and the guard test.
#   --scenario NAME   baseline, reorder_storm, offline_window, post_collection_replay, or
#                     bounded_loss.
#   --adversaries N   number of distrusted nodes (also accepted as a bare integer).
#   --crdt NAME       syncordian, fugue, logoot, or treedoc.
#   --out DIR         output root. Defaults to debug/, which is where the control panel and
#                     the convergence checker look.
#   --observer        launch the Erlang observer before the peers spawn, and wait for Enter
#                     at the end so the window stays open. Needs a display and a :wx build;
#                     a failure here is not fatal to the run.
#
# The run writes, under the output root: manifest.json (the full description of the run),
# documents/, metadata/, latency_*.json, and result.json (what was asserted and what
# happened). Everything a reader needs to tell which configuration produced a number is in
# manifest.json, so no number has to be matched to a configuration by its position in a
# directory tree.

defmodule FullExperiment do
  def run(options) do
    started_at = System.monotonic_time(:millisecond)

    # The run's description has to be in force before the supervisor builds anything, so the
    # driver publishes its options where Syncordian.Run.install!/1 will find them.
    configure(options)

    root = Application.get_env(:syncordian, :run_root, "debug")
    crdt = options[:crdt]

    # Every implementation writes under a directory named after itself, so the driver has to ask
    # which one rather than assume. This used to be hardcoded to Syncordian, which meant a run
    # started with --crdt fugue dumped its documents where nobody looked: the fixpoint wait then
    # never saw a file, spun to its warning, and the convergence check compared nothing. Every
    # baseline comparison was unreachable from the command line as a result.
    name = Syncordian.Utilities.identify_peer_module(crdt).get_module_name()
    out_dir = Path.join(root, "documents/#{name}")

    clean(out_dir, "document_peer_*")
    clean(Path.join(root, "metadata/supervisor/#{name}"), "*.json")
    clean(Path.join(root, "metadata/individual_peer/#{name}"), "*.json")

    if options[:observer], do: start_observer()

    adversaries = options[:adversaries]

    IO.puts("Initializing supervisor with crdt=#{inspect(crdt)}, adversaries=#{adversaries} …")
    sup_pid = Syncordian.Supervisor.init(adversaries, crdt)
    IO.puts("Supervisor pid: #{inspect(sup_pid)}")
    print_source_summary()

    # Give peers a moment to fully register with :global and bind to the supervisor.
    Process.sleep(500)

    IO.puts("Replaying the full history …")
    send(sup_pid, {:send_all_commits, self(), adversaries})

    wait_for_limit_reached()

    # Fixed sleeps are NOT enough here: a straggling replica can still be catching up
    # when the dump lands, so its file is a stale snapshot (and a kill right after loses
    # its remaining work entirely). Wait for true network quiescence, then dump
    # repeatedly until two consecutive rounds are byte-identical — a fixpoint.
    IO.puts("Waiting for network quiescence, then dumping to a fixpoint…")
    wait_quiescence()
    wait_dump_fixpoint(sup_pid, out_dir, nil, 1)

    files = Path.wildcard(Path.join(out_dir, "document_peer_*")) |> Enum.sort()
    IO.puts("Dumped #{length(files)} peer documents:")

    save_final_metadata(sup_pid)
    print_source_summary()

    elapsed = System.monotonic_time(:millisecond) - started_at

    files
    |> check_convergence()
    |> report(root, elapsed, options)
  end

  # The driver's options reach the run descriptor through the application environment, which
  # is where Syncordian.Run.install!/1 looks after the process environment. Setting them
  # here rather than building the descriptor directly keeps a single place where a run's
  # configuration is resolved.
  defp configure(options) do
    if options[:seed], do: Application.put_env(:syncordian, :rng_seed, options[:seed])
    Application.put_env(:syncordian, :delay, options[:delay])
    Application.put_env(:syncordian, :scenario, options[:scenario])
    Application.put_env(:syncordian, :run_root, options[:out])
  end

  defp clean(dir, pattern) do
    File.mkdir_p!(dir)
    Path.wildcard(Path.join(dir, pattern)) |> Enum.each(&File.rm!/1)
  end

  ########################################################################################
  # Convergence
  ########################################################################################

  # Two questions, and the second is the one that matters. Are the replicas identical to each
  # other, and are they identical to what git holds at the last replayed commit? Agreement
  # alone is not correctness: replicas that all applied the same wrong order agree with each
  # other and with nothing else.
  defp check_convergence([]), do: %{status: :error, reason: "no peer documents were written"}

  defp check_convergence(files) do
    [reference | rest] = files
    reference_bytes = File.read!(reference)

    diverged =
      Enum.reject(rest, fn path -> File.read!(path) == reference_bytes end)

    IO.puts(
      "Reference: #{reference}  sha256=#{short_hash(reference_bytes)}  " <>
        "size=#{byte_size(reference_bytes)}"
    )

    cond do
      diverged != [] ->
        IO.puts("\nMISMATCHES (#{length(diverged)} of #{length(rest)} peers diverged):")
        Enum.each(diverged, &IO.puts("  #{&1}  sha256=#{short_hash(File.read!(&1))}"))

        %{
          status: :diverged,
          peers: length(files),
          diverged: length(diverged),
          reason: "replicas do not agree with each other"
        }

      true ->
        IO.puts("\nALL #{length(files)} PEER DOCUMENTS ARE BYTE-IDENTICAL.")
        against_git(reference_bytes, length(files))
    end
  end

  defp against_git(reference_bytes, peers) do
    expected = expected_from_git()

    if expected == nil do
      %{status: :ok, peers: peers, ground_truth: "unavailable", sha256: hash(reference_bytes)}
    else
      if expected == reference_bytes do
        IO.puts("Converged document matches the tracked file at the last replayed commit.")
        %{status: :ok, peers: peers, ground_truth: "matched", sha256: hash(reference_bytes)}
      else
        IO.puts(
          "\nDIVERGED FROM GROUND TRUTH: the replicas agree with each other but not with " <>
            "the tracked file at the last replayed commit " <>
            "(expected #{byte_size(expected)} bytes, got #{byte_size(reference_bytes)})."
        )

        %{
          status: :diverged,
          peers: peers,
          ground_truth: "mismatched",
          reason: "replicas agree with each other but not with git"
        }
      end
    end
  end

  # The line-based document cannot represent a missing final newline, so a git state that
  # ends without one is compared as if it had one. This mirrors the supervisor's own
  # materialization barrier.
  defp expected_from_git do
    last_commit =
      Syncordian.GitLog.log_lines() |> Syncordian.GitParser.commits_from_lines() |> List.last()

    content = Syncordian.GitLog.file_at(last_commit)

    if content != "" and not String.ends_with?(content, "\n"), do: content <> "\n", else: content
  rescue
    _error -> nil
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp short_hash(bytes), do: bytes |> hash() |> String.slice(0, 12)

  ########################################################################################
  # Reporting
  ########################################################################################

  # Every run leaves a verdict beside its data. The repetition driver reads it to decide
  # whether a repetition has already been done, and the aggregation reads it to leave a
  # failed run out of a mean rather than silently averaging it in.
  defp report(result, root, elapsed_ms, options) do
    result =
      result
      |> Map.put(:elapsed_ms, elapsed_ms)
      |> Map.put(:run, Syncordian.Run.to_map())

    File.mkdir_p!(root)
    File.write!(Path.join(root, "result.json"), Jason.encode!(result, pretty: true))

    IO.puts("\nRun finished in #{div(elapsed_ms, 1000)}s: #{result.status}")

    finish(if(result.status == :ok, do: 0, else: 1), options[:observer])
  end

  ########################################################################################
  # Waiting
  ########################################################################################

  # Total queued messages across all globally registered processes must be 0 on two
  # consecutive samples 1s apart. (Mailbox emptiness misses in-flight send_after timers,
  # which is why the dump below still iterates to a fixpoint.)
  defp wait_quiescence(streak \\ 0, waited_ms \\ 0)

  defp wait_quiescence(2, waited_ms) do
    IO.puts("  network quiescent after ~#{div(waited_ms, 1000)}s")
  end

  defp wait_quiescence(streak, waited_ms) do
    if waited_ms > 600_000 do
      IO.puts("  WARNING: still #{total_backlog()} queued messages after 10 min; continuing")
    else
      Process.sleep(1_000)
      backlog = total_backlog()
      if rem(waited_ms, 10_000) == 0 and backlog > 0, do: IO.puts("  backlog: #{backlog}")
      wait_quiescence(if(backlog == 0, do: streak + 1, else: 0), waited_ms + 1_000)
    end
  end

  defp total_backlog do
    :global.registered_names()
    |> Enum.map(&:global.whereis_name/1)
    |> Enum.filter(&is_pid/1)
    |> Enum.map(fn pid ->
      try do
        # `:message_queue_len` is the item `:erlang.process_info/2` accepts. The longer spelling
        # raised, and the rescue below then reported an idle network however deep the mailboxes
        # were, so quiescence here was never actually waited for.
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          _ended -> 0
        end
      rescue
        ArgumentError -> 0
      end
    end)
    |> Enum.sum()
  end

  # Requests a full document dump each round and stops when two consecutive rounds are
  # byte-identical (and non-empty) — the network reached a fixpoint. Late peers keep the
  # loop going instead of leaving a stale file behind.
  defp wait_dump_fixpoint(sup_pid, out_dir, prev, round) do
    send(sup_pid, {:write_current_peers_document})
    Process.sleep(3_000)
    wait_quiescence()

    current =
      Path.wildcard(Path.join(out_dir, "document_peer_*"))
      |> Enum.sort()
      |> Enum.map(fn f -> {f, :erlang.md5(File.read!(f))} end)

    cond do
      current == prev and current != [] ->
        IO.puts("  fixpoint after #{round} dump rounds (#{length(current)} documents)")

      round >= 60 ->
        IO.puts("  WARNING: no fixpoint after #{round} dump rounds; documents still changing")

      true ->
        wait_dump_fixpoint(sup_pid, out_dir, current, round + 1)
    end
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
      600_000 ->
        raise "Timeout waiting for {:limit_reached, _} from supervisor"
    end
  end

  ########################################################################################
  # Reporting helpers
  ########################################################################################

  # Reads the same live git source Syncordian.Supervisor.init/2 replays, and reports
  # repo/file, author (peer) count, commit count, and the last commit's hash.
  defp print_source_summary do
    repo = Syncordian.GitLog.repo_path()
    file = Syncordian.GitLog.tracked_file()
    log_lines = Syncordian.GitLog.log_lines()

    commits = Syncordian.GitParser.commits_from_lines(log_lines)

    {_, authors_list} =
      log_lines |> Syncordian.GitParser.parse_lines() |> Syncordian.GitParser.group_by_author()

    IO.puts("Source repo:      #{Path.expand(repo)}")
    IO.puts("Tracked file:     #{file}")
    IO.puts("Author peers:     #{length(authors_list)}")
    IO.puts("Commits to replay: #{length(commits)}")
    IO.puts("Last commit hash: #{List.last(commits)}")
  end

  # Mirrors the control panel's collect and save actions, so a headless run leaves the same
  # final, fully-settled network-wide snapshot the panel produces.
  defp save_final_metadata(sup_pid) do
    send(sup_pid, {:collect_metadata_from_peers})
    Process.sleep(1_000)
    send(sup_pid, {:print_supervisor_metadata})
    Process.sleep(500)
  end

  defp start_observer do
    IO.puts("Starting :observer …")

    case Application.ensure_all_started(:observer) do
      {:ok, _} ->
        case :observer.start() do
          :ok ->
            IO.puts("Observer launched — look under the \"Processes\" tab for the peer PIDs.")

          {:error, reason} ->
            IO.puts("Could not start the Observer window (#{inspect(reason)}) — continuing.")
        end

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

  defp finish(code, observer?) do
    if observer?, do: IO.gets("\nObserver is still running — press Enter here to exit… ")
    System.halt(code)
  end
end

########################################################################################
# Options
########################################################################################

{parsed, positional, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      seed: :integer,
      delay: :string,
      scenario: :string,
      adversaries: :integer,
      crdt: :string,
      out: :string,
      observer: :boolean
    ],
    aliases: [s: :seed, o: :observer]
  )

# The adversary count used to be the only argument, given bare. Both forms are accepted so
# that the habit and the scripts built on it keep working.
adversaries =
  parsed[:adversaries] ||
    case positional do
      [n | _] -> String.to_integer(n)
      _ -> 0
    end

options = [
  seed: parsed[:seed],
  delay: Syncordian.Run.parse_delay(parsed[:delay] || "none"),
  scenario: parsed[:scenario] || "baseline",
  adversaries: adversaries,
  crdt: Syncordian.Utilities.parse_crdt_id(parsed[:crdt] || "syncordian"),
  out: parsed[:out] || "debug",
  observer: parsed[:observer] || false
]

FullExperiment.run(options)
