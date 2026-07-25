# Repeated runs of the evaluation.
#
# A single run of a concurrent system is one observation, not a property of the system. The
# evaluation therefore reports the mean over R runs that differ only in their seed, with a
# confidence interval over those runs. This driver produces them.
#
# Each repetition is a separate operating system process. Repetitions inside one virtual
# machine would share the global name registry, the boundary secret, the operation-time
# table, and the process dictionaries the cost accumulators live in, so a leak from one
# repetition into the next would show up as correlation between samples that are supposed to
# be independent.
#
# Run from `Code/` as:
#
#     mix run --no-start scripts/run_repetitions.exs --reps 10 --seed-base 1 \
#       --delay uniform:5:50 --scenarios baseline,reorder_storm,offline_window,\
# post_collection_replay,bounded_loss
#
# Options:
#
#   --reps N          repetitions per configuration. The evaluation uses 10.
#   --seed-base S     seeds are S through S+N-1. Two sweeps with the same base are the
#                     same experiment.
#   --delay SPEC      "uniform:<low_ms>:<high_ms>". A sweep whose results are reported must
#                     not run with "none"; see --allow-no-delay below.
#   --scenarios LIST  comma-separated scenario names. Defaults to the two a history replay
#                     can carry, baseline and reorder_storm; see --allow-stalling-scenarios.
#   --adversaries N   distrusted nodes per run. Defaults to 0.
#   --crdt NAME       implementation to replay. Defaults to syncordian.
#   --root DIR        where the runs are written. Defaults to debug/runs.
#   --allow-stalling-scenarios
#                     replays a history under offline_window or bounded_loss. Those two are
#                     asserted on the controlled workload instead, for the reason the refusal
#                     explains.
#   --allow-no-delay  permits a sweep with no delay at all. Present only so that a quick
#                     check can be run without editing this file, and it is refused by
#                     default because a reported experiment that silently ran on a quiet
#                     network is the defect this driver exists to prevent.
#
# The sweep is resumable. A repetition whose result.json already exists is skipped, so an
# interrupted sweep continues where it stopped rather than starting again.

defmodule Repetitions do
  def run(options) do
    scenarios = options[:scenarios]
    reps = options[:reps]
    seeds = Enum.to_list(options[:seed_base]..(options[:seed_base] + reps - 1))

    File.mkdir_p!(options[:root])

    IO.puts("""
    Sweep: #{length(scenarios)} scenario(s) x #{reps} repetition(s) = \
    #{length(scenarios) * reps} runs
      delay       #{options[:delay]}
      seeds       #{List.first(seeds)}..#{List.last(seeds)}
      adversaries #{options[:adversaries]}
      root        #{options[:root]}
    """)

    results =
      for scenario <- scenarios, seed <- seeds do
        one(scenario, seed, options)
      end

    write_index(results, options)
    summarize(results)
  end

  defp one(scenario, seed, options) do
    directory = Path.join(options[:root], run_id(scenario, seed, options))

    if File.exists?(Path.join(directory, "result.json")) do
      IO.puts("skip  #{directory} (already has a result)")
      %{"run" => directory, "status" => "skipped"}
    else
      IO.puts("run   #{directory}")
      started_at = System.monotonic_time(:millisecond)

      {output, exit_status} =
        System.cmd(
          "mix",
          [
            "run",
            "--no-start",
            "scripts/run_full_experiment.exs",
            "--seed",
            to_string(seed),
            "--delay",
            options[:delay],
            "--scenario",
            scenario,
            "--adversaries",
            to_string(options[:adversaries]),
            "--crdt",
            options[:crdt],
            "--out",
            directory
          ],
          stderr_to_stdout: true
        )

      elapsed = System.monotonic_time(:millisecond) - started_at
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "console.log"), output)

      IO.puts("      exit #{exit_status} after #{div(elapsed, 1000)}s")

      %{
        "run" => directory,
        "scenario" => scenario,
        "seed" => seed,
        "exit_status" => exit_status,
        "elapsed_ms" => elapsed,
        "status" => if(exit_status == 0, do: "ok", else: "failed")
      }
    end
  end

  # The same components the run descriptor builds its identifier from, so that the directory
  # a run is written to and the identifier it records for itself agree.
  defp run_id(scenario, seed, options) do
    [
      options[:crdt],
      options[:tracked_file] |> Path.basename() |> String.replace(~r/\W+/, "-"),
      scenario,
      "adv#{options[:adversaries]}",
      "seed#{seed}"
    ]
    |> Enum.join("_")
  end

  defp write_index(results, options) do
    index = %{
      "delay" => options[:delay],
      "reps" => options[:reps],
      "seed_base" => options[:seed_base],
      "crdt" => options[:crdt],
      "adversaries" => options[:adversaries],
      "tracked_file" => options[:tracked_file],
      "runs" => results
    }

    File.write!(Path.join(options[:root], "index.json"), Jason.encode!(index, pretty: true))
  end

  defp summarize(results) do
    failed = Enum.filter(results, &(&1["status"] == "failed"))
    ok = Enum.count(results, &(&1["status"] == "ok"))
    skipped = Enum.count(results, &(&1["status"] == "skipped"))

    IO.puts("\n#{ok} ok, #{skipped} skipped, #{length(failed)} failed")
    Enum.each(failed, &IO.puts("  failed: #{&1["run"]}"))

    System.halt(if(failed == [], do: 0, else: 1))
  end
end

{parsed, _positional, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      reps: :integer,
      seed_base: :integer,
      delay: :string,
      scenarios: :string,
      adversaries: :integer,
      crdt: :string,
      root: :string,
      allow_no_delay: :boolean,
      allow_stalling_scenarios: :boolean
    ]
  )

delay = parsed[:delay] || "none"

if delay == "none" and not (parsed[:allow_no_delay] || false) do
  IO.puts("""
  Refusing to run a sweep with no delay.

  The evaluation states that peers exchange messages under a delay, so a sweep whose
  numbers are reported has to apply one. Pass --delay uniform:<low_ms>:<high_ms>, or
  --allow-no-delay if this sweep is a check rather than a measurement.
  """)

  System.halt(2)
end

# Parsed here rather than in the run so that a misspelled scenario fails before the first
# repetition instead of after the last one.
scenarios =
  (parsed[:scenarios] || "baseline,reorder_storm")
  |> String.split(",", trim: true)
  |> Enum.map(fn name ->
    unless Enum.any?(Syncordian.Run.scenarios(), &(Atom.to_string(&1) == name)) do
      raise ArgumentError, "unknown scenario #{inspect(name)}"
    end

    name
  end)

adversaries = parsed[:adversaries] || 0

# Two scenarios leave a replica behind with nothing to tell it so. A replica recovers a lost
# operation when a later message reveals the gap, and if the writer of the lost operation
# never speaks again, nothing reveals it. On the git replay that turns into a stall rather
# than a failure, because the replay holds every commit until its author has materialized the
# exact state the commit was written against, and an author that is quietly behind never
# materializes it. The scenarios are therefore asserted on the controlled workload, where the
# window of disturbance closes and the traffic that follows reveals every gap
# (test/syncordian/live/difficult_executions_test.exs). Running them over a history is
# possible and is left available, but it measures the replay harness as much as the protocol.
stalling = Enum.filter(scenarios, &(&1 in ["offline_window", "bounded_loss"]))

if stalling != [] and not (parsed[:allow_stalling_scenarios] || false) do
  IO.puts("""
  Refusing to replay a history under #{Enum.join(stalling, ", ")}.

  These scenarios can leave a replica behind with nothing to tell it so, and the replay holds
  every commit until its author has caught up exactly, so a quietly behind author stalls the
  replay instead of failing it. They are asserted on the controlled workload instead:

      mix test --include live test/syncordian/live/difficult_executions_test.exs

  Pass --allow-stalling-scenarios to replay a history under them anyway.
  """)

  System.halt(2)
end

# A run named after an attack that had nobody to carry it out reports a property it never
# tested. Refusing the combination is better than producing a quiet baseline under an
# alarming name.
needs_adversary =
  Enum.filter(scenarios, fn name ->
    Syncordian.Run.requires_adversary?(String.to_existing_atom(name))
  end)

if adversaries == 0 and needs_adversary != [] do
  IO.puts("""
  Refusing to run #{Enum.join(needs_adversary, ", ")} with no distrusted nodes.

  These scenarios are carried out by a distrusted node, so with none in the network they
  would run as a plain baseline under the name of an attack. Pass --adversaries N.
  """)

  System.halt(2)
end

# Recorded in the index so the sweep says which history it replayed, which is otherwise only
# visible in the environment the sweep happened to be launched with.
Repetitions.run(
  reps: parsed[:reps] || 10,
  seed_base: parsed[:seed_base] || 1,
  delay: delay,
  scenarios: scenarios,
  adversaries: adversaries,
  crdt: parsed[:crdt] || "syncordian",
  root: parsed[:root] || "debug/runs",
  tracked_file: Syncordian.GitLog.tracked_file()
)
