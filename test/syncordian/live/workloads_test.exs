defmodule Syncordian.Live.WorkloadsTest do
  @moduledoc """
  The seven controlled concurrent workloads, run on real peers.

  These are the executions the git replay cannot produce. The replay holds each commit until its
  author has materialized the state it was written against, so two writers never reach the same
  place in the document at the same time, and the counters that record an interleaving and its
  repair stay at zero over both histories we replay. Everything the repair protocol does is
  therefore established here and nowhere else.

  Each test runs one workload at a fixed seed and asserts the properties that workload declares.
  The properties themselves live in `Syncordian.Workloads.Checks`, so a test cannot assert a
  weaker version of one than the scripts do.

  The tests run one at a time and tear their peers down afterwards. A peer identifier is a
  registered name, so two workloads cannot hold the same network at once.
  """

  use ExUnit.Case, async: false

  alias Syncordian.Workloads
  alias Syncordian.Workloads.Checks

  @moduletag :live
  @moduletag timeout: 180_000

  # Small enough to finish quickly, large enough to contend. Three writers is the smallest network
  # in which a repair can cascade, since the second repair needs a third block to land in.
  @peers 3
  @ops 3
  @seed 1

  # The delay the evaluation reports. The workloads collide under it rather than under a widened
  # one, which is the whole difference between this suite and the earlier smoke drivers.
  @delay {:uniform, 5, 50}

  setup do
    on_exit(fn ->
      Syncordian.Run.reset!()
      Syncordian.Network.reconnect_all()
      Enum.each(Workloads.env_keys(), &Application.delete_env(:syncordian, &1))
      Syncordian.Byzantine.install_boundary_secret!({"Infimum", "Supremum"})
    end)

    :ok
  end

  describe "same-position concurrent inserts" do
    test "every writer names one position, and every line survives in one order" do
      run(:same_position_inserts, ops_per_peer: 1)
    end
  end

  describe "overlapping blocks" do
    test "three blocks contend, are repaired, and each writer's lines end up together" do
      %{results: results, metadata: metadata} = run(:overlapping_blocks)

      # The reason this suite exists. If these are zero the workload built nothing, and every other
      # assertion in the test would have passed over an execution with no interleaving in it.
      assert results.exercised == :ok
      assert metadata["conflicts_observed"] > 0
      assert metadata["replacement_issued_counter"] > 0
    end

    # Every other test here runs three writers of three lines, which is the smallest network that
    # can contend, and for a long time it was the only size the repair protocol was tested at. The
    # defects the scalability sweep found were both invisible at that size: a block stranded inside
    # another writer's block by somebody else's repair needs enough concurrent blocks for a repair
    # to move a third party's anchors, and the workload's own tail writers needed enough traffic to
    # still be in flight when they authored. Sixteen writers of eight lines produces both, so the
    # configuration the sweep reports is covered by a test rather than only by the sweep.
    @tag timeout: 300_000
    test "sixteen writers contending at half the network stay contiguous too" do
      %{results: results, metadata: metadata} =
        run(:overlapping_blocks, peers: 16, ops_per_peer: 8, conflict_rate: 0.5)

      assert results.contiguous == :ok
      assert results.no_repair_pending == :ok
      assert results.complete == :ok
      assert results.exercised == :ok
      assert metadata["replacement_issued_counter"] > 0
    end
  end

  describe "identical-content blocks" do
    test "writers authoring the same text converge, and no copy is lost or doubled" do
      %{results: results, text: text} = run(:identical_content_blocks)

      assert results.complete == :ok
      assert results.exercised == :ok

      # Nine lines from three writers of three identical lines each. A convergence rule that
      # collapsed equal content would leave three, and it would still look like agreement.
      assert length(String.split(text, "\n", trim: true)) == @peers * @ops
    end
  end

  describe "delete and insert racing each other" do
    test "a delete during a repair removes one line and revives none" do
      %{results: results, deleted: deleted, metadata: metadata} = run(:delete_insert_races)

      assert deleted != [], "the workload deleted nothing and tested nothing"
      assert results.no_resurrection == :ok

      # A move is one operation carrying a link to what it supersedes, not a delete and an insert,
      # so no replica should ever have held both copies of a moved line.
      assert metadata["live_duplicates_max"] == 0
    end
  end

  describe "a long offline period" do
    test "a replica cut off in both directions recovers by asking for what it missed" do
      %{results: results, metadata: metadata, documents: documents} =
        run(:long_offline, offline_ms: 500)

      # Nothing is rebroadcast, so holding the missing operations at the end means having asked for
      # them.
      assert results.recovered == :ok
      assert metadata["fetch_request_sent"] > 0
      assert metadata["fetch_served"] > 0

      # What recovers is the content, and this is the limit of it. Acknowledgements are not logged,
      # so the ones broadcast during the outage cannot be asked for, and the lines they belonged to
      # stay unsettled at the replica that was away while every other replica has them settled.
      # The document converges; the settlement state does not. Asserting otherwise here would be
      # asserting a property the protocol does not currently have.
      report = Checks.settlement_report(documents)
      unsettled = for {peer, %{aura: count}} <- report, count > 0, do: peer

      assert length(unsettled) <= 1,
             "settlement lagged at more than the recovered replica: #{inspect(report)}"
    end
  end

  describe "old replays after the applied-operation set is collected" do
    @tag timeout: 240_000
    test "genuine messages returned later change nothing and revive nothing" do
      %{results: results, contents: contents, deleted: deleted} =
        run(:post_gc_replay, adversary: %{count: 1})

      # These messages carry an authenticator written by an admitted peer, so the admission check
      # accepts them. What has to answer them is the identity every operation carries and the fact
      # that a deletion is recorded rather than performed.
      assert results.no_resurrection == :ok
      assert results.complete == :ok
      assert deleted != [], "no line was deleted, so no replay named a tombstone"

      for {peer, text} <- contents do
        lines = String.split(text, "\n", trim: true)

        assert lines == Enum.uniq(lines),
               "peer #{peer} holds a line twice after the replay"
      end
    end
  end

  describe "three-way repair cascades" do
    test "a repair that creates another repair still terminates, and inside its bound" do
      %{results: results, metadata: metadata} = run(:three_way_cascade)

      assert results.exercised == :ok

      # A fixed point, not a pause: the detector is a pure function of the document, so an empty
      # result means there is no repair left to make.
      assert results.no_repair_pending == :ok
      assert metadata["conflicts_observed"] > 0
    end
  end

  ##########################################################################################
  # Running one workload
  ##########################################################################################

  # Runs a workload at the fixed seed and asserts everything it declares, then hands the
  # observation back so a test can make the assertions specific to it. Every workload asserts
  # convergence, so it is checked here rather than in each test.
  defp run(name, opts \\ []) do
    plan =
      Workloads.plan(
        name,
        Keyword.merge([seed: @seed, peers: @peers, ops_per_peer: @ops], opts)
      )

    observation =
      Workloads.run(plan,
        seed: @seed,
        delay: @delay,
        root: Path.join(System.tmp_dir!(), "syncordian-workload-test"),
        adversary: opts[:adversary]
      )

    try do
      assert observation.settled == :ok,
             "the network never went quiet: #{inspect(observation.settled)}"

      results = Checks.run(plan, observation)

      assert Checks.failures(results) == [],
             "#{name} failed: #{inspect(Checks.failures(results), pretty: true, limit: :infinity)}"

      {:ok, text} = Checks.converged(observation.contents)

      Map.merge(observation, %{results: results, text: text})
    after
      Workloads.teardown(observation.pids)
    end
  end
end
