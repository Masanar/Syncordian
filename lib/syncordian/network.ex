defmodule Syncordian.Network do
  @moduledoc """
  The simulated network, and the only place a message's delivery is decided.

  Every protocol message a peer sends passes through here: a broadcast to the whole group
  and the point-to-point traffic of the recovery path alike. Routing the point-to-point
  traffic through the same place matters. A retransmission request and its answer used to
  be delivered with no delay at all, which made recovery look instantaneous and flattered
  the very numbers the recovery path exists to be judged on.

  ## The delay model

  Delay is drawn independently for each message and each recipient from a uniform
  distribution whose bounds the run reports (`Syncordian.Run.delay_spec/0`). It is derived
  from the run's seed together with the sender, the recipient, and the message, rather than
  drawn from the sender's own generator, so that a seed describes one network rather than
  one network per scheduling of the virtual machine. `Syncordian.Rng` explains why the
  distinction is not cosmetic.

  ## The adversary

  The evaluation's adversary is an outsider with control of delivery. Within the profile a
  run configures, it may deliver a message twice, hold one back so that it arrives out of
  order, or suppress one so that it does not arrive until it is asked for again. It may also
  cut a peer off entirely for a window (`partition/2`), which is the targeted form of the
  same power.

  What it may not do is read the boundary secret, and nothing in this module does. Its power
  is over delivery, never over content: a message it holds, duplicates, or drops is the
  message the honest sender wrote. Forged and tampered messages are the separate business of
  `Syncordian.ByzantinePeer`, which observes traffic and injects.

  Suppression is bounded by construction rather than by a budget. It is drawn from the
  sender's own stream, so the same operation offered again after a retransmission request is
  an independent trial, and an operation asked for often enough arrives. A suppression
  derived from the message alone would suppress every copy of it forever, which is a
  permanent partition rather than a lossy link, and no protocol converges under one.

  ## Accounting

  A suppressed message is still counted as sent, because it was put on the wire, and a
  duplicated one is counted twice. Reporting only what arrived would understate the load the
  network actually carried and would make an adversarial run look cheaper than a quiet one.
  """

  alias Syncordian.Instrument
  alias Syncordian.Rng
  alias Syncordian.Run

  @table :syncordian_network
  @partition_key :partitioned
  @calm_key :calm

  @doc """
  Creates the table that holds the network's mutable state.

  Only the targeted partition lives here. Everything else about a delivery is derived, so it
  needs no state at all. Called by the supervisor before any peer is spawned; a previous
  run's table is discarded so that a partition can never outlive the run that opened it.
  """
  @spec create() :: :ok
  def create do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(@table, {@partition_key, MapSet.new()})
    :ets.insert(@table, {@calm_key, false})
    :ok
  end

  @doc """
  Cuts `peer_id` off from the network, or restores it.

  Both directions are cut. A peer behind a partition sends nothing that arrives and receives
  nothing, which is what an offline window means, and when the window closes it has to
  recover the operations it missed by asking for them.
  """
  @spec partition(Syncordian.Basic_Types.peer_id(), boolean()) :: :ok
  def partition(peer_id, cut?) do
    current = partitioned()

    updated =
      if cut?, do: MapSet.put(current, peer_id), else: MapSet.delete(current, peer_id)

    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {@partition_key, updated})
    :ok
  end

  @doc """
  Ends the disturbance: reconnects every peer and stops the loss, duplication, and
  reordering, leaving only the run's ordinary delay.

  Called when the replay ends, before the settle window opens. What eventual consistency
  claims is that the replicas agree once the disturbance stops, so that is what the settle
  window has to measure. A run that was still losing messages when its documents were dumped
  would be reporting on a network that never went quiet, and a replica still cut off at the
  end has not been shown to recover; it has been prevented from trying.

  This is also what makes the loss in the `:bounded_loss` scenario bounded, and so what keeps
  the network assumption the recovery path is judged under intact.
  """
  @spec calm() :: :ok
  def calm do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {@partition_key, MapSet.new()})
      :ets.insert(@table, {@calm_key, true})
    end

    :ok
  end

  @doc """
  Turns the run's disturbance on or off.

  A scenario that disturbs the network for a stretch of the replay rather than for all of it
  uses this to open and close the stretch. `calm/0` is the same switch, thrown for the last
  time when the replay ends.
  """
  @spec disturb(boolean()) :: :ok
  def disturb(active?) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {@calm_key, not active?})
    :ok
  end

  @doc "Reconnects every peer, leaving the rest of the disturbance in place."
  @spec reconnect_all() :: :ok
  def reconnect_all do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {@partition_key, MapSet.new()})
    :ok
  end

  @doc "True once `calm/0` has ended the run's disturbance."
  @spec calm?() :: boolean()
  def calm? do
    case :ets.whereis(@table) do
      :undefined ->
        false

      _ ->
        case :ets.lookup(@table, @calm_key) do
          [{@calm_key, value}] -> value
          [] -> false
        end
    end
  end

  @doc "The set of peers currently cut off."
  @spec partitioned() :: MapSet.t()
  def partitioned do
    case :ets.whereis(@table) do
      :undefined ->
        MapSet.new()

      _ ->
        case :ets.lookup(@table, @partition_key) do
          [{@partition_key, set}] -> set
          [] -> MapSet.new()
        end
    end
  end

  @doc """
  Sends `message` from `sender_id` to every `{pid, peer_id}` in `targets`.

  The whole broadcast is accounted once, as one message per recipient, and then each
  recipient's delivery is decided on its own. That ordering is deliberate: the cost a
  broadcast puts on the network does not depend on what the environment then does with each
  copy.
  """
  @spec broadcast(Syncordian.Basic_Types.peer_id(), [{pid(), term()}], term()) :: :ok
  def broadcast(sender_id, targets, message) do
    account(message, length(targets))
    policy = policy()

    Enum.each(targets, fn {pid, peer_id} ->
      dispatch(policy, sender_id, peer_id, pid, message)
    end)

    :ok
  end

  @doc """
  Sends `message` from `sender_id` to one peer.

  The recovery path's traffic. It is as real a cost as a broadcast and is subject to the
  same network, so it is accounted and delayed the same way.
  """
  @spec unicast(Syncordian.Basic_Types.peer_id(), pid(), term(), term()) :: :ok
  def unicast(sender_id, recipient_pid, recipient_id, message) do
    account(message, 1)
    dispatch(policy(), sender_id, recipient_id, recipient_pid, message)
    :ok
  end

  @doc """
  Delivers a message that belongs to the harness rather than to the protocol.

  The supervisor's requests for metadata are not part of the system under study. Delaying,
  duplicating, or dropping them would corrupt the measurement rather than the run, so they
  bypass the network entirely and are not accounted.
  """
  @spec control(pid(), term()) :: :ok
  def control(pid, message) do
    send(pid, message)
    :ok
  end

  ########################################################################################
  # Delivery
  ########################################################################################

  # Everything a delivery decision needs, read once per broadcast rather than per recipient.
  defp policy do
    run = Run.current()
    adversary = if calm?(), do: %{}, else: run.adversary
    delay = run.delay
    duplicate_rate = Map.get(adversary, :duplicate_rate, 0.0)
    reorder_rate = Map.get(adversary, :reorder_rate, 0.0)
    drop_rate = Map.get(adversary, :drop_rate, 0.0)
    partitioned = partitioned()

    %{
      delay: delay,
      duplicate_rate: duplicate_rate,
      reorder_rate: reorder_rate,
      reorder_extra_ms: Map.get(adversary, :reorder_extra_ms, 0),
      drop_rate: drop_rate,
      partitioned: partitioned,
      quiet?:
        delay == :none and duplicate_rate == 0 and reorder_rate == 0 and drop_rate == 0 and
          MapSet.size(partitioned) == 0
    }
  end

  # The undisturbed network: no delay, no adversary, no partition. Kept as an explicit
  # branch because it is the case every unit test runs under, and because a timer per
  # message per recipient is real overhead on the acknowledgement storm.
  defp dispatch(%{quiet?: true}, _sender_id, _recipient_id, pid, message) do
    send(pid, message)
    :ok
  end

  defp dispatch(policy, sender_id, recipient_id, pid, message) do
    cond do
      cut?(policy.partitioned, sender_id, recipient_id) ->
        :ok

      Rng.roll?(policy.drop_rate) ->
        :ok

      true ->
        deliver(policy, sender_id, recipient_id, pid, message)
    end
  end

  defp deliver(policy, sender_id, recipient_id, pid, message) do
    link = {sender_id, recipient_id, message}
    delay = base_delay(policy.delay, link) + reorder_delay(policy, link)

    schedule(pid, message, delay)

    if Rng.chance?({:duplicate, link}, policy.duplicate_rate) do
      account(message, 1)

      schedule(
        pid,
        message,
        base_delay(policy.delay, {:copy, link}) + reorder_delay(policy, link)
      )
    end

    :ok
  end

  defp schedule(pid, message, 0), do: send(pid, message)
  defp schedule(pid, message, delay), do: Process.send_after(pid, message, delay)

  defp base_delay(:none, _link), do: 0
  defp base_delay({:uniform, low, high}, link), do: Rng.uniform({:delay, link}, low, high)

  defp reorder_delay(policy, link) do
    if Rng.chance?({:reorder, link}, policy.reorder_rate) do
      Rng.uniform({:reorder_amount, link}, 1, max(policy.reorder_extra_ms, 1))
    else
      0
    end
  end

  defp cut?(partitioned, sender_id, recipient_id) do
    MapSet.size(partitioned) > 0 and
      (MapSet.member?(partitioned, sender_id) or MapSet.member?(partitioned, recipient_id))
  end

  defp account(message, copies) do
    Instrument.record_message(
      Instrument.wire_kind(message),
      :erlang.external_size(message) * copies,
      copies
    )
  end
end
