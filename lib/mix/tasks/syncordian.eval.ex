defmodule Mix.Tasks.Syncordian.Eval do
  @moduledoc """
  Headless driver for a Syncordian experiment.

  Replays the configured git-log fixture through the supervisor, dumps every peer's
  document to `debug/documents/<crdt>/`, then compares those documents to assert
  byte-for-byte convergence. Equivalent to the `/supervisor` LiveView's
  "Launch → All commits → Write current peers document" sequence, but suitable for CI
  and for quick regression checks while iterating on the CRDT modules.

  ## Usage

      mix syncordian.eval                          # syncordian, 0 byzantine
      mix syncordian.eval --crdt fugue             # one of: syncordian | fugue | treedoc | logoot
      mix syncordian.eval --byzantine 3
      mix syncordian.eval --skip-identical         # skip the comparison (faster smoke run)
      mix syncordian.eval --commit-timeout 600000  # ms allowed per commit before giving up
                                                   # (default 120000; the materialization
                                                   # barrier legitimately waits a while on
                                                   # large commits at high peer counts)

  ## Exit codes

    * 0 — every peer converged
    * 1 — divergence detected (or supervisor never finished)
  """
  use Mix.Task

  @shortdoc "Headless Syncordian experiment driver (replay → save → convergence check)"

  @valid_crdts ~w(syncordian fugue treedoc logoot)a

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          crdt: :string,
          byzantine: :integer,
          skip_identical: :boolean,
          commit_timeout: :integer
        ]
      )

    crdt = parse_crdt(opts[:crdt] || "syncordian")
    byzantine = opts[:byzantine] || 0
    commit_timeout = opts[:commit_timeout] || 120_000
    skip_identical = opts[:skip_identical] || false

    # Load code paths without booting the Phoenix endpoint — the supervisor only needs
    # the BEAM globals (:global, :logger) which Mix has already started for us.
    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")
    Application.ensure_all_started(:logger)
    crdt_dir = Path.join(["debug", "documents", to_string(crdt)])
    File.mkdir_p!(Path.join(crdt_dir, "raw"))
    File.mkdir_p!("debug/metadata")
    # Clear any prior dump from this CRDT so a stale prior run can't make a divergent
    # rerun look like it converged. The raw dump must go too: the convergence script's
    # no-:aura check reads raw/document, and a leftover from an earlier run reports
    # that run's settle state, not this one's.
    crdt_dir
    |> File.ls!()
    |> Enum.reject(&(&1 == ".gitignore"))
    |> Enum.reject(&File.dir?(Path.join(crdt_dir, &1)))
    |> Enum.each(&File.rm!(Path.join(crdt_dir, &1)))

    File.rm(Path.join([crdt_dir, "raw", "document"]))

    # Stale metadata JSONs from a prior run (different commit range, byzantine count,
    # or an aborted attempt) would silently mix into the series that
    # scripts/data_visualization.py and scripts/heap_size_visualization.py plot, so
    # start each run from empty metadata dirs — mirroring
    # scripts/run_full_experiment.exs, whose cleaning this task previously lacked.
    for dir <- [
          Path.join(["debug", "metadata", "supervisor", to_string(crdt)]),
          Path.join(["debug", "metadata", "individual_peer", to_string(crdt)])
        ] do
      File.mkdir_p!(dir)
      dir |> Path.join("*.json") |> Path.wildcard() |> Enum.each(&File.rm!/1)
    end

    # The comparison series the plot scripts read; make sure they exist on a fresh clone,
    # but leave contents alone. There used to be a third directory here,
    # debug/metadata/byzantine_nodes, which the sweep plot read and which no code ever
    # wrote. The adversary count now travels in each run's manifest, so the sweep is
    # assembled from the runs themselves and the empty directory is gone.
    Enum.each(
      [
        "debug/metadata/individual_peer/fugue",
        "debug/metadata/individual_peer/logoot"
      ],
      &File.mkdir_p!/1
    )

    IO.puts(banner(crdt, byzantine))

    supervisor_pid = Syncordian.Supervisor.init(byzantine, crdt)
    send(supervisor_pid, {:send_all_commits, self(), byzantine})

    case wait_for_completion(commit_timeout) do
      {:ok, count} ->
        IO.puts("\n[eval] supervisor reached limit after #{count} commits")

      {:timeout, count, last_seen_ms_ago} ->
        IO.puts(
          "\n[eval] timed out waiting for next commit (#{count} processed, " <>
            "no progress for #{last_seen_ms_ago} ms)"
        )

        send(supervisor_pid, {:kill})
        Mix.raise("supervisor did not finish replaying commits within the timeout")
    end

    # The supervisor schedules :write_current_peers_document right before sending
    # :limit_reached, but the save runs asynchronously per peer after the settle
    # window. Wait generously: hundreds of peers each flush a document file.
    wait_for_documents(crdt, 120_000)

    send(supervisor_pid, {:kill})

    if skip_identical do
      IO.puts("[eval] --skip-identical set, not comparing the peer documents")
    else
      run_identical(crdt)
    end
  end

  defp parse_crdt(s) do
    atom = String.to_atom(s)

    if atom in @valid_crdts do
      atom
    else
      Mix.raise("unknown --crdt #{inspect(s)}; expected one of #{Enum.join(@valid_crdts, ", ")}")
    end
  end

  defp wait_for_completion(commit_timeout) do
    wait_for_completion(0, commit_timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for_completion(count, commit_timeout, last_progress_ms) do
    receive do
      {:commit_inserted, %{author: _, hash: hash}} ->
        IO.write(".")
        if rem(count + 1, 10) == 0, do: IO.puts(" (#{count + 1}, last #{short(hash)})")

        wait_for_completion(
          count + 1,
          commit_timeout,
          System.monotonic_time(:millisecond)
        )

      {:limit_reached, _} ->
        {:ok, count}

      _other ->
        wait_for_completion(count, commit_timeout, last_progress_ms)
    after
      commit_timeout ->
        ms = System.monotonic_time(:millisecond) - last_progress_ms
        {:timeout, count, ms}
    end
  end

  # Waits until every peer's document save has landed: the file count must be >= 2 AND
  # stable across several consecutive polls (the eval does not know the pool size, and
  # the previous ">= 2 then 500 ms" rule killed the network while late savers — one
  # peer out of 85 in practice — were still flushing, silently shrinking the identical
  # check). For syncordian it additionally waits for this run's raw dump
  # (raw/document, deleted at startup), which the convergence script's no-:aura check
  # reads and which the supervisor schedules after the settle window.
  defp wait_for_documents(crdt, total_timeout_ms) do
    dir = Path.join(["debug", "documents", to_string(crdt)])
    raw_path = Path.join([dir, "raw", "document"])
    deadline = System.monotonic_time(:millisecond) + total_timeout_ms

    poll = fn poll, prev_count, stable ->
      files =
        case File.ls(dir) do
          {:ok, fs} ->
            fs
            |> Enum.reject(&(&1 == ".gitignore"))
            |> Enum.reject(&File.dir?(Path.join(dir, &1)))

          _ ->
            []
        end

      count = length(files)
      stable = if count == prev_count, do: stable + 1, else: 0
      raw_ok = crdt != :syncordian or File.exists?(raw_path)

      cond do
        count >= 2 and stable >= 4 and raw_ok ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          Mix.raise(
            "documents under #{dir} incomplete after timeout " <>
              "(#{count} files, raw dump present: #{raw_ok}); aborting"
          )

        true ->
          Process.sleep(500)
          poll.(poll, count, stable)
      end
    end

    poll.(poll, -1, 0)
  end

  defp run_identical(crdt) do
    dir = Path.join(["debug", "documents", to_string(crdt)])

    files =
      File.ls!(dir)
      |> Enum.reject(&(&1 == ".gitignore"))
      |> Enum.reject(&File.dir?(Path.join(dir, &1)))
      |> Enum.sort()

    if length(files) < 2 do
      Mix.raise("only #{length(files)} document file(s) under #{dir}; nothing to compare")
    end

    [head | rest] = files
    head_path = Path.join(dir, head)
    head_bytes = File.read!(head_path)

    mismatches =
      Enum.flat_map(rest, fn name ->
        path = Path.join(dir, name)
        if File.read!(path) == head_bytes, do: [], else: [path]
      end)

    case mismatches do
      [] ->
        IO.puts("\n[eval] CONVERGED: all #{length(files)} peer documents identical to #{head}")

      _ ->
        IO.puts(
          "\n[eval] DIVERGED: #{length(mismatches)} of #{length(rest)} peers differ from #{head}:"
        )

        Enum.each(mismatches, &IO.puts("  - " <> &1))
        Mix.raise("convergence check failed")
    end
  end

  defp banner(crdt, byzantine) do
    [
      "",
      "================================================================",
      " Syncordian headless evaluation",
      "   crdt:      #{crdt}",
      "   byzantine: #{byzantine}",
      "================================================================"
    ]
    |> Enum.join("\n")
  end

  defp short(hash) when is_binary(hash), do: String.slice(hash, 0, 7)
  defp short(hash), do: inspect(hash)
end
