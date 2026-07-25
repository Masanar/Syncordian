defmodule Syncordian.RunConfigTest do
  @moduledoc """
  The description of a run, and the randomness it fixes.

  These pin the two properties the methodology rests on. A run reports the configuration it
  used, and a seed determines every choice the protocol and its environment make, on a
  runtime whose scheduling it cannot determine.
  """
  use ExUnit.Case, async: false

  alias Syncordian.Network
  alias Syncordian.Rng
  alias Syncordian.Run

  setup do
    on_exit(&Run.reset!/0)
    :ok
  end

  describe "the delay model" do
    test "is read from and written back to the same textual form" do
      assert Run.parse_delay("uniform:5:50") == {:uniform, 5, 50}
      assert Run.delay_to_string({:uniform, 5, 50}) == "uniform:5:50"
      assert Run.parse_delay("none") == :none
      assert Run.delay_to_string(:none) == "none"
    end

    test "refuses a specification it cannot read instead of falling back to no delay" do
      # A run that silently reverted to a quiet network while reporting a delayed one is the
      # defect this workstream exists to remove, so an unreadable value has to fail loudly.
      assert_raise ArgumentError, fn -> Run.parse_delay("uniform:5") end
      assert_raise ArgumentError, fn -> Run.parse_delay("exponential:20") end
    end

    test "a run reports the model it was installed with" do
      Run.install!(seed: 1, delay: {:uniform, 5, 50}, root: "debug")

      assert Run.delay_spec() == {:uniform, 5, 50}
      assert Run.to_map()["delay"] == "uniform:5:50"
    end
  end

  describe "the manifest" do
    test "carries every parameter the evaluation states about a run" do
      Run.install!(seed: 42, delay: {:uniform, 5, 50}, scenario: :reorder_storm, root: "debug")

      manifest = Run.to_map()

      assert manifest["seed"] == 42
      assert manifest["delay"] == "uniform:5:50"
      assert manifest["scenario"] == "reorder_storm"
      assert manifest["secret_source"] == "seed"
      assert manifest["environment"]["otp"] == System.otp_release()
      assert manifest["environment"]["elixir"] == System.version()

      # Every capability is present, including the ones this scenario leaves off, so a reader
      # can tell an attack that was tried from one that was not.
      for capability <- ~w(inject_rate replay_rate duplicate_rate reorder_rate drop_rate) do
        assert Map.has_key?(manifest["adversary"], capability)
      end
    end

    test "an unseeded run says its secret came from the system generator" do
      Run.install!(delay: :none, root: "debug")

      assert Run.to_map()["seed"] == nil
      assert Run.to_map()["secret_source"] == "system"
    end

    test "the identifier separates runs that differ in anything but nothing" do
      first = Run.install!(seed: 1, scenario: :baseline, adversary: %{count: 0}, root: "debug")
      second = Run.install!(seed: 2, scenario: :baseline, adversary: %{count: 0}, root: "debug")

      third =
        Run.install!(seed: 1, scenario: :bounded_loss, adversary: %{count: 0}, root: "debug")

      assert first.run_id != second.run_id
      assert first.run_id != third.run_id
      assert first.run_id =~ "seed1"
      assert third.run_id =~ "bounded_loss"
    end
  end

  describe "derived randomness" do
    test "the same seed and the same message give the same value" do
      Run.install!(seed: 7, root: "debug")
      first = Rng.uniform({:delay, 0, 1, :message}, 5, 50)

      Run.install!(seed: 7, root: "debug")
      assert Rng.uniform({:delay, 0, 1, :message}, 5, 50) == first
    end

    test "a different seed gives a different network" do
      Run.install!(seed: 7, root: "debug")
      under_seven = for id <- 1..200, do: Rng.uniform({:delay, 0, id}, 5, 50)

      Run.install!(seed: 8, root: "debug")
      under_eight = for id <- 1..200, do: Rng.uniform({:delay, 0, id}, 5, 50)

      assert under_seven != under_eight
    end

    test "a delay stays inside the bounds the run reports" do
      Run.install!(seed: 3, root: "debug")

      for id <- 1..500 do
        assert Rng.uniform({:delay, 0, id}, 5, 50) in 5..50
      end
    end

    test "the value does not depend on how many values were drawn before it" do
      # This is what separates a derived value from one taken off a process generator. A
      # generator advances once per draw, so the value a sender gives a message would depend
      # on how many messages it had already sent, which depends on the order its inbox
      # happened to fill.
      Run.install!(seed: 11, root: "debug")
      direct = Rng.uniform({:delay, 0, 1, :the_message}, 5, 50)

      Run.install!(seed: 11, root: "debug")
      for id <- 1..1_000, do: Rng.uniform({:delay, 0, id}, 5, 50)

      assert Rng.uniform({:delay, 0, 1, :the_message}, 5, 50) == direct
    end

    test "a process seeds its own generator from the run's seed" do
      Run.install!(seed: 5, root: "debug")

      draw = fn ->
        task = Task.async(fn -> Rng.seed_process!(:peer, 0) && :rand.uniform(1_000_000) end)
        Task.await(task)
      end

      assert draw.() == draw.()
    end

    test "two processes of the same role and different identity draw differently" do
      Run.install!(seed: 5, root: "debug")

      draw = fn id ->
        Task.async(fn -> Rng.seed_process!(:peer, id) && :rand.uniform(1_000_000) end)
        |> Task.await()
      end

      assert draw.(0) != draw.(1)
    end
  end

  describe "the boundary secret" do
    test "a seeded run derives it, so the replica state repeats" do
      Run.install!(seed: 21, root: "debug")
      first = Syncordian.Byzantine.generate_boundary_secret()

      Run.install!(seed: 21, root: "debug")
      assert Syncordian.Byzantine.generate_boundary_secret() == first

      Run.install!(seed: 22, root: "debug")
      assert Syncordian.Byzantine.generate_boundary_secret() != first
    end

    test "an unseeded run still draws it from the system generator" do
      Run.reset!()

      assert Syncordian.Byzantine.generate_boundary_secret() !=
               Syncordian.Byzantine.generate_boundary_secret()
    end

    test "the derived pair has the shape a drawn pair has" do
      Run.install!(seed: 1, root: "debug")
      {infimum, supremum} = Syncordian.Byzantine.generate_boundary_secret()

      assert byte_size(infimum) == 64
      assert byte_size(supremum) == 64
      assert infimum != supremum
    end
  end

  describe "scenarios" do
    test "each names the capabilities it exercises" do
      storm = Run.scenario_adversary(:reorder_storm)
      assert storm[:duplicate_rate] > 0
      assert storm[:reorder_rate] > 0
      assert storm[:replay_rate] > 0

      replay = Run.scenario_adversary(:post_collection_replay)
      assert replay[:replay_rate] > 0
      assert replay[:replay_hold_ms] > 0

      loss = Run.scenario_adversary(:bounded_loss)
      assert loss[:drop_rate] > 0

      baseline = Run.scenario_adversary(:baseline)
      assert baseline[:drop_rate] == 0.0
      assert baseline[:duplicate_rate] == 0.0
    end

    test "the ones that need an adversary are marked as needing one" do
      assert Run.requires_adversary?(:post_collection_replay)
      assert Run.requires_adversary?(:reorder_storm)
      refute Run.requires_adversary?(:baseline)
      refute Run.requires_adversary?(:bounded_loss)
    end

    test "an unknown name is refused" do
      assert_raise ArgumentError, fn -> Run.install!(scenario: "reorder-storm") end
    end
  end

  describe "the network's partition" do
    setup do
      Network.create()
      :ok
    end

    test "cuts a peer off in both directions and lets it back" do
      Network.partition(3, true)
      assert MapSet.member?(Network.partitioned(), 3)

      Network.partition(3, false)
      refute MapSet.member?(Network.partitioned(), 3)
    end

    test "reconnects everyone at once" do
      Network.partition(1, true)
      Network.partition(2, true)
      Network.reconnect_all()

      assert MapSet.size(Network.partitioned()) == 0
    end

    test "a run with no table reports nobody cut off rather than failing" do
      :ets.delete(:syncordian_network)
      assert MapSet.size(Network.partitioned()) == 0
    end
  end
end
