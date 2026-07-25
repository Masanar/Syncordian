defmodule Syncordian.NetworkTest do
  @moduledoc """
  The simulated network, and the adversary's control of delivery.

  These pin what the evaluation claims about the environment its numbers were taken in: what
  a delay may be, what the adversary may do to a message, and what a run counts as sent.
  """
  use ExUnit.Case, async: false

  alias Syncordian.Instrument
  alias Syncordian.Network
  alias Syncordian.Run

  @insert {:receive_insert_broadcast, {:payload}, "alpha"}

  setup do
    Network.create()
    Instrument.reset()

    on_exit(fn ->
      Run.reset!()
      Network.reconnect_all()
    end)

    :ok
  end

  defp receiver do
    parent = self()
    spawn_link(fn -> relay(parent) end)
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:delivered, message, System.monotonic_time(:millisecond)})
        relay(parent)
    end
  end

  defp deliveries(within) do
    collect(within, [])
  end

  defp collect(within, acc) do
    receive do
      {:delivered, message, at} -> collect(within, [{message, at} | acc])
    after
      within -> Enum.reverse(acc)
    end
  end

  describe "an undisturbed network" do
    test "delivers every message once, and immediately" do
      Run.install!(delay: :none, root: "debug")
      target = receiver()

      Network.broadcast(0, [{target, 1}], @insert)

      assert [{@insert, _at}] = deliveries(200)
    end
  end

  describe "the delay model" do
    test "holds a message for a time inside the bounds the run reports" do
      Run.install!(seed: 1, delay: {:uniform, 60, 120}, root: "debug")
      target = receiver()

      sent_at = System.monotonic_time(:millisecond)
      Network.broadcast(0, [{target, 1}], @insert)

      assert [{@insert, at}] = deliveries(400)
      waited = at - sent_at

      assert waited >= 55, "delivered after #{waited}ms, before the model's lower bound"
      assert waited <= 200, "delivered after #{waited}ms, past the model's upper bound"
    end

    test "draws for each recipient independently" do
      Run.install!(seed: 1, delay: {:uniform, 0, 200}, root: "debug")
      targets = for id <- 1..12, do: {receiver(), id}

      Network.broadcast(0, targets, @insert)
      arrivals = deliveries(600) |> Enum.map(fn {_message, at} -> at end)

      assert length(arrivals) == 12
      assert Enum.uniq(arrivals) != [hd(arrivals)], "every recipient waited the same time"
    end
  end

  describe "the adversary's control of delivery" do
    test "a duplicated message arrives twice" do
      Run.install!(
        seed: 1,
        delay: :none,
        adversary: %{duplicate_rate: 1.0},
        root: "debug"
      )

      target = receiver()
      Network.broadcast(0, [{target, 1}], @insert)

      assert length(deliveries(300)) == 2
    end

    test "a reordered message arrives later than an undisturbed one" do
      Run.install!(
        seed: 1,
        delay: :none,
        adversary: %{reorder_rate: 1.0, reorder_extra_ms: 150},
        root: "debug"
      )

      target = receiver()
      sent_at = System.monotonic_time(:millisecond)
      Network.broadcast(0, [{target, 1}], @insert)

      assert [{@insert, at}] = deliveries(600)
      assert at - sent_at > 0
    end

    test "a partitioned peer neither receives nor sends" do
      Run.install!(delay: :none, root: "debug")
      target = receiver()

      Network.partition(1, true)
      Network.broadcast(0, [{target, 1}], @insert)
      assert deliveries(200) == []

      # And in the other direction: the cut peer's own sends do not arrive either.
      Network.partition(1, false)
      Network.partition(0, true)
      Network.broadcast(0, [{target, 1}], @insert)
      assert deliveries(200) == []

      Network.reconnect_all()
      Network.broadcast(0, [{target, 1}], @insert)
      assert length(deliveries(200)) == 1
    end

    test "suppression is independent across attempts, so a message asked for again arrives" do
      # A suppression derived from the message alone would suppress every copy of it forever,
      # which is a permanent partition rather than a lossy link, and no protocol converges
      # under one. The same message offered repeatedly has to get through eventually.
      Run.install!(seed: 1, delay: :none, adversary: %{drop_rate: 0.5}, root: "debug")
      target = receiver()

      for _attempt <- 1..40, do: Network.broadcast(0, [{target, 1}], @insert)

      arrived = length(deliveries(300))
      assert arrived > 0, "40 attempts at a 50% loss rate delivered nothing"
      assert arrived < 40, "a 50% loss rate dropped nothing"
    end
  end

  describe "accounting" do
    test "a broadcast counts one message per recipient" do
      Run.install!(delay: :none, root: "debug")
      targets = for id <- 1..3, do: {receiver(), id}

      Network.broadcast(0, targets, @insert)

      assert %{wire: %{insert: {3, bytes}}} = Instrument.snapshot()
      assert bytes == :erlang.external_size(@insert) * 3
    end

    test "a suppressed message is still counted as sent" do
      # It was put on the wire. Reporting only what arrived would make an adversarial run
      # look cheaper than a quiet one, which is the opposite of the truth.
      Run.install!(seed: 1, delay: :none, adversary: %{drop_rate: 1.0}, root: "debug")
      target = receiver()

      Network.broadcast(0, [{target, 1}], @insert)

      assert deliveries(200) == []
      assert %{wire: %{insert: {1, _bytes}}} = Instrument.snapshot()
    end

    test "a duplicated message is counted twice" do
      Run.install!(seed: 1, delay: :none, adversary: %{duplicate_rate: 1.0}, root: "debug")
      target = receiver()

      Network.broadcast(0, [{target, 1}], @insert)

      assert %{wire: %{insert: {2, _bytes}}} = Instrument.snapshot()
    end

    test "the recovery path is delayed and accounted like everything else" do
      # Retransmission requests and their answers used to bypass the network entirely, which
      # made recovery look instantaneous and flattered the numbers the recovery path exists
      # to be judged on.
      Run.install!(seed: 1, delay: {:uniform, 60, 120}, root: "debug")
      target = receiver()
      request = {:fetch_request, 3, {:op, {0, 1}}, "alpha"}

      sent_at = System.monotonic_time(:millisecond)
      Network.unicast(0, target, 3, request)

      assert [{^request, at}] = deliveries(400)
      assert at - sent_at >= 55
      assert %{wire: %{fetch: {1, _bytes}}} = Instrument.snapshot()
    end
  end

  describe "harness traffic" do
    test "bypasses the network and is not accounted" do
      # The supervisor's requests for metadata are not part of the system under study.
      # Delaying or dropping them would corrupt the measurement rather than the run.
      Run.install!(
        seed: 1,
        delay: {:uniform, 200, 300},
        adversary: %{drop_rate: 1.0},
        root: "debug"
      )

      target = receiver()
      Network.control(target, {:supervisor_request_metadata})

      assert [{{:supervisor_request_metadata}, _at}] = deliveries(150)
      assert Instrument.snapshot().wire == %{}
    end
  end
end
