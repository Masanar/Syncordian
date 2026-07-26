defmodule SyntheticWorkload do
  @moduledoc """
  One controlled concurrent workload, one seed, one operating system process.

  The counterpart of `scripts/run_full_experiment.exs`. That script replays a real history and
  asks whether the replicas end up holding the file git holds. This one constructs an execution
  the history cannot produce, and asks whether the properties that execution is supposed to
  establish actually hold.

  Why a separate driver is needed at all: the replay holds each commit until its author has
  materialized the state the commit was written against, so two writers never reach the same place
  in the document at the same time. Over both histories we replay, the counters that record an
  interleaving and its repair stay at zero. Here every writer has its own process and no writer
  waits for another.

  The output layout is the one the aggregation reads, so a synthetic run and a git run can be
  summarized by the same script. What differs is the workload block of the manifest, which names
  the workload and the size of the network instead of a repository and a file.
  """

  alias Syncordian.Peer
  alias Syncordian.Run
  alias Syncordian.Workloads
  alias Syncordian.Workloads.Checks

  def run(options) do
    name = options[:workload]
    plan = build_plan(name, options)

    refuse_unless_delayed(options)
    refuse_unless_adversary(name, options)

    prepare(options[:out])
    announce(plan, options)

    started = System.monotonic_time(:millisecond)

    observation =
      Workloads.run(
        plan,
        [
          seed: options[:seed],
          delay: options[:delay],
          scenario: options[:scenario],
          root: options[:out],
          adversary: adversary_profile(options)
        ] ++ maybe(:settle_timeout_ms, options[:settle_timeout_ms])
      )

    elapsed = System.monotonic_time(:millisecond) - started
    results = Checks.run(plan, observation)
    failures = Checks.failures(results)

    Run.write_manifest!()
    save_documents(observation)
    save_workload_metadata(plan, observation, results)
    save_latency(plan)

    report(plan, observation, results, failures, elapsed)
    write_result(plan, observation, results, failures, elapsed)

    Workloads.teardown(observation.pids)
    Workloads.teardown(observation.adversaries)

    if failures == [], do: System.halt(0), else: System.halt(1)
  end

  ######################################################################################
  # Refusals
  ######################################################################################

  # The same rule the repetition driver applies. Every reported number is taken under a delay, so a
  # run that would report one without applying any is refused rather than produced quietly.
  defp refuse_unless_delayed(options) do
    if options[:delay] == :none and not options[:allow_no_delay] do
      halt("""
      Refusing to run without a message delay.

      The evaluation states that replicas exchange messages under a delay, so a run whose numbers
      are reported has to apply one. Pass --delay uniform:5:50, or --allow-no-delay if you are
      debugging and the numbers are not going anywhere.
      """)
    end
  end

  # A workload whose subject is the behaviour of a distrusted node cannot be constructed without
  # one. Without this the run would pass every property over an execution in which nothing was
  # replayed, which reads as evidence that replays are harmless.
  defp refuse_unless_adversary(name, options) do
    if Workloads.requires_adversary?(name) and options[:adversaries] == 0 do
      halt("""
      Refusing to run #{name} with no distrusted node.

      This workload's subject is a message a distrusted node captures and broadcasts again, so with
      nobody to capture anything it tests nothing. Pass --adversaries 1.
      """)
    end
  end

  defp halt(message) do
    IO.puts("\n" <> String.trim(message) <> "\n")
    System.halt(2)
  end

  ######################################################################################
  # Reporting
  ######################################################################################

  # What the run is about to cost, before it costs it. Each insert makes every other replica
  # acknowledge, and each acknowledgement is broadcast to every other replica, so the
  # acknowledgement traffic grows as the square of the network. That growth is the subject of the
  # scalability question, and it is also what decides whether a point of the sweep is affordable, so
  # it is worth knowing before the run rather than after.
  #
  # It is a floor and not an estimate, and at the top of a ladder it is a long way below what the run
  # does. It counts the inserts the workload authors, and a repair re-issues a whole block as fresh
  # inserts that draw their own acknowledgements. Measured at sixty-four writers: 512 authored lines,
  # 3432 re-placements, and 15.4 million acknowledgements against the 2.0 million this line predicts.
  # The repair, not the authoring, is what the traffic is made of once enough writers contend.
  defp announce(plan, options) do
    inserts = plan.peers * plan.params[:ops_per_peer]
    acks = inserts * (plan.peers - 1) * (plan.peers - 1)

    IO.puts("""
    Synthetic workload
      workload      #{plan.name}
      peers         #{plan.peers}
      ops per peer  #{plan.params[:ops_per_peer]}
      seed          #{options[:seed] || "none"}
      delay         #{Run.delay_to_string(options[:delay])}
      scenario      #{options[:scenario] || plan.scenario || :baseline}
      adversaries   #{options[:adversaries]}
      out           #{options[:out]}
      asserts       #{Enum.join([:converged | plan.asserts], ", ")}

    Expected traffic, counting the authored inserts only
      inserts       #{inserts}
      acknowledgements at least #{acks}   (inserts * (n-1)^2, before any repair re-issues)
    """)
  end

  defp report(plan, observation, results, failures, elapsed) do
    metadata = observation.metadata

    IO.puts("Settled: #{inspect(observation.settled)} in #{elapsed} ms")
    IO.puts("\nProperties")

    Enum.each(Enum.sort(results), fn {property, outcome} ->
      mark = if outcome == :ok, do: "ok  ", else: "FAIL"
      detail = if outcome == :ok, do: "", else: " " <> inspect(outcome, limit: 6)
      IO.puts("  #{mark} #{property}#{detail}")
    end)

    IO.puts("""

    Interleaving
      conflicts observed      #{metadata["conflicts_observed"]}
      replacements issued     #{metadata["replacement_issued_counter"]}
      lines re-issued         #{distribution(metadata["reissued_lines_per_conflict"])}
      live duplicates, most   #{metadata["live_duplicates_max"]}

    Traffic
      insert bytes / messages #{metadata["bytes_insert"]} / #{metadata["msgs_insert"]}
      ack bytes / messages    #{metadata["bytes_ack"]} / #{metadata["msgs_ack"]}
      fetch asked / served    #{metadata["fetch_request_sent"]} / #{metadata["fetch_served"]}
    """)

    # Reported and not asserted, because there is one execution in which it legitimately differs
    # between replicas. See `Syncordian.Workloads.Checks.settlement_report/1`.
    settlement = Checks.settlement_report(observation.documents)
    lagging = for {peer, %{aura: count}} <- settlement, count > 0, do: {peer, count}

    if lagging != [] do
      IO.puts("Settlement still pending at #{inspect(lagging)} (peer, unsettled lines)")
    end

    if :contiguous not in plan.asserts do
      IO.puts(
        "Writer order: " <>
          inspect(Checks.contiguity_report(reference_document(observation)).order)
      )
    end

    if failures == [] do
      IO.puts("\nPASS #{plan.name}")
    else
      IO.puts("\nFAIL #{plan.name}\n#{inspect(failures, pretty: true, limit: :infinity)}")
    end
  end

  ######################################################################################
  # Output
  ######################################################################################

  # The output directories, made before the peers exist. A peer writes its document straight to the
  # path the run names and does not create it, so a missing directory turns into a crash inside the
  # replica rather than an error here. Any earlier documents are removed as well: a stale file left
  # over from a previous run is a file the convergence check would happily compare against.
  defp prepare(root) do
    documents = Path.join([root, "documents", "syncordian"])

    File.rm_rf!(documents)
    File.mkdir_p!(Path.join(documents, "raw"))
    File.mkdir_p!(Path.join(root, "metadata"))
  end

  defp save_documents(observation) do
    Enum.each(observation.pids, fn {_peer, pid} -> Peer.save_content(pid) end)

    case observation.pids do
      [{_peer, pid} | _] -> send(pid, {:write_raw_document})
      [] -> :ok
    end

    Process.sleep(300)
  end

  # The run's own record of what it measured. The aggregation reads this file as the run's
  # contribution, the same way it reads a git run's per-commit snapshots.
  defp save_workload_metadata(plan, observation, results) do
    path = Path.join(Run.root(), "metadata")
    File.mkdir_p!(path)

    payload =
      observation.metadata
      |> Map.put("workload", Map.new(plan.params, fn {key, value} -> {to_string(key), value} end))
      |> Map.put("workload_name", to_string(plan.name))
      |> Map.put("peer_count", plan.peers)
      |> Map.put("live_lines", live_line_count(observation))
      |> Map.put(
        "checks",
        Map.new(results, fn {key, outcome} -> {to_string(key), outcome == :ok} end)
      )
      |> Map.put("run", Run.to_map())

    File.write!(Path.join(path, "workload.json"), Jason.encode!(payload, pretty: true))
  end

  defp save_latency(plan) do
    case Syncordian.OpTimes.dump("#{plan.name}_n#{plan.peers}") do
      {:ok, path} -> IO.puts("Latency samples: #{path}")
      :inactive -> IO.puts("Latency table inactive; no samples written")
    end
  end

  defp write_result(plan, observation, results, failures, elapsed) do
    status = if failures == [], do: "ok", else: "failed"

    payload = %{
      status: status,
      run: Run.to_map(),
      peers: plan.peers,
      workload: to_string(plan.name),
      elapsed_ms: elapsed,
      settled: inspect(observation.settled),
      checks: Map.new(results, fn {key, outcome} -> {to_string(key), outcome == :ok} end),
      failures: Enum.map(failures, fn {property, reason} -> "#{property}: #{inspect(reason)}" end)
    }

    File.mkdir_p!(Run.root())
    File.write!(Path.join(Run.root(), "result.json"), Jason.encode!(payload, pretty: true))
  end

  ######################################################################################
  # Helpers
  ######################################################################################

  defp build_plan(name, options) do
    Workloads.plan(
      name,
      [seed: options[:seed] || 1, peers: options[:peers]] ++
        maybe(:ops_per_peer, options[:ops_per_peer]) ++
        maybe(:conflict_rate, options[:conflict_rate])
    )
  end

  defp maybe(_key, nil), do: []
  defp maybe(key, value), do: [{key, value}]

  defp adversary_profile(options) do
    case options[:adversaries] do
      0 -> nil
      count -> %{count: count}
    end
  end

  # How many lines each repair re-issued, said as a distribution. The samples are small integers, so
  # a run with a few hundred repairs printed a list that Elixir renders as a charlist of control
  # characters, which reads as corruption rather than as the measurement it is. The whole list is
  # kept in the metadata for the aggregation; what belongs on a console is its shape.
  defp distribution(nil), do: "none"
  defp distribution([]), do: "none"

  defp distribution(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    median = Enum.at(sorted, div(count, 2))

    "#{count} repairs, #{List.first(sorted)}..#{List.last(sorted)} lines, median #{median}"
  end

  defp reference_document(observation) do
    observation.documents |> Enum.sort() |> hd() |> elem(1)
  end

  defp live_line_count(observation) do
    observation |> reference_document() |> Enum.count(&Checks.live?/1)
  end
end

########################################################################################
# Options
########################################################################################

{parsed, _positional, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      workload: :string,
      peers: :integer,
      ops_per_peer: :integer,
      conflict_rate: :float,
      seed: :integer,
      delay: :string,
      scenario: :string,
      adversaries: :integer,
      out: :string,
      settle_timeout_ms: :integer,
      allow_no_delay: :boolean
    ],
    aliases: [s: :seed, w: :workload, n: :peers]
  )

workload = String.to_atom(parsed[:workload] || "overlapping_blocks")

unless workload in Syncordian.Workloads.catalogue() do
  IO.puts("""

  Unknown workload #{inspect(workload)}.

  Available: #{Enum.join(Syncordian.Workloads.catalogue(), ", ")}
  """)

  System.halt(2)
end

# A workload that names a scenario gets it unless the command line says otherwise, and one that
# cannot run without a distrusted node is given one rather than refused for the sake of it.
default_adversaries = if Syncordian.Workloads.requires_adversary?(workload), do: 1, else: 0

SyntheticWorkload.run(
  workload: workload,
  peers: parsed[:peers] || 3,
  ops_per_peer: parsed[:ops_per_peer],
  conflict_rate: parsed[:conflict_rate],
  seed: parsed[:seed] || 1,
  delay: Syncordian.Run.parse_delay(parsed[:delay] || "uniform:5:50"),
  scenario: parsed[:scenario],
  adversaries: parsed[:adversaries] || default_adversaries,
  out: parsed[:out] || "debug",
  settle_timeout_ms: parsed[:settle_timeout_ms],
  allow_no_delay: parsed[:allow_no_delay] || false
)
