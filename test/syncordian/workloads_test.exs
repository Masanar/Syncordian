defmodule Syncordian.WorkloadsTest do
  @moduledoc """
  The workload generator, checked without a network.

  A plan is a value, so everything about it can be established here: that a seed determines it,
  that it schedules the writers the way the workload it names requires, and that its parameters
  mean what the driver assumes they mean. The executions themselves are in
  `test/syncordian/live/workloads_test.exs`, which needs peers and is therefore slow.

  The tests worth reading are the ones about the authoring window and about contention. They pin
  the two facts the whole suite rests on: that the contending writers issue their lines close
  enough together to reach the document before hearing from each other, and that they name the
  same position when they do.
  """

  use ExUnit.Case, async: true

  alias Syncordian.Workloads

  @seed 1

  # Every property `Syncordian.Workloads.Checks` can evaluate. Convergence is not here because it
  # is checked for every workload and so is never declared.
  @known_properties [
    :complete,
    :contiguous,
    :no_resurrection,
    :no_aura_residue,
    :no_repair_pending,
    :no_live_duplicates,
    :exercised,
    :recovered,
    :replayed
  ]

  describe "the catalogue" do
    test "holds the seven workloads the review asked for" do
      assert Workloads.catalogue() == [
               :same_position_inserts,
               :overlapping_blocks,
               :identical_content_blocks,
               :delete_insert_races,
               :long_offline,
               :post_gc_replay,
               :three_way_cascade
             ]
    end

    test "every workload plans, and declares only properties the checks can run" do
      # A declared property that no check implements would be silently skipped, and the workload
      # would then report a guarantee nobody evaluated.
      for name <- Workloads.catalogue() do
        plan = Workloads.plan(name, seed: @seed, peers: 3)

        assert plan.name == name
        assert plan.steps != [], "#{name} planned no steps"

        assert Workloads.asserts(name) -- @known_properties == [],
               "#{name} declares a property with no check behind it"
      end
    end

    test "an unknown workload is refused rather than silently replaced" do
      assert_raise ArgumentError, ~r/unknown workload/, fn ->
        Workloads.plan(:no_such_workload)
      end
    end

    test "a workload is refused a network smaller than the execution it describes" do
      assert_raise ArgumentError, ~r/needs at least 3 peers/, fn ->
        Workloads.plan(:three_way_cascade, peers: 2)
      end
    end
  end

  describe "determinism" do
    test "the same name, seed, and parameters give the identical plan" do
      for name <- Workloads.catalogue() do
        first = Workloads.plan(name, seed: 7, peers: 4, ops_per_peer: 3)
        second = Workloads.plan(name, seed: 7, peers: 4, ops_per_peer: 3)

        assert first == second, "#{name} is not reproducible from its seed"
      end
    end

    test "a different seed gives a different schedule" do
      # The steps themselves are fixed by the workload; what the seed varies is when each writer
      # issues them, which is what decides the order the collisions resolve in.
      offsets = fn seed ->
        Workloads.plan(:overlapping_blocks, seed: seed, peers: 6, ops_per_peer: 2).steps
        |> Enum.map(fn {offset, _step} -> offset end)
      end

      assert Enum.any?(1..12, fn seed -> offsets.(seed) != offsets.(1) end),
             "no seed in the sample changed the schedule"
    end

    test "the plan depends on no process state, so it is the same after other draws" do
      first = Workloads.plan(:three_way_cascade, seed: 3, peers: 5)
      _ = :rand.uniform(1_000)
      _ = Enum.map(1..50, fn _ -> :rand.uniform(99) end)
      second = Workloads.plan(:three_way_cascade, seed: 3, peers: 5)

      assert first == second
    end
  end

  describe "the shape of a plan" do
    test "every step names a peer inside the network" do
      for name <- Workloads.catalogue() do
        plan = Workloads.plan(name, seed: @seed, peers: 4)

        for {_offset, step} <- plan.steps, peer = peer_of(step), peer != nil do
          assert peer in 0..3, "#{name} names peer #{peer} in a network of 4"
        end
      end
    end

    test "steps are ordered by the moment they are issued" do
      for name <- Workloads.catalogue() do
        offsets =
          Workloads.plan(name, seed: @seed, peers: 4).steps
          |> Enum.map(fn {offset, _step} -> offset end)

        assert offsets == Enum.sort(offsets), "#{name} is not in issue order"
      end
    end

    test "each writer authors its block in one run of consecutive positions" do
      # Appending the i-th line of a block means naming position i + 1. Naming i instead would
      # anchor every line on the writer's own first line, and the blocks of two writers would then
      # sit in different authored intervals and never contend at all.
      plan = Workloads.plan(:overlapping_blocks, seed: @seed, peers: 3, ops_per_peer: 4)

      for peer <- 0..2 do
        positions =
          for {_offset, {:insert, ^peer, _content, index}} <- plan.steps, do: index

        assert positions == [1, 2, 3, 4], "peer #{peer} named #{inspect(positions)}"
      end
    end
  end

  describe "contention" do
    test "the contending writers all name the same position for their first line" do
      plan = Workloads.plan(:overlapping_blocks, seed: @seed, peers: 4, ops_per_peer: 3)

      heads =
        plan.steps
        |> Enum.filter(fn {_offset, step} -> match?({:insert, _, _, 1}, step) end)
        |> Enum.map(fn {_offset, {:insert, peer, _content, _index}} -> peer end)

      assert Enum.sort(heads) == [0, 1, 2, 3]
    end

    test "they issue inside a window narrower than the smallest message delay" do
      # This is the property that makes the collisions happen at all. With a delay of at least five
      # milliseconds and an authoring window of three, no writer can have heard from another before
      # it has finished its block.
      plan = Workloads.plan(:overlapping_blocks, seed: @seed, peers: 8, ops_per_peer: 3)

      offsets = for {offset, {:insert, _, _, _}} <- plan.steps, do: offset

      assert Enum.max(offsets) - Enum.min(offsets) <= 3
    end

    test "a conflict rate below one leaves some writers out of the contended interval" do
      plan =
        Workloads.plan(:overlapping_blocks,
          seed: @seed,
          peers: 8,
          ops_per_peer: 2,
          conflict_rate: 0.5
        )

      contending = for {_offset, {:insert, peer, _content, _index}} <- plan.steps, do: peer
      appending = for {_offset, {:append_after, peer, _contents, _await}} <- plan.steps, do: peer

      assert length(Enum.uniq(contending)) == 4
      assert length(Enum.uniq(appending)) == 4
      assert Enum.uniq(contending) -- Enum.uniq(appending) == Enum.uniq(contending)
    end

    test "a writer outside the contended interval waits for the contended lines, not for a delay" do
      # An appending writer has to have received the contended lines before it appends, or its
      # append lands in the very interval it is supposed to stay out of. What it waits for is those
      # lines: the step names how many there will be, so the wait holds at any size of network. An
      # earlier version waited a fixed 120 milliseconds instead, which is long enough at eight
      # writers and not at sixteen.
      plan =
        Workloads.plan(:overlapping_blocks,
          seed: @seed,
          peers: 4,
          ops_per_peer: 2,
          conflict_rate: 0.5
        )

      awaits =
        for {_offset, {:append_after, peer, _c, await}} <- plan.steps, do: {peer, await}

      # Two contending writers of two lines each, so writer 2 waits for those four lines. Writer 3
      # waits for six: the same four and writer 2's block. A tail writer that waited only for the
      # contended lines would append past the end of the document at the same moment as every other
      # tail writer, and land in the middle of one of their blocks.
      assert Enum.sort(awaits) == [{2, 4}, {3, 6}]
    end

    test "the cascade staggers its later writers by more than the delay" do
      # The opposite requirement. A cascade needs the third block to arrive while the first repair
      # is still in flight, so its stagger has to exceed the delay rather than fall inside it.
      plan = Workloads.plan(:three_way_cascade, seed: @seed, peers: 3, ops_per_peer: 3)

      by_peer =
        plan.steps
        |> Enum.group_by(fn {_offset, {:insert, peer, _content, _index}} -> peer end)
        |> Map.new(fn {peer, steps} -> {peer, steps |> Enum.map(&elem(&1, 0)) |> Enum.min()} end)

      assert by_peer[2] - by_peer[1] > 50
      assert abs(by_peer[1] - by_peer[0]) <= 3
    end
  end

  describe "the executions that need an environment" do
    test "the outage workload cuts one peer off and restores it" do
      plan = Workloads.plan(:long_offline, seed: @seed, peers: 3, offline_ms: 500)

      assert {0, {:partition, 0, true}} in plan.steps
      assert {500, {:partition, 0, false}} in plan.steps
    end

    test "the outage workload keeps every peer editing after the outage closes" do
      # Recovery is triggered by continued use: a replica asks for a missing operation only once
      # the waiting dependency has aged past a threshold counted in that replica's own edits. A
      # workload whose peers fall silent after the outage would never ask, and would then look like
      # evidence that recovery does not work.
      plan = Workloads.plan(:long_offline, seed: @seed, peers: 3, offline_ms: 500)

      after_outage =
        for {offset, {:append_block, peer, _c}} <- plan.steps, offset > 500, do: peer

      for peer <- 0..2 do
        assert Enum.count(after_outage, &(&1 == peer)) >= 2,
               "peer #{peer} stops editing after the outage and would never ask for what it missed"
      end
    end

    test "the replay workload names the scenario and the adversary it cannot run without" do
      assert Workloads.scenario_for(:post_gc_replay) == :post_collection_replay
      assert Workloads.requires_adversary?(:post_gc_replay)

      assert Workloads.plan(:post_gc_replay, seed: @seed, peers: 3).scenario ==
               :post_collection_replay
    end

    test "the replay workload waits out the window the replayed messages are held for" do
      plan = Workloads.plan(:post_gc_replay, seed: @seed, peers: 3, replay_ms: 5_000)

      assert plan.settle_floor_ms > 5_000
    end

    test "the replay workload deletes a line, so a replayed insert names a tombstone" do
      plan = Workloads.plan(:post_gc_replay, seed: @seed, peers: 3)

      assert Enum.any?(plan.steps, &match?({_offset, {:delete, _peer, _index}}, &1))
    end

    test "no other workload asks for a scenario or an adversary" do
      for name <- Workloads.catalogue() -- [:post_gc_replay] do
        assert Workloads.scenario_for(name) == nil
        refute Workloads.requires_adversary?(name)
      end
    end

    test "only the outage workload tunes the protocol, and the tuning is reversible" do
      for name <- Workloads.catalogue() -- [:long_offline] do
        assert Workloads.env_tuning(name) == []
      end

      tuned = Keyword.keys(Workloads.env_tuning(:long_offline))
      assert tuned != []
      assert tuned -- Workloads.env_keys() == []
    end
  end

  describe "the manifest a workload records" do
    test "describes itself as synthetic, and names its size" do
      plan = Workloads.plan(:overlapping_blocks, seed: 4, peers: 16, ops_per_peer: 5)
      description = Workloads.workload_description(plan)

      assert description.kind == :synthetic
      assert description.name == :overlapping_blocks
      assert description.peers == 16
      assert description.ops_per_peer == 5
    end

    test "the peer count reaches the run identifier, so two sweep points cannot collide" do
      identifier = fn peers ->
        Syncordian.Run.reset!()

        run =
          Syncordian.Run.install!(
            seed: 1,
            workload:
              Workloads.workload_description(Workloads.plan(:overlapping_blocks, peers: peers))
          )

        run.run_id
      end

      eight = identifier.(8)
      sixteen = identifier.(16)
      Syncordian.Run.reset!()

      assert eight =~ "n8"
      assert sixteen =~ "n16"
      assert eight != sixteen
    end
  end

  defp peer_of({:insert, peer, _content, _index}), do: peer
  defp peer_of({:append_block, peer, _contents}), do: peer
  defp peer_of({:delete, peer, _index}), do: peer
  defp peer_of({:partition, peer, _cut?}), do: peer
  defp peer_of(:calm), do: nil
end
