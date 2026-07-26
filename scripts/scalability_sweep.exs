defmodule ScalabilitySweep do
  @moduledoc """
  The same controlled workload over a ladder of network sizes, repeated at many seeds.

  This is the sweep the review asks for when it asks what the costs do as the number of peers
  increases. The git replay cannot answer it, because the number of peers in a replay is the number
  of people who happened to write the file, and it is not a knob. The synthetic generator makes it
  one.

  Each point of the ladder is run at every seed, and each run is its own operating system process.
  That matters for the same reason it matters in `scripts/run_repetitions.exs`: two runs inside one
  virtual machine would share the registry, the boundary secret, the latency table, and the
  per-process counters, and would then not be independent samples of anything.

  ## The cost, and how this script handles it

  Each insert makes every other replica acknowledge it, and each acknowledgement is broadcast to
  every other replica, so the acknowledgement traffic of a run grows as the square of the network.
  That growth is the finding, not an accident of the harness, and it is also why the top of the
  ladder is expensive. Two consequences are built in.

  The ladder runs in ascending order of network size, so if the largest point proves unaffordable
  it can be interrupted and every smaller point is already on disk with a trend through it. And a
  run whose `result.json` already exists is skipped, so an interrupted sweep continues where it
  stopped instead of starting again.

  What the script will not do is quietly report a ladder it did not finish. The index it writes
  names every point it attempted along with what happened, and the summary says how many points are
  missing.
  """

  # The reported ladder. Doubling each step, so the quadratic term in the acknowledgement traffic
  # shows as a straight line on a logarithmic axis rather than as three points and a guess.
  @peer_ladder [8, 16, 32, 64, 128]
  @reps 30

  # A ladder a laptop can finish, for proving that the sweep and the plots work before committing a
  # machine to the real one.
  @quick_ladder [4, 8]
  @quick_reps 2

  def run(options) do
    peers = options[:peers]
    seeds = Enum.to_list(options[:seed_base]..(options[:seed_base] + options[:reps] - 1))

    File.mkdir_p!(options[:root])
    announce(peers, seeds, options)

    # Ascending in the network size, and the seeds of one size together, so that an interrupted
    # sweep leaves whole points behind rather than a fragment of each.
    results =
      for peer_count <- peers, seed <- seeds do
        one(peer_count, seed, options)
      end

    write_index(results, peers, seeds, options)
    summarize(results, peers, seeds)
  end

  defp announce(peers, seeds, options) do
    ops = options[:ops_per_peer]

    IO.puts("""
    Scalability sweep
      workload      #{options[:workload]}
      peers         #{Enum.join(peers, ", ")}
      repetitions   #{length(seeds)} (seeds #{hd(seeds)}..#{List.last(seeds)})
      ops per peer  #{ops}
      conflict rate #{options[:conflict_rate]}
      delay         #{options[:delay]}
      root          #{options[:root]}
      runs          #{length(peers) * length(seeds)}

    Expected acknowledgement traffic per run, which is what the cost is
    """)

    Enum.each(peers, fn peer_count ->
      inserts = peer_count * ops
      acks = inserts * (peer_count - 1) * (peer_count - 1)
      IO.puts("      n=#{String.pad_leading(to_string(peer_count), 4)}  #{acks} messages")
    end)

    IO.puts("")
  end

  defp one(peer_count, seed, options) do
    directory = Path.join(options[:root], run_id(peer_count, seed, options))

    if completed?(directory) do
      IO.puts("skip  n=#{peer_count} seed=#{seed} (already has a result)")
      %{"run" => directory, "peers" => peer_count, "seed" => seed, "status" => "skipped"}
    else
      # A directory that is there without a passing result is a run that failed or was interrupted,
      # and saying so distinguishes a sweep that is repeating work from one that is doing it once.
      verb = if File.exists?(directory), do: "rerun", else: "run  "
      IO.puts("#{verb} n=#{peer_count} seed=#{seed}")
      started_at = System.monotonic_time(:millisecond)

      {output, exit_status} =
        System.cmd("mix", arguments(peer_count, seed, directory, options), stderr_to_stdout: true)

      elapsed = System.monotonic_time(:millisecond) - started_at
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "console.log"), output)

      IO.puts("      exit #{exit_status} after #{div(elapsed, 1000)}s")

      %{
        "run" => directory,
        "peers" => peer_count,
        "seed" => seed,
        "exit_status" => exit_status,
        "elapsed_ms" => elapsed,
        "status" => if(exit_status == 0, do: "ok", else: "failed")
      }
    end
  end

  # Whether a run is already on disk and worth keeping. A run writes its `result.json` whether it
  # passed or failed, so the presence of the file is not the question: a sweep re-run after a fix
  # would otherwise inherit every failure it was re-run to clear, and report them as skipped points
  # that a reader takes for finished ones. Only a run that reported `ok` is skipped.
  defp completed?(directory) do
    path = Path.join(directory, "result.json")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"status" => "ok"}} <- Jason.decode(body) do
      true
    else
      _incomplete_or_failed -> false
    end
  end

  defp arguments(peer_count, seed, directory, options) do
    [
      "run",
      "--no-start",
      "scripts/synthetic_workload.exs",
      "--workload",
      to_string(options[:workload]),
      "--peers",
      to_string(peer_count),
      "--ops-per-peer",
      to_string(options[:ops_per_peer]),
      "--conflict-rate",
      to_string(options[:conflict_rate]),
      "--seed",
      to_string(seed),
      "--delay",
      options[:delay],
      "--adversaries",
      to_string(options[:adversaries]),
      "--out",
      directory
    ]
  end

  # The components the run descriptor builds its own identifier from, so the directory a run is
  # written to and the identifier it records for itself agree. The network size is in it, which is
  # what keeps two points of the ladder out of each other's output.
  defp run_id(peer_count, seed, options) do
    [
      "syncordian",
      "#{options[:workload]}_n#{peer_count}",
      to_string(options[:scenario]),
      "adv#{options[:adversaries]}",
      "seed#{seed}"
    ]
    |> Enum.join("_")
  end

  defp write_index(results, peers, seeds, options) do
    path = Path.join(options[:root], "index_#{options[:workload]}.json")
    previous = read_index(path)

    # Merged with whatever the root already holds, rather than replacing it. The top of a ladder is
    # not always affordable at the same number of repetitions as the bottom, so a ladder is run in
    # more than one invocation: the expensive point separately, and at fewer seeds. An index that
    # described only the last invocation would report a two-point ladder over a root holding five,
    # and the runs it omitted would be invisible rather than merely unmentioned.
    #
    # Runs are keyed by their directory, so re-running a point replaces its entry instead of
    # doubling it.
    runs =
      (Map.get(previous, "runs", []) ++ results)
      |> Enum.reduce(%{}, fn run, acc -> Map.put(acc, run["run"], run) end)
      |> Map.values()
      |> Enum.sort_by(&{&1["peers"], &1["seed"]})

    index = %{
      "workload" => to_string(options[:workload]),
      "peers" => union(Map.get(previous, "peers", []), peers),
      "seeds" => union(Map.get(previous, "seeds", []), seeds),
      "ops_per_peer" => options[:ops_per_peer],
      "conflict_rate" => options[:conflict_rate],
      "delay" => options[:delay],
      "adversaries" => options[:adversaries],
      # How many runs stand behind each point, said in the index and not only on the console. A
      # figure drawn from a point with thirty runs and a point with five is not wrong, but a reader
      # cannot see which is which unless the file says so.
      "runs_by_peers" =>
        runs
        |> Enum.filter(&(&1["status"] in ["ok", "skipped"]))
        |> Enum.frequencies_by(& &1["peers"]),
      "runs" => runs
    }

    # Named after the workload, so that running several workloads into one root leaves an index for
    # each rather than only for whichever finished last.
    File.write!(path, Jason.encode!(index, pretty: true))
  end

  defp read_index(path) do
    with {:ok, body} <- File.read(path), {:ok, index} <- Jason.decode(body) do
      index
    else
      _absent_or_unreadable -> %{}
    end
  end

  defp union(left, right), do: (left ++ right) |> Enum.uniq() |> Enum.sort()

  defp summarize(results, peers, seeds) do
    failed = Enum.filter(results, &(&1["status"] == "failed"))
    ok = Enum.count(results, &(&1["status"] == "ok"))
    skipped = Enum.count(results, &(&1["status"] == "skipped"))

    IO.puts("\n#{ok} ok, #{skipped} skipped, #{length(failed)} failed")

    Enum.each(failed, fn result ->
      IO.puts("  failed: n=#{result["peers"]} seed=#{result["seed"]} in #{result["run"]}")
    end)

    # Which points of the ladder have enough runs behind them to carry an interval, said plainly.
    # A point with two runs and a point with thirty are not the same evidence, and a figure drawn
    # from both without saying so invites the reader to treat them as if they were.
    IO.puts("\nRuns behind each point")

    Enum.each(peers, fn peer_count ->
      usable =
        Enum.count(results, &(&1["peers"] == peer_count and &1["status"] in ["ok", "skipped"]))

      note = if usable < length(seeds), do: "  (incomplete)", else: ""
      IO.puts("      n=#{String.pad_leading(to_string(peer_count), 4)}  #{usable}#{note}")
    end)

    System.halt(if(failed == [], do: 0, else: 1))
  end

  def peer_ladder, do: @peer_ladder
  def reps, do: @reps
  def quick_ladder, do: @quick_ladder
  def quick_reps, do: @quick_reps
end

########################################################################################
# Options
########################################################################################

{parsed, _positional, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      workload: :string,
      peers: :string,
      reps: :integer,
      seed_base: :integer,
      ops_per_peer: :integer,
      conflict_rate: :float,
      delay: :string,
      adversaries: :integer,
      root: :string,
      quick: :boolean,
      allow_no_delay: :boolean
    ]
  )

quick? = parsed[:quick] || false
delay = parsed[:delay] || "uniform:5:50"

if delay == "none" and not (parsed[:allow_no_delay] || false) do
  IO.puts("""

  Refusing to run a sweep with no delay.

  The evaluation states that replicas exchange messages under a delay, so a sweep whose numbers are
  reported has to apply one. Pass --delay uniform:<low_ms>:<high_ms>, or --allow-no-delay if this
  sweep is a check rather than a measurement.
  """)

  System.halt(2)
end

# Parsed before the first run, so a misspelled ladder fails immediately rather than after an hour.
peers =
  case parsed[:peers] do
    nil ->
      if quick?, do: ScalabilitySweep.quick_ladder(), else: ScalabilitySweep.peer_ladder()

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        case Integer.parse(String.trim(part)) do
          {count, ""} when count >= 2 ->
            count

          _ ->
            raise ArgumentError,
                  "unreadable peer count #{inspect(part)}; expected a comma-separated list of " <>
                    "integers of at least 2, as in --peers 8,16,32"
        end
      end)
      |> Enum.sort()
  end

workload = String.to_atom(parsed[:workload] || "overlapping_blocks")

unless workload in Syncordian.Workloads.catalogue() do
  IO.puts("""

  Unknown workload #{inspect(workload)}.

  Available: #{Enum.join(Syncordian.Workloads.catalogue(), ", ")}
  """)

  System.halt(2)
end

reps =
  parsed[:reps] || if(quick?, do: ScalabilitySweep.quick_reps(), else: ScalabilitySweep.reps())

# A workload that names a scenario carries it into the directory name too, so the folder a run is
# written to and the scenario its manifest records cannot disagree. The same for the distrusted
# nodes: a workload that cannot be constructed without one is given one rather than run empty.
scenario = Syncordian.Workloads.scenario_for(workload) || :baseline

adversaries =
  parsed[:adversaries] ||
    if(Syncordian.Workloads.requires_adversary?(workload), do: 1, else: 0)

ScalabilitySweep.run(
  workload: workload,
  peers: peers,
  reps: reps,
  seed_base: parsed[:seed_base] || 1,
  ops_per_peer: parsed[:ops_per_peer] || 8,
  conflict_rate: parsed[:conflict_rate] || 0.5,
  delay: delay,
  scenario: scenario,
  adversaries: adversaries,
  root: parsed[:root] || "debug/sweep"
)
