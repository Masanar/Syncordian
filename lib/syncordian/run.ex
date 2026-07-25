defmodule Syncordian.Run do
  @moduledoc """
  The description of one experimental run.

  A run is the unit of replication for every number the evaluation reports. It fixes the
  workload, the delay model, the adversary, and the seed that drives every random choice
  the protocol and its environment make. Ten runs that differ only in their seed are ten
  independent samples of the same configuration, and a reported mean with a confidence
  interval is a statement about those samples.

  The descriptor is built once, before any peer exists, and published through
  `:persistent_term` in the same way the boundary secret is
  (`Syncordian.Byzantine.install_boundary_secret!/1`). Every process reads the same frozen
  description for the whole run. Freezing matters for more than speed. The configuration a
  run reports has to be the configuration the run used, and a value re-read from the
  application environment on every message can be changed halfway through a replay by
  anything that happens to be running in the same virtual machine.

  When no descriptor is installed, the accessors fall back to the live application
  environment. That keeps the unit tests and the ad-hoc drivers, which spawn peers without
  a supervisor and set `:broadcast_delay` at runtime, working exactly as before.

  This module is a plain struct rather than a `Record`. The record convention applies to
  the replicated state of a CRDT, where the getter and setter pattern keeps the hot paths
  free of map access. A run descriptor is written once and read as configuration.

  ## Reproducibility

  A seeded run is reproducible in the sense that every choice the *protocol* and the
  *environment* make is a function of the seed. It is not reproducible in the sense that
  the scheduler of the virtual machine repeats itself, and no experiment on a concurrent
  runtime can claim that. `Syncordian.Rng` is where the distinction is made concrete: a
  quantity that must not depend on the order in which a process happened to receive its
  messages is derived from the seed and the message rather than drawn from a generator
  that advances once per draw.
  """

  @key {:syncordian, :run}

  @typedoc """
  The per-message delay model. `:none` delivers with no delay at all, which is the
  degenerate case the reported experiments must never use.
  """
  @type delay :: :none | {:uniform, non_neg_integer(), non_neg_integer()}

  @typedoc "The named executions the evaluation runs at every repetition."
  @type scenario ::
          :baseline | :reorder_storm | :offline_window | :post_collection_replay | :bounded_loss

  @type t :: %__MODULE__{
          seed: non_neg_integer() | nil,
          run_id: String.t(),
          delay: delay(),
          scenario: scenario(),
          adversary: map(),
          workload: map(),
          root: String.t(),
          environment: map()
        }

  defstruct seed: nil,
            run_id: "adhoc",
            delay: :none,
            scenario: :baseline,
            adversary: %{},
            workload: %{},
            root: "debug",
            environment: %{}

  @scenarios [:baseline, :reorder_storm, :offline_window, :post_collection_replay, :bounded_loss]

  # The adversary's capability set, all of it switched off. A capability the profile leaves
  # at zero is one the run does not exercise, and the manifest says so, so a reader can tell
  # a capability that was tested and survived from one that was never tried.
  @no_adversary %{
    count: 0,
    # Injection of a message with a forged authorization tag, as a fraction of the
    # operations the adversary observes. Replaces a coin that used to be hardcoded.
    inject_rate: 0.0,
    # Whether an injected message also carries tampered content.
    tamper_content: false,
    # Verbatim re-broadcast of a genuine captured message. These pass admission, which is
    # the point of them: they test idempotence rather than the guard.
    replay_rate: 0.0,
    # Delay held before a captured message is replayed, in milliseconds. Long enough to
    # outlive the rotation of the applied-operation set is what makes the replay difficult.
    replay_hold_ms: 0,
    # Delivery control. A duplicated message arrives twice, a reordered one arrives late,
    # and a suppressed one does not arrive at all until it is asked for again.
    duplicate_rate: 0.0,
    reorder_rate: 0.0,
    reorder_extra_ms: 0,
    drop_rate: 0.0
  }

  @doc """
  Builds the descriptor for a run and publishes it to every process.

  Called by `Syncordian.Supervisor.init/2` before the boundary secret is drawn and before
  any peer is spawned, so that no process can observe a half-configured run. Values come
  from `overrides`, then the environment, then the application configuration, then the
  defaults, which is the order the rest of the harness already uses.
  """
  @spec install!(keyword()) :: t()
  def install!(overrides \\ []) do
    seed = resolve_seed(overrides[:seed])
    scenario = resolve_scenario(overrides[:scenario])

    run = %__MODULE__{
      seed: seed,
      delay: resolve_delay(overrides[:delay], scenario),
      scenario: scenario,
      adversary: resolve_adversary(overrides[:adversary], scenario),
      workload: resolve_workload(overrides[:workload]),
      root:
        overrides[:root] || env("SYNCORDIAN_RUN_ROOT") ||
          Application.get_env(:syncordian, :run_root, "debug"),
      environment: environment()
    }

    run = %{run | run_id: overrides[:run_id] || run_id(run)}

    :persistent_term.put(@key, run)
    run
  end

  @doc """
  The descriptor of the run in progress, or a default one when no run has been installed.

  The default is deliberately inert: no seed, no delay, no adversary. A process that reads
  it behaves the way it did before this module existed.
  """
  @spec current() :: t()
  def current, do: :persistent_term.get(@key, %__MODULE__{adversary: @no_adversary})

  @doc "True when a run descriptor has been installed, false under the ad-hoc default."
  @spec installed?() :: boolean()
  def installed?, do: :persistent_term.get(@key, nil) != nil

  @doc """
  Removes the installed descriptor, returning the accessors to their inert defaults.

  For tests, which install a descriptor to exercise one configuration and must not leave it
  in force for the next one.
  """
  @spec reset!() :: :ok
  def reset! do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Whether a scenario is meaningless without at least one distrusted node.

  A run named after an attack that had nobody to carry it out reports a property it never
  tested, so the drivers refuse the combination rather than producing a quiet baseline under
  an alarming name.
  """
  @spec requires_adversary?(scenario()) :: boolean()
  def requires_adversary?(scenario) do
    profile = scenario_adversary(scenario)
    profile[:replay_rate] > 0 or profile[:tamper_content]
  end

  @doc "The run's seed, or `nil` when the run is not seeded."
  @spec seed() :: non_neg_integer() | nil
  def seed, do: current().seed

  @doc """
  The per-message delay model in force.

  Without an installed descriptor this reads the application environment on every call, so
  a driver that widens the delay of already-running peers keeps working. With a descriptor
  the frozen value wins, and the run reports the model it actually ran under.
  """
  @spec delay_spec() :: delay()
  def delay_spec do
    case :persistent_term.get(@key, nil) do
      nil -> legacy_delay()
      run -> run.delay
    end
  end

  @doc """
  The adversary's capability profile.

  Always complete: every capability the profile does not name is present and switched off,
  so a reader of the manifest can tell a capability that was exercised from one that was
  never tried.
  """
  @spec adversary() :: map()
  def adversary, do: current().adversary

  @doc "The named execution this run replays."
  @spec scenario() :: scenario()
  def scenario, do: current().scenario

  @doc """
  A path under the run's output root.

  Repetitions write below `debug/runs/<run_id>/`, and a single run keeps writing below
  `debug/` so that the control panel, the convergence checker, and the plotting scripts
  need no change to read it.
  """
  @spec path(String.t()) :: String.t()
  def path(subpath), do: Path.join(current().root, subpath)

  @doc "The run's output root."
  @spec root() :: String.t()
  def root, do: current().root

  @doc """
  The descriptor as plain data, for the manifest and for the run block embedded in every
  metadata document.
  """
  @spec to_map(t()) :: map()
  def to_map(run \\ current()) do
    %{
      "run_id" => run.run_id,
      "seed" => run.seed,
      "delay" => delay_to_string(run.delay),
      "scenario" => Atom.to_string(run.scenario),
      "adversary" => stringify(run.adversary),
      "workload" => stringify(run.workload),
      "root" => run.root,
      "environment" => stringify(run.environment),
      "secret_source" => if(run.seed, do: "seed", else: "system")
    }
  end

  @doc """
  Writes the descriptor to `manifest.json` at the run root.

  Every parameter the paper states about a run has to be recoverable from this file. That
  is what makes it possible to check the prose against a run instead of against a memory of
  one.
  """
  @spec write_manifest!(t()) :: :ok
  def write_manifest!(run \\ current()) do
    File.mkdir_p!(run.root)
    File.write!(Path.join(run.root, "manifest.json"), Jason.encode!(to_map(run), pretty: true))
  end

  @doc """
  A one-line rendering of the delay model, as the paper states it.

  Kept here rather than in the driver so that the manifest, the console, and the figures
  cannot disagree about what the run's model was.
  """
  @spec delay_to_string(delay()) :: String.t()
  def delay_to_string(:none), do: "none"
  def delay_to_string({:uniform, low, high}), do: "uniform:#{low}:#{high}"

  @doc """
  Parses a delay model from its textual form, as given on a command line or in the
  environment. Raises on an unreadable value rather than silently falling back to no delay,
  because a run that reports a delay it did not apply is the defect this workstream exists
  to remove.
  """
  @spec parse_delay(String.t()) :: delay()
  def parse_delay("none"), do: :none

  def parse_delay(spec) do
    case String.split(spec, ":") do
      ["uniform", low, high] ->
        {:uniform, String.to_integer(low), String.to_integer(high)}

      _ ->
        raise ArgumentError,
              "unreadable delay specification #{inspect(spec)}; " <>
                "expected \"none\" or \"uniform:<low_ms>:<high_ms>\""
    end
  end

  @doc "The known scenarios."
  @spec scenarios() :: [scenario()]
  def scenarios, do: @scenarios

  @doc """
  The adversary profile a named scenario implies.

  A scenario is a claim about what a run stresses, so its capabilities belong with its name
  rather than in the driver that launches it. A run may still override any single value.
  """
  @spec scenario_adversary(scenario()) :: map()
  def scenario_adversary(:baseline), do: %{@no_adversary | inject_rate: 0.09}

  # Every link duplicates and reorders, and the adversary injects and replays hard. This is
  # the execution in which almost nothing arrives in the order it was sent.
  def scenario_adversary(:reorder_storm) do
    %{
      @no_adversary
      | inject_rate: 0.5,
        tamper_content: true,
        replay_rate: 0.5,
        duplicate_rate: 0.3,
        reorder_rate: 0.5,
        reorder_extra_ms: 400
    }
  end

  # The partition itself is targeted rather than probabilistic, so it is not a rate. The
  # supervisor opens and closes it; see `Syncordian.Network.partition/2`.
  def scenario_adversary(:offline_window), do: %{@no_adversary | inject_rate: 0.09}

  # Genuine messages, held past the rotation of the applied-operation set and then replayed
  # verbatim. These pass admission, so what they test is idempotence.
  def scenario_adversary(:post_collection_replay),
    do: %{@no_adversary | replay_rate: 1.0, replay_hold_ms: 5_000}

  # Loss on every link, recovered only by asking the origin again. The rate is modest because
  # the loss is what the replay has to survive, not what it has to be defeated by: a replica
  # that never learns it fell behind has nothing to ask for, and the traffic that follows the
  # window is what reveals the gaps.
  def scenario_adversary(:bounded_loss), do: %{@no_adversary | inject_rate: 0.09, drop_rate: 0.05}

  # The delay a scenario implies. The reorder storm widens the base model as well as adding
  # adversarial reordering on top of it; the rest inherit the run's configured model.
  defp scenario_delay(:reorder_storm), do: {:uniform, 0, 500}
  defp scenario_delay(_scenario), do: nil

  ########################################################################################
  # Resolution
  ########################################################################################

  defp resolve_seed(nil) do
    case env("SYNCORDIAN_SEED") do
      nil -> Application.get_env(:syncordian, :rng_seed)
      value -> String.to_integer(value)
    end
  end

  defp resolve_seed(seed), do: seed

  defp resolve_scenario(nil) do
    (env("SYNCORDIAN_SCENARIO") || Application.get_env(:syncordian, :scenario) || :baseline)
    |> resolve_scenario()
  end

  defp resolve_scenario(scenario) when is_binary(scenario), do: parse_scenario(scenario)
  defp resolve_scenario(scenario) when scenario in @scenarios, do: scenario

  defp parse_scenario(value) do
    case Enum.find(@scenarios, &(Atom.to_string(&1) == value)) do
      nil ->
        raise ArgumentError,
              "unknown scenario #{inspect(value)}, expected one of #{inspect(@scenarios)}"

      scenario ->
        scenario
    end
  end

  defp resolve_delay(nil, scenario) do
    explicit =
      case env("SYNCORDIAN_DELAY") do
        nil -> Application.get_env(:syncordian, :delay)
        value -> parse_delay(value)
      end

    explicit || scenario_delay(scenario) || legacy_delay()
  end

  defp resolve_delay(spec, _scenario) when is_binary(spec), do: parse_delay(spec)
  defp resolve_delay(spec, _scenario), do: spec

  # The delay used to be a range read from `:broadcast_delay` on every broadcast. Two smoke
  # drivers still set it that way to force concurrent authoring, so the range is accepted
  # and translated rather than dropped.
  defp legacy_delay do
    case Application.get_env(:syncordian, :broadcast_delay, 0..0) do
      %Range{first: 0, last: 0} -> :none
      %Range{first: low, last: high} -> {:uniform, low, high}
      other -> other
    end
  end

  defp resolve_adversary(nil, scenario), do: scenario_adversary(scenario)

  defp resolve_adversary(overrides, scenario),
    do: Map.merge(scenario_adversary(scenario), Map.new(overrides))

  defp resolve_workload(nil), do: resolve_workload([])

  defp resolve_workload(overrides) do
    Map.merge(
      %{
        crdt: :syncordian,
        repository: Syncordian.GitLog.repo_path(),
        tracked_file: Syncordian.GitLog.tracked_file(),
        max_commits: Syncordian.GitLog.max_commits(),
        max_peers: max_peers()
      },
      Map.new(overrides)
    )
  end

  defp max_peers do
    case env("SYNCORDIAN_MAX_PEERS") do
      nil -> Application.get_env(:syncordian, :max_peers)
      value -> String.to_integer(value)
    end
  end

  # Absolute performance numbers are only readable next to the machine that produced them.
  defp environment do
    {:ok, hostname} = :inet.gethostname()

    %{
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      host: to_string(hostname),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # The identifier a repetition writes under. Everything that distinguishes one run of a
  # sweep from another appears in it, so two runs can never overwrite each other's output.
  defp run_id(run) do
    workload = run.workload

    [
      to_string(workload[:crdt] || "syncordian"),
      workload[:tracked_file] |> to_string() |> Path.basename() |> String.replace(~r/\W+/, "-"),
      Atom.to_string(run.scenario),
      "adv#{run.adversary[:count] || 0}",
      "seed#{run.seed || 0}"
    ]
    |> Enum.join("_")
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp stringify(map) do
    Map.new(map, fn
      {key, value} when is_atom(value) and not is_boolean(value) and not is_nil(value) ->
        {to_string(key), Atom.to_string(value)}

      {key, value} ->
        {to_string(key), value}
    end)
  end
end
