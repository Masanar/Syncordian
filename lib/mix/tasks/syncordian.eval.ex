defmodule Mix.Tasks.Syncordian.Eval do
  @moduledoc """
  Headless driver for a Syncordian experiment.

  Replays the configured git-log fixture through the supervisor, dumps every peer's
  document to `debug/documents/<crdt>/`, then runs `scripts/identical.sh` to assert
  byte-for-byte convergence. Equivalent to the `/supervisor` LiveView's
  "Launch → All commits → Write current peers document" sequence, but suitable for CI
  and for quick regression checks while iterating on the CRDT modules.

  ## Usage

      mix syncordian.eval                          # syncordian, 0 byzantine
      mix syncordian.eval --crdt fugue             # one of: syncordian | fugue | treedoc | logoot
      mix syncordian.eval --byzantine 3
      mix syncordian.eval --skip-identical         # skip the cmp pass (faster smoke run)
      mix syncordian.eval --commit-timeout 8000    # ms allowed per commit before giving up

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
    commit_timeout = opts[:commit_timeout] || 10_000
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
    # rerun look like it converged.
    crdt_dir
    |> File.ls!()
    |> Enum.reject(&(&1 == ".gitignore"))
    |> Enum.reject(&File.dir?(Path.join(crdt_dir, &1)))
    |> Enum.each(&File.rm!(Path.join(crdt_dir, &1)))

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
    # :limit_reached, but the save runs asynchronously per peer. Give it a moment
    # to flush before we read the directory.
    wait_for_documents(crdt, 30_000)

    send(supervisor_pid, {:kill})

    if skip_identical do
      IO.puts("[eval] --skip-identical set, not running scripts/identical.sh")
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

  defp wait_for_documents(crdt, total_timeout_ms) do
    dir = Path.join(["debug", "documents", to_string(crdt)])
    deadline = System.monotonic_time(:millisecond) + total_timeout_ms

    poll = fn poll ->
      files =
        case File.ls(dir) do
          {:ok, fs} ->
            fs
            |> Enum.reject(&(&1 == ".gitignore"))
            |> Enum.reject(&File.dir?(Path.join(dir, &1)))

          _ ->
            []
        end

      cond do
        length(files) >= 2 ->
          # Give one more half-second so the last save finishes flushing to disk.
          Process.sleep(500)
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          Mix.raise("documents directory #{dir} still has fewer than 2 files; aborting")

        true ->
          Process.sleep(250)
          poll.(poll)
      end
    end

    poll.(poll)
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
