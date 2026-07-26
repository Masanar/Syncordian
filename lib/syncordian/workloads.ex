defmodule Syncordian.Workloads do
  @moduledoc """
  Controlled concurrent workloads, and the driver that runs them.

  The evaluation's main experiment replays a git history. That replay holds each commit until
  its author has materialized the state the commit was written against, so the authoring is
  serialized and only the delivery is concurrent. The consequence is measurable rather than
  hypothetical: over the histories we replay, the counters that record an interleaving and its
  repair stay at zero from the first commit to the last. The replay establishes that the
  replicas converge, and it establishes nothing at all about the repair protocol, because it
  never asks the repair protocol to run.

  This module builds the executions the replay cannot. A workload here names two or more writers
  that reach the same place in the document at the same time, on purpose, and it says what must
  be true afterwards. `Syncordian.Workloads.Checks` holds the properties.

  ## A workload is a plan, and a plan is data

  `plan/2` returns a value: a list of steps, each stamped with the millisecond at which it is
  issued. It starts no process and reads no configuration. Two consequences follow. A plan can
  be inspected and tested without a network, which is what the fast test suite does. And a plan
  is a function of its name, its seed, and its parameters alone, so the same three arguments
  describe the same execution on any machine.

  The randomness is threaded explicitly through the generator rather than drawn from the
  calling process, for the reason `Syncordian.Rng` sets out: a quantity that must not depend on
  the order in which a process happened to run has to be derived from the seed, not taken from
  a generator whose position depends on who drew from it last. `Syncordian.Rng` itself is not
  used here because its salt is the installed run's seed, and a plan has to be readable before
  a run exists.

  ## Where the concurrency comes from

  From the authoring, not from the delay. `drive/3` gives every writer its own process, and
  those processes share nothing but a starting instant. No writer waits for another.

  This is worth stating plainly because the earlier smoke drivers did it the other way. They
  widened the message delay to 300 milliseconds so that a writer would finish its whole block
  before anyone else's first line arrived. That produces an interleaving, but it produces it by
  running the protocol under a delay no reported experiment uses, and a configuration that only
  the test knows about is the kind of thing that later turns out to have been in force
  everywhere. Here the run keeps the delay the evaluation reports, and the writers collide
  because the plan schedules them to.

  What makes that work is the authoring window. Every writer issues its block inside a window
  narrower than the smallest message delay, so no writer can have heard from another before it
  has finished. `author_window_ms` is that window and it defaults to three milliseconds, against
  a reported delay whose lower bound is five. A workload that wants the opposite, a block that
  arrives while an earlier conflict is still being repaired, states a stagger wider than the
  delay instead; `:three_way_cascade` is the one that does.

  ## Running one

  `run/2` installs the run, starts the peers, drives the plan, waits for the network to go
  quiet, and reads every replica. It leaves the peers alive, because some properties need a
  second look after a further window, and the caller ends them with `teardown/1`.
  """

  require Syncordian.Metadata

  alias Syncordian.Byzantine
  alias Syncordian.Info
  alias Syncordian.Workloads.Checks
  alias Syncordian.Metadata
  alias Syncordian.Network
  alias Syncordian.OpTimes
  alias Syncordian.Peer
  alias Syncordian.Run

  @typedoc "A single edit or network action, and who performs it."
  @type step ::
          {:insert, peer_id :: non_neg_integer(), content :: String.t(),
           test_index :: pos_integer()}
          | {:append_block, peer_id :: non_neg_integer(), contents :: [String.t()]}
          | {:append_after, peer_id :: non_neg_integer(), contents :: [String.t()],
             await_lines :: non_neg_integer()}
          | {:delete, peer_id :: non_neg_integer(), test_index :: pos_integer()}
          | {:partition, peer_id :: non_neg_integer(), boolean()}
          | :calm

  @typedoc "A step and the millisecond after the start at which it is issued."
  @type scheduled :: {non_neg_integer(), step()}

  @type plan :: %{
          name: atom(),
          peers: pos_integer(),
          seed: non_neg_integer(),
          params: map(),
          steps: [scheduled()],
          settle_floor_ms: non_neg_integer(),
          scenario: Run.scenario(),
          asserts: [atom()]
        }

  @catalogue [
    :same_position_inserts,
    :overlapping_blocks,
    :identical_content_blocks,
    :delete_insert_races,
    :long_offline,
    :post_gc_replay,
    :three_way_cascade
  ]

  # The window inside which every writer of a simultaneous workload issues its block. It has to
  # be smaller than the smallest message delay, or a writer may hear from another before it has
  # finished authoring and the two blocks will no longer share an authored interval.
  @author_window_ms 3

  # How often a writer outside the contending fraction looks at its replica while waiting for the
  # lines it has to append past. How long it will wait is not fixed here: it is half the budget the
  # whole drive is given, so the writer gives up before the driver does and the run reports its
  # properties rather than dying (`drive/3`).
  #
  # This replaced a fixed 120 millisecond delay, which was a constant standing in for "by now the
  # lines before mine have arrived". That is true at eight writers and false at sixteen, where the
  # contending traffic is four times larger and still in flight at 120ms, so the tail writer read a
  # document that was still moving and appended into the middle of somebody's block.
  @tail_sample_ms 100

  # How long a replica is given to answer a request for its document. A peer answers from its
  # message loop, so a peer working through a deep mailbox answers late, and at the top of a
  # scalability ladder the mailboxes are very deep indeed.
  @document_timeout_ms 60_000

  # How long a peer is given to process the messages that its own start sends it, before any
  # edit is issued. A peer's first message installs its identity, its progress vector, and its
  # seeded generator; an edit that arrived before it would be answered by a peer that does not
  # yet know who it is.
  @start_settle_ms 300

  @doc "The workloads this module can build."
  @spec catalogue() :: [atom()]
  def catalogue, do: @catalogue

  @doc """
  The run scenario a workload needs.

  Most workloads say nothing about the environment and run under whatever the caller configured.
  `:post_gc_replay` is different: the messages it has to survive are genuine ones, captured and
  returned later, and only the distrusted node can produce those. Naming the scenario here keeps
  a workload from being run under an environment that cannot construct it.
  """
  @spec scenario_for(atom()) :: Run.scenario() | nil
  def scenario_for(:post_gc_replay), do: :post_collection_replay
  def scenario_for(_name), do: nil

  @doc """
  Whether a workload is meaningless without a distrusted node.

  The same reasoning as `Syncordian.Run.requires_adversary?/1`: a run named after an execution
  that had nobody to carry it out reports a property it never tested.
  """
  @spec requires_adversary?(atom()) :: boolean()
  def requires_adversary?(:post_gc_replay), do: true
  def requires_adversary?(_name), do: false

  @doc """
  The protocol settings a workload has to change to be observable at all.

  A replica asks for an operation it is missing once the dependency has waited longer than a
  threshold counted in edits, and that threshold is a thousand edits, which is right for a replay
  of a real history and useless in a workload of a dozen. Lowering it does not change what the
  recovery path does, only how soon it is willing to do it, and the run records the value it used.

  Only `:long_offline` needs this. `teardown/1` removes every key listed by `env_keys/0`, so a
  workload cannot leave a threshold in force for whatever runs next.
  """
  @spec env_tuning(atom()) :: keyword()
  def env_tuning(:long_offline), do: [fetch_soft_threshold: 1, fetch_sweep_interval_ms: 20]
  def env_tuning(_name), do: []

  @doc "The application settings any workload may tune, and that `teardown/1` restores."
  @spec env_keys() :: [atom()]
  def env_keys, do: [:fetch_soft_threshold, :fetch_sweep_interval_ms]

  @doc """
  Builds the plan for a named workload.

  Options are `:peers`, `:ops_per_peer`, `:seed`, `:author_window_ms`, and the parameters the
  individual workloads read. Raises on an unknown name rather than falling back to something
  plausible, because a driver that silently ran a different workload than the one it was asked
  for would report the wrong thing under the right label.
  """
  @spec plan(atom(), keyword()) :: plan()
  def plan(name, opts \\ [])

  def plan(name, opts) when name in @catalogue do
    peers = Keyword.get(opts, :peers, default_peers(name))
    seed = Keyword.get(opts, :seed, 1)
    ops = Keyword.get(opts, :ops_per_peer, default_ops(name))

    if peers < minimum_peers(name) do
      raise ArgumentError,
            "workload #{inspect(name)} needs at least #{minimum_peers(name)} peers, got #{peers}"
    end

    params =
      opts
      |> Keyword.take([:conflict_rate, :offline_ms, :stagger_ms, :author_window_ms, :replay_ms])
      |> Map.new()
      |> Map.put_new(:author_window_ms, @author_window_ms)

    state = %{
      name: name,
      peers: peers,
      ops: ops,
      params: params,
      rand: :rand.seed_s(:exsss, {seed, :erlang.phash2(name), peers})
    }

    {steps, floor_ms} = build(name, state)

    %{
      name: name,
      peers: peers,
      seed: seed,
      params: Map.put(params, :ops_per_peer, ops),
      steps: Enum.sort_by(steps, fn {offset, _step} -> offset end),
      settle_floor_ms: floor_ms,
      scenario: scenario_for(name),
      asserts: asserts(name)
    }
  end

  def plan(name, _opts) do
    raise ArgumentError,
          "unknown workload #{inspect(name)}, expected one of #{inspect(@catalogue)}"
  end

  @doc """
  The properties a workload asserts, beyond byte-identical convergence.

  Every workload asserts convergence, so it is not listed. What is listed is what each one adds,
  and `:exercised` is the important entry: it demands that the workload actually constructed the
  interleaving it is named after. Without it a workload could pass while building nothing, which
  is the state the git replay is in.
  """
  @spec asserts(atom()) :: [atom()]
  def asserts(:same_position_inserts), do: [:complete, :no_aura_residue]
  def asserts(:overlapping_blocks), do: [:complete, :contiguous, :exercised, :no_repair_pending]
  def asserts(:identical_content_blocks), do: [:complete, :exercised, :no_repair_pending]
  def asserts(:delete_insert_races), do: [:complete, :no_resurrection, :no_live_duplicates]

  # `:long_offline` asserts convergence, completeness, and that the recovery path ran, and it
  # deliberately does not assert that every line is settled. A replica that returns from an outage
  # recovers the operations it missed, because those are held in their author's origin log and can
  # be asked for. It does not recover the acknowledgements that were broadcast while it was away,
  # because acknowledgements are not logged and there is nothing to ask for. The lines involved
  # therefore stay at `:aura` at that one replica, with the absent peer's entry still false in
  # their checklist, while every other replica has them settled.
  #
  # This is a limitation of the recovery path rather than a failure of the run: the content of the
  # document converges and the reader sees the same text everywhere, while the settlement state
  # does not converge. `Checks.settlement_report/1` reports it with its witness instead of hiding
  # it, and closing it would need acknowledgements to be recoverable, which is a change to the
  # protocol and not to this suite.
  def asserts(:long_offline), do: [:complete, :recovered]
  def asserts(:post_gc_replay), do: [:complete, :no_resurrection, :no_aura_residue, :replayed]

  # Termination is asserted as a fixed point rather than as a bound on a ratio. An earlier version
  # of this compared re-placements issued against interleavings observed and required the quotient to
  # stay under the number of writers, which measured nothing: the two counters are summed over the
  # replicas on different bases, since every replica observes the same interleaving while only the
  # losing writer re-issues. `:no_repair_pending` is the honest statement, because the detector is a
  # pure function of the document and an empty result means there is no repair left to make. The
  # amplification is reported as a distribution instead of being bounded by an invented rule.
  def asserts(:three_way_cascade),
    do: [:complete, :contiguous, :exercised, :no_repair_pending]

  ##########################################################################################
  # The seven workloads
  ##########################################################################################

  # Every writer inserts a single line naming the same live position, so every writer allocates
  # into the one empty interval between the two boundary lines. This is the smallest possible
  # position collision, and the only thing that can separate the results is the identity each
  # line carries.
  defp build(:same_position_inserts, state) do
    {steps, _state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)
        {[{offset, {:insert, peer, label(peer, 0), 1}}], state}
      end)

    {steps, 0}
  end

  # Every contending writer appends a block of consecutive lines from the same starting document,
  # so all of those blocks are anchored on the same authored interval and every pair of them
  # overlaps.
  #
  # The conflict rate is a fraction of the writers, not of each writer's lines, and the reason is
  # a property of the position identifiers. Only the head of a block sits in the shared interval.
  # Every later line of a block is anchored between the writer's own previous line and the
  # boundary, an interval no other writer names, so a block contends as a whole or not at all and
  # there is no such thing as a partly contending block. A writer outside the contending fraction
  # waits until the shared lines have reached it and then appends past all of them, which is an
  # interval nobody else is in. That is what lets the scalability sweep hold the contention fixed
  # while it varies the number of writers.
  defp build(:overlapping_blocks, state) do
    rate = Map.get(state.params, :conflict_rate, 1.0)
    contending = max(2, min(state.peers, round(state.peers * rate)))

    {steps, _state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)

        if peer < contending do
          {block(peer, state.ops, offset), state}
        else
          # Every line authored by a writer before this one: the contending blocks, and the tail
          # blocks of the writers ahead of it in the tail. Waiting for its own predecessors is what
          # keeps the tail writers out of each other's way, which is the second half of "contends
          # with nobody" and the half that is easy to miss. Waiting only for the contending lines
          # leaves sixteen tail writers appending past the same end of the same document at the same
          # moment, and a writer that holds five lines of another tail block appends into the middle
          # of it. That reads afterwards as a deliberate nested edit, because its authored parents
          # are two adjacent lines of that block, and a deliberate nested edit is precisely what the
          # repair rule is required not to touch.
          {tail_block(peer, state.ops, offset, peer * state.ops), state}
        end
      end)

    {steps, 0}
  end

  # As above, except every writer authors byte-identical content. Convergence cannot be reached
  # by noticing that two lines say the same thing, because every line says the same thing, so
  # what has to order them is the identity of the operation that wrote them.
  defp build(:identical_content_blocks, state) do
    {steps, _state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)

        steps =
          for index <- 0..(state.ops - 1),
              do: {offset, {:insert, peer, "shared line #{index}", index + 1}}

        {steps, state}
      end)

    {steps, 0}
  end

  # Overlapping blocks, and then a delete aimed at a line while a re-placement is moving it. The
  # delete is issued after the blocks have been broadcast but before the network has settled, so
  # it races the repair rather than following it. The last writer performs the delete, and it
  # names a position rather than a line, so which line it removes is a fact about the run.
  defp build(:delete_insert_races, state) do
    {inserts, state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)
        {block(peer, state.ops, offset), state}
      end)

    {delay, _state} = uniform(state, 5, 25)
    deleter = state.peers - 1

    {inserts ++ [{state.params.author_window_ms + delay, {:delete, deleter, 2}}], 0}
  end

  # One writer is cut off in both directions while the others author, and is reconnected
  # afterwards. Nothing that was sent during the outage is broadcast again, so the only way any
  # replica can hold the operations it missed is to have asked their origin for them.
  #
  # The editing continues after the outage, on both sides, and that is a requirement rather than
  # decoration. A replica notices that it fell behind when a later message names something it does
  # not hold, so without traffic after the window nothing reveals the gap. It then asks only once
  # the waiting dependency has aged past a threshold counted in that replica's own edits, so a
  # replica that falls silent never ages its suspensions and never asks. Recovery here is
  # triggered by continued use, not by a timer. That is a real property of the current protocol,
  # not a property of this workload: unprompted anti-entropy would remove the requirement, and the
  # protocol does not have it yet.
  defp build(:long_offline, state) do
    offline_ms = Map.get(state.params, :offline_ms, 400)
    victim = 0

    {inserts, state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)
        base = if peer == victim, do: 20, else: 20 + offset
        {block(peer, state.ops, base), state}
      end)

    control = [
      {0, {:partition, victim, true}},
      {offline_ms, {:partition, victim, false}}
    ]

    # The traffic that reveals the gap, and then the edits that age it. Every replica takes part,
    # because after a two-way outage every replica is behind on something.
    after_outage =
      for peer <- 0..(state.peers - 1),
          {tag, delay} <- [{:reveal, 60}, {:nudge_a, 160}, {:nudge_b, 260}],
          do: {offline_ms + delay, {:append_block, peer, [label(peer, tag)]}}

    {control ++ inserts ++ after_outage, offline_ms + 900}
  end

  # Genuine messages, captured by the distrusted node and broadcast again unchanged after the
  # replicas have stopped remembering the operations they carry. These pass every check, which is
  # the point of them, so what has to answer them is the identity every operation carries and the
  # fact that a deletion is recorded rather than performed. A line is deleted deliberately so
  # that one of the replayed inserts is an insert whose line no longer exists.
  defp build(:post_gc_replay, state) do
    {inserts, state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)
        {block(peer, state.ops, offset), state}
      end)

    replay_ms = Map.get(state.params, :replay_ms, 5_000)

    # The delete waits until the inserts have settled, so the replay that follows it is a replay
    # of an insert whose line is already a tombstone.
    delete = [{400, {:delete, 0, 1}}]

    {inserts ++ delete, replay_ms + 2_000}
  end

  # Three or more writers arranged so that repairing one conflict creates the next. The first two
  # blocks collide inside the authoring window, and each later block is issued a stagger wider
  # than the message delay, so it arrives while the earlier repair is still in flight. The
  # assertion is that this terminates, and inside the bound the repair rule gives it.
  defp build(:three_way_cascade, state) do
    stagger = Map.get(state.params, :stagger_ms, 80)

    # Exactly three writers, whatever the size of the network. The remaining peers are replicas
    # that receive the traffic and acknowledge it but author nothing.
    #
    # Holding the number of writers fixed is what keeps the workload's name true. An earlier
    # version staggered every peer by its own index, which at three peers was a cascade and at
    # eight was something else entirely: writers three upwards each arrived long after the others,
    # anchored on whatever they had already received, and contended with nobody. The workload then
    # measured a different execution at every network size while reporting one name.
    {steps, _state} =
      each_writer(state, fn peer, state ->
        {offset, state} = jitter(state)

        cond do
          # The first two contend inside the authoring window, so neither has heard from the other.
          peer < 2 ->
            {block(peer, state.ops, offset), state}

          # The third arrives a stagger later, wider than the largest message delay, so its block
          # lands while the first repair is still in flight. That is what turns one repair into
          # two.
          peer == 2 ->
            {block(peer, state.ops, offset + stagger), state}

          true ->
            {[], state}
        end
      end)

    {steps, 3 * stagger}
  end

  # A block of `ops` lines by one writer, its head anchored on the interval every other
  # contending writer also targets. Appending the i-th line means naming position i + 1: a local
  # edit lands before the position it names, and the boundary line counts as position zero, so
  # naming i would anchor every line on the writer's own first line and the blocks would never
  # share an interval at all.
  defp block(peer, ops, offset) do
    for index <- 0..(ops - 1),
        do: {offset, {:insert, peer, label(peer, index), index + 1}}
  end

  # A block appended past every line the writer can see. Where `block/3` names a fixed position and
  # therefore contends, this one names the end of the document as it stands when the block begins, so
  # it contends with nobody.
  #
  # The whole block is one step, and the tail is resolved once for it rather than once per line. That
  # matters: resolving per line meant a foreign line arriving mid-block moved the target, so the
  # writer's later lines were authored after that foreign line and its own lines were genuinely no
  # longer one authored block. Contiguity then failed for a reason that was a property of the
  # workload rather than of the protocol.
  #
  # Resolving the tail once is necessary and it is not sufficient. It fixes the target while the
  # block is being issued and says nothing about the document the target was read from, and reading
  # it too early is the same defect one step earlier: a writer that appends "past everything" while
  # the contending lines are still arriving appends past what it happens to hold, which is the middle
  # of the document a moment later. So the step carries what the writer is waiting for, `await`, the
  # number of live lines every writer before it will have produced, and the writer reads its tail
  # only once it holds them and the repairs they caused have finished. That is what the workload
  # meant by "waits until the shared lines have reached it": a condition on the replica, not an
  # interval on a clock, which is the only form of it that survives a change in the size of the
  # network.
  defp tail_block(peer, ops, offset, await) do
    [{offset, {:append_after, peer, Enum.map(0..(ops - 1), &label(peer, &1)), await}}]
  end

  defp label(peer, index), do: "p#{peer}-#{index}"

  # Walks every writer, threading the generator state so that the whole plan is one deterministic
  # function of the seed.
  defp each_writer(state, builder) do
    Enum.reduce(0..(state.peers - 1), {[], state}, fn peer, {steps, state} ->
      {new_steps, state} = builder.(peer, state)
      {steps ++ new_steps, state}
    end)
  end

  defp jitter(state), do: uniform(state, 0, state.params.author_window_ms)

  defp uniform(state, low, high) when high <= low, do: {low, state}

  defp uniform(state, low, high) do
    {value, rand} = :rand.uniform_s(high - low + 1, state.rand)
    {low + value - 1, %{state | rand: rand}}
  end

  defp default_peers(:three_way_cascade), do: 3
  defp default_peers(_name), do: 3

  defp default_ops(:same_position_inserts), do: 1
  defp default_ops(_name), do: 3

  defp minimum_peers(:three_way_cascade), do: 3
  defp minimum_peers(:long_offline), do: 2
  defp minimum_peers(:delete_insert_races), do: 2
  defp minimum_peers(_name), do: 2

  ##########################################################################################
  # Running a plan
  ##########################################################################################

  @doc """
  Installs a run, starts the peers, drives the plan, and reads every replica.

  Returns the peers it started, the text every replica holds, the merged network metadata, the
  operation latency samples, and the two lists the properties are checked against: what was
  authored, and what was deleted.

  The peers are left running. Some properties need a second observation after a further window,
  and `teardown/1` ends them.
  """
  @spec run(plan(), keyword()) :: map()
  def run(plan, opts \\ []) do
    if Keyword.get(opts, :install, true), do: install!(plan, opts)

    pids = start_peers(plan.peers)
    adversaries = start_adversaries(adversary_count(plan, opts))
    {authored, deleted} = drive(plan, pids, opts)

    observation =
      observe(pids, Keyword.put_new(opts, :floor_ms, plan.settle_floor_ms))

    Map.merge(observation, %{
      plan: plan,
      pids: pids,
      adversaries: adversaries,
      authored: authored,
      deleted: deleted
    })
  end

  @doc """
  Starts the distrusted nodes, before any honest peer has broadcast.

  The order matters and it is easy to get wrong. An honest peer works out who it broadcasts to the
  first time it sends anything and then keeps that set, so a distrusted node registered after the
  first edit observes no traffic at all. It would report a clean run under an alarming name, which
  is worse than reporting a failure.

  A distrusted node holds no boundary secret. Its identifiers start well above the honest range,
  as the supervisor's do, so a large network cannot collide with them.
  """
  @spec start_adversaries(non_neg_integer()) :: [{non_neg_integer(), pid()}]
  def start_adversaries(0), do: []

  def start_adversaries(count) do
    adversaries =
      for index <- 1..count do
        id = 1_000_000 + index
        Syncordian.ByzantinePeer.start_byzantine_peer(id)
        {id, :global.whereis_name(id)}
      end

    Process.sleep(100)
    adversaries
  end

  # How many distrusted nodes this run needs. An explicit option wins; otherwise the count comes
  # from the adversary profile, and a workload that cannot be constructed without one gets one.
  defp adversary_count(plan, opts) do
    explicit =
      case Keyword.get(opts, :adversary) do
        %{count: count} -> count
        _ -> nil
      end

    cond do
      is_integer(explicit) and explicit > 0 -> explicit
      requires_adversary?(plan.name) -> 1
      true -> 0
    end
  end

  @doc """
  Publishes the run description, the network, the boundary secret, and the latency table.

  The order is the one `Syncordian.Supervisor.init/2` uses and it is load-bearing. A peer bakes
  the boundary secret into its two boundary lines when it starts, so a secret installed after a
  peer exists is a secret that peer does not hold.
  """
  @spec install!(plan(), keyword()) :: Run.t()
  def install!(plan, opts \\ []) do
    Run.reset!()

    run =
      Run.install!(
        seed: Keyword.get(opts, :seed, plan.seed),
        scenario: Keyword.get(opts, :scenario) || plan.scenario || :baseline,
        delay: Keyword.get(opts, :delay, {:uniform, 5, 50}),
        root: Keyword.get(opts, :root, "debug"),
        adversary: Keyword.get(opts, :adversary),
        workload: workload_description(plan)
      )

    Enum.each(env_tuning(plan.name), fn {key, value} ->
      Application.put_env(:syncordian, key, value)
    end)

    Network.create()
    Byzantine.generate_boundary_secret() |> Byzantine.install_boundary_secret!()
    OpTimes.create()

    run
  end

  @doc "The workload block this plan records in the run manifest."
  @spec workload_description(plan()) :: map()
  def workload_description(plan) do
    %{
      kind: :synthetic,
      crdt: :syncordian,
      name: plan.name,
      peers: plan.peers,
      ops_per_peer: plan.params[:ops_per_peer],
      conflict_rate: Map.get(plan.params, :conflict_rate, 1.0)
    }
  end

  @doc """
  Starts every peer of the network, and waits for each to answer its own first message.

  All of them start before any edit is issued. A peer caches the set of peers it broadcasts to
  the first time it sends, and the size of the network fixes both the length of the progress
  vector and the width of the response checklist, so a peer that arrives later is not a member
  of this run.
  """
  @spec start_peers(pos_integer()) :: [{non_neg_integer(), pid()}]
  def start_peers(count) do
    pids = for id <- 0..(count - 1), do: {id, Peer.start(id, count)}
    Process.sleep(@start_settle_ms)
    pids
  end

  @doc """
  Issues the plan's steps, each writer in its own process.

  The writers share one starting instant and nothing else. There is no barrier between them,
  which is the whole difference between this and the commit replay.

  Returns what was authored and what was deleted. A delete names a position, so the content it
  removes is only known while the run is happening: the writer reads its own replica immediately
  before issuing the delete and reports the line it is about to remove. Recovering that
  afterwards, by subtracting what is live from what was authored, would make the
  no-resurrection property restate its own premise.
  """
  @spec drive(plan(), [{non_neg_integer(), pid()}], keyword()) :: {[String.t()], [String.t()]}
  def drive(plan, pids, opts \\ []) do
    # Scaled with the network for the same reason the settle budget is: a writer that waits on its
    # replica waits as long as the traffic takes, and the traffic grows with the cube of the network.
    timeout = Keyword.get(opts, :drive_timeout_ms, settle_budget(plan.peers))
    tail_deadline = div(timeout, 2)
    by_peer = Map.new(pids)
    parent = self()

    writers =
      for {peer, steps} <- writer_steps(plan), steps != [] do
        pid = Map.fetch!(by_peer, peer)
        spawn_link(fn -> writer(parent, peer, pid, steps, tail_deadline) end)
      end

    controller = spawn_link(fn -> controller(parent, control_steps(plan)) end)
    processes = [controller | writers]

    start = System.monotonic_time(:millisecond)
    Enum.each(processes, &send(&1, {:go, start}))

    collect_reports(length(processes), timeout, {[], []})
  end

  @doc """
  Waits for the network to go quiet, then reads every replica.

  Quiet is two conditions, and one of them alone is not enough. Every mailbox has to be empty on
  two consecutive samples, and then the text every replica holds has to be the same on two
  consecutive reads. An empty mailbox does not mean an idle network, because a message whose
  delay has not elapsed is held in a timer and is in no mailbox at all.
  """
  @spec observe([{non_neg_integer(), pid()}], keyword()) :: map()
  def observe(pids, opts \\ []) do
    floor_ms = Keyword.get(opts, :floor_ms, 0)
    timeout = Keyword.get(opts, :settle_timeout_ms, settle_budget(length(pids)))

    if floor_ms > 0, do: Process.sleep(floor_ms)

    settled = settle(pids, timeout)

    %{
      settled: settled,
      documents: Map.new(pids, fn {peer, pid} -> {peer, document(pid)} end),
      contents: Map.new(pids, fn {peer, pid} -> {peer, content(pid)} end),
      metadata: metadata(pids),
      latency: OpTimes.samples()
    }
  end

  # How long a run is given to go quiet, scaled to the traffic it generates. Every insert is
  # acknowledged by every replica and every acknowledgement is broadcast to every replica, so the
  # messages a run exchanges grow with the cube of the network. A fixed budget is therefore generous
  # at the bottom of a scalability ladder and wrong at the top, and what it produces there is not a
  # slow run but a run reported as diverged, because the replicas are read while they are still
  # exchanging.
  #
  # The factor is set from measurement rather than from the message count, because the repair is what
  # the traffic is made of once enough writers contend and the repair is not in the message count. At
  # sixty-four writers with half of them contending, a run exchanges 15.7 million messages and goes
  # quiet after 898 seconds. The cube alone allows 262, which fails it; eight times the cube allows
  # 2097, which is the same run reported correctly.
  #
  # This is a deadline and not a wait. A run that goes quiet returns immediately, so the margin costs
  # nothing except the time a genuinely stuck run takes to admit it.
  @spec settle_budget(pos_integer()) :: pos_integer()
  def settle_budget(peers), do: max(120_000, 8 * peers * peers * peers)

  @doc """
  Ends every peer of the run, and releases the names they registered.

  Releasing the names matters when more than one workload runs inside one virtual machine: a
  peer identifier is a registered name, and the next workload cannot claim a name the previous
  one still holds.
  """
  @spec teardown([{non_neg_integer(), pid()}]) :: :ok
  def teardown(pids) do
    Enum.each(pids, fn {peer, pid} ->
      if is_pid(pid), do: Process.exit(pid, :kill)
      :global.unregister_name(peer)
    end)

    Process.sleep(100)
    Network.reconnect_all()
    Enum.each(env_keys(), &Application.delete_env(:syncordian, &1))
    :ok
  end

  @doc "The text one replica holds, live lines only, in document order."
  @spec content(pid()) :: String.t()
  def content(pid), do: pid |> document() |> Info.string_document_content()

  @doc """
  One replica's document, as line records, tombstones and boundary lines included.

  Raises if the replica does not answer. It used to return an empty list, which is not a document
  a replica can hold: every document has its two boundary lines. The empty list was then read as
  the replica's contents, and at sixty-four writers, where a busy peer needs longer than the old
  five second limit to answer, the run died inside the function that strips the boundary lines
  rather than saying which replica had not replied.

  Stale answers to an earlier request are drained first, for the same reason `hash/1` drains them:
  a reply that arrives after its caller stopped waiting is still in the mailbox, and reading it as
  this request's answer would report one moment's document as another's.
  """
  @spec document(pid()) :: list()
  def document(pid) do
    drain_documents()
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> document
    after
      @document_timeout_ms ->
        raise "replica #{inspect(pid)} did not answer a document request in " <>
                "#{@document_timeout_ms}ms"
    end
  end

  defp drain_documents do
    receive do
      {:receive_live_view_document, _document, _handler} -> drain_documents()
    after
      0 -> :ok
    end
  end

  @doc """
  The network's metadata, merged over every peer.

  Taken from the peers directly rather than through the supervisor, because a synthetic workload
  has no supervisor. The merge follows each field's own rule: totals add, high-water marks take
  the larger, and sample lists join.
  """
  @spec metadata([{non_neg_integer(), pid()}]) :: map()
  def metadata(pids) do
    pids
    |> Enum.reduce(Metadata.metadata(), fn {_peer, pid}, acc ->
      send(pid, {:request_metadata, self()})

      receive do
        {:receive_metadata_from_peer, peer_metadata, _pid} ->
          Metadata.merge_metadata(acc, peer_metadata)
      after
        5_000 -> acc
      end
    end)
    |> Metadata.report()
  end

  ##########################################################################################
  # Quiescence
  ##########################################################################################

  @doc """
  Two consecutive quiet samples, then two consecutive identical reads of every replica.
  """
  @spec settle([{non_neg_integer(), pid()}], non_neg_integer()) :: :ok | {:error, term()}
  def settle(pids, timeout \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- await_quiet(deadline, 0), do: await_fixpoint(pids, deadline, :none, 0)
  end

  @sample_interval_ms 250

  defp await_quiet(deadline, streak) do
    cond do
      streak >= 2 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, {:backlog_never_emptied, backlog()}}

      true ->
        Process.sleep(@sample_interval_ms)
        await_quiet(deadline, if(backlog() == 0, do: streak + 1, else: 0))
    end
  end

  # The summed mailbox depth of every registered process. A name whose process has already ended
  # answers `:undefined` rather than a count, and that is not a backlog.
  #
  # The item is `:message_queue_len`. It was `:message_queue_length` until the sweep at sixteen
  # writers made the difference visible: that name is not an item `:erlang.process_info/2` accepts,
  # so every call raised, the rescue below turned the whole sum into zero, and `await_quiet/2` read
  # an idle network on its first two samples whatever the mailboxes held. Quiescence was then decided
  # by the fixpoint check alone, which is the condition the module doc says is not sufficient by
  # itself: a replica can hold the same text twice in a row while operations are still in flight.
  defp backlog do
    :global.registered_names()
    |> Enum.map(&:global.whereis_name/1)
    |> Enum.filter(&is_pid/1)
    |> Enum.map(fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} -> length
        _ended -> 0
      end
    end)
    |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  defp await_fixpoint(pids, deadline, previous, streak) do
    hashes = Map.new(pids, fn {peer, pid} -> {peer, hash(pid)} end)

    cond do
      streak >= 1 and hashes == previous ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :no_fixpoint}

      hashes == previous ->
        Process.sleep(@sample_interval_ms)
        await_fixpoint(pids, deadline, hashes, streak + 1)

      true ->
        Process.sleep(@sample_interval_ms)
        await_fixpoint(pids, deadline, hashes, 0)
    end
  end

  # A replica's own digest of the text it holds, answered by the peer itself so that no document
  # has to cross the wire to be compared. Stale answers to an earlier request are drained first;
  # they carry a reference nobody is waiting for and would otherwise be read as this one's.
  defp hash(pid) do
    drain_hashes()
    ref = make_ref()
    send(pid, {:request_content_hash, self(), ref})

    receive do
      {:content_hash, ^ref, hash} -> hash
    after
      5_000 -> :timeout
    end
  end

  defp drain_hashes do
    receive do
      {:content_hash, _ref, _hash} -> drain_hashes()
    after
      0 -> :ok
    end
  end

  ##########################################################################################
  # The writers
  ##########################################################################################

  defp writer_steps(plan) do
    plan.steps
    |> Enum.flat_map(fn
      {offset, {:insert, peer, _content, _index} = step} -> [{peer, {offset, step}}]
      {offset, {:append_block, peer, _contents} = step} -> [{peer, {offset, step}}]
      {offset, {:append_after, peer, _contents, _await} = step} -> [{peer, {offset, step}}]
      {offset, {:delete, peer, _index} = step} -> [{peer, {offset, step}}]
      _control -> []
    end)
    |> Enum.group_by(fn {peer, _step} -> peer end, fn {_peer, step} -> step end)
  end

  defp control_steps(plan) do
    Enum.filter(plan.steps, fn
      {_offset, {:partition, _peer, _cut?}} -> true
      {_offset, :calm} -> true
      _edit -> false
    end)
  end

  defp writer(parent, peer, pid, steps, tail_deadline) do
    start = await_go()

    {authored, deleted} =
      Enum.reduce(steps, {[], []}, fn {offset, step}, {authored, deleted} ->
        sleep_until(start, offset)

        case step do
          {:insert, ^peer, content, index} ->
            Peer.insert(pid, content, 0, index, 0, 0)
            {[content | authored], deleted}

          {:append_block, ^peer, contents} ->
            {append(pid, contents, authored), deleted}

          {:append_after, ^peer, contents, await} ->
            await_tail(pid, await, tail_deadline)
            {append(pid, contents, authored), deleted}

          {:delete, ^peer, index} ->
            target = live_content_at(pid, index)
            Peer.delete_line(pid, 0, index, 0, 0)
            {authored, if(target, do: [target | deleted], else: deleted)}
        end
      end)

    send(parent, {:workload_report, Enum.reverse(authored), Enum.reverse(deleted)})
  end

  defp controller(parent, steps) do
    start = await_go()

    Enum.each(steps, fn {offset, step} ->
      sleep_until(start, offset)

      case step do
        {:partition, peer, cut?} -> Network.partition(peer, cut?)
        :calm -> Network.calm()
      end
    end)

    send(parent, {:workload_report, [], []})
  end

  defp await_go do
    receive do
      {:go, start} -> start
    after
      30_000 -> System.monotonic_time(:millisecond)
    end
  end

  defp sleep_until(start, offset) do
    remaining = start + offset - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(remaining)
  end

  # Issues a block past the end of the document. The tail is read once, and the block chains from
  # it, so the writer's lines form one authored block whatever arrives while it is being issued.
  defp append(pid, contents, authored) do
    base = live_count(pid)

    contents
    |> Enum.with_index()
    |> Enum.each(fn {content, index} -> Peer.insert(pid, content, 0, base + index + 1, 0, 0) end)

    Enum.reverse(contents) ++ authored
  end

  # Waits until this replica holds the lines the workload said to wait for and owes no repair, so
  # that the tail read next is the tail of a document that has stopped moving.
  #
  # Two conditions, and each answers a different way of appending into the middle of somebody's
  # block. The count is what says the contending writers' lines have arrived: append before it and
  # the end of the document is wherever those lines have got to so far. The outstanding-repair check
  # is what says they have stopped moving: a re-placement retracts a block and re-issues it
  # elsewhere, so a tail read while one is in flight can be anchored on a line that is about to
  # become a tombstone, and the block lands wherever that line used to be.
  #
  # The deadline is a backstop, not a schedule. Returning on it rather than raising keeps a run that
  # missed the condition observable: it will fail its properties and say so, which is more use than
  # a writer that died.
  defp await_tail(pid, expected, budget_ms) do
    await_tail_until(pid, expected, System.monotonic_time(:millisecond) + budget_ms)
  end

  defp await_tail_until(pid, expected, deadline) do
    document = document(pid)

    ready? =
      Enum.count(document, &Checks.live?/1) >= expected and
        Syncordian.Interleaving.detect_replacements(document) == []

    unless ready? or System.monotonic_time(:millisecond) > deadline do
      Process.sleep(@tail_sample_ms)
      await_tail_until(pid, expected, deadline)
    end
  end

  # The content a delete is about to remove. A delete names the position of a live line, counting
  # the boundary line as position zero, which is the same translation the peer applies locally.
  defp live_content_at(pid, index) do
    pid
    |> live_lines()
    |> Enum.at(index - 1)
    |> case do
      nil -> nil
      line -> Syncordian.Line_Object.get_content(line)
    end
  end

  # How many lines a replica currently holds, so that an append can name the end of the document.
  defp live_count(pid), do: pid |> live_lines() |> length()

  defp live_lines(pid), do: pid |> document() |> Enum.filter(&Checks.live?/1)

  defp collect_reports(0, _timeout, {authored, deleted}),
    do: {Enum.sort(authored), Enum.sort(deleted)}

  defp collect_reports(pending, timeout, {authored, deleted}) do
    receive do
      {:workload_report, new_authored, new_deleted} ->
        collect_reports(
          pending - 1,
          timeout,
          {authored ++ new_authored, deleted ++ new_deleted}
        )
    after
      timeout -> raise "a writer did not report within #{timeout}ms"
    end
  end
end
