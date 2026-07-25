defmodule Syncordian.ByzantinePeer do
  @moduledoc """
  The adversary of the evaluation: an outsider that observes every message and answers it.

  A distrusted node is spawned alongside the author peers, with an identifier that cannot
  collide with theirs (see `Syncordian.Supervisor`), and registered in `:global`, so it
  receives every broadcast. It **does not hold the boundary secret**, the per-run pair the
  supervisor distributes out of band to admitted peers
  (`Syncordian.Byzantine.boundary_secret/0`). This module must never read that term; doing
  so would break the outsider assumption of `def:adversary`, on which the rejection
  guarantee of `theo:outsider` rests.

  ## What it can do

  Two of the adversary's powers live here, and both act on the content of messages.

    * **Injection.** It rewrites the authorization tag of an observed operation, optionally
      tampering with the operation's content as well, and broadcasts the result. It cannot
      recompute the admission authenticator over a payload it changed, so honest receivers
      reject the message at admission (`Syncordian.Byzantine.check_admission/4`, tallied in
      `admission_rejected_counter`) without ever applying or buffering it. Replaying the
      observed authenticator is the strongest move available to it; garbling that too would
      be strictly weaker.
    * **Replay.** It re-broadcasts a captured message *unchanged*, after holding it for as
      long as the profile says. This message is genuine. It carries a valid authenticator
      written by an admitted peer, so it passes admission, and the guard the injection
      attack exercises has nothing to say about it. What answers it is the applied-operation
      set, and a replay held past the collection of that set is answered by the tombstone
      and by the position identifier alone. This is the harder of the two experiments, and
      it is the one a reviewer is entitled to ask for.

  The adversary's third power, control of delivery, is not here. Dropping, delaying,
  duplicating, and partitioning are properties of the network rather than of a peer, and
  they live in `Syncordian.Network`.

  ## What it cannot do

  It never holds the boundary secret, so it can neither author an admissible operation nor
  authenticate a tampered one. Every capability it does have is named in the run's adversary
  profile and recorded in the run manifest, so a run reports which attacks it exercised
  rather than leaving a reader to assume the strongest one.

  Its decisions are derived from the run's seed together with the message it is answering,
  so an adversarial run repeats under its seed, and two adversaries never make the same
  decision about the same message.

  A message the adversary has already answered is remembered, so that a replay it broadcast
  is not observed and replayed again without end. The adversary replays what it captured;
  it does not amplify its own traffic without bound.

  > #### Spelling note {: .info}
  > The file and lower-level identifiers use the legacy spelling `bizantine`; the
  > module and user-facing strings say "Byzantine". Keep both in sync if renaming.
  """
  require Record
  import Syncordian.Metadata

  alias Syncordian.Network
  alias Syncordian.Rng
  alias Syncordian.Run
  alias Syncordian.Utilities

  Record.defrecord(:byzantine_peer,
    pid: nil,
    peer_id: nil,
    supervisor_pid: nil,
    metadata: Syncordian.Metadata.metadata(),
    answered: nil
  )

  @type byzantine_peer ::
          record(:byzantine_peer,
            pid: pid() | nil,
            peer_id: Syncordian.Basic_Types.peer_id(),
            supervisor_pid: pid() | nil,
            metadata: Syncordian.Metadata.metadata(),
            answered: MapSet.t() | nil
          )

  # An honest authorization tag is a 64-character digest; a forged one is the short token
  # below. The length tells the adversary that a message is another adversary's forgery, so
  # it never forges a forgery.
  @forged_tag_length 10

  @spec get_metadata(byzantine_peer()) :: Syncordian.Metadata.metadata()
  defp get_metadata(byzantine_peer), do: byzantine_peer(byzantine_peer, :metadata)

  @spec update_metadata(
          Syncordian.Metadata.metadata(),
          byzantine_peer()
        ) :: byzantine_peer()
  defp update_metadata(metadata, byzantine_peer),
    do: byzantine_peer(byzantine_peer, metadata: metadata)

  @spec get_peer_pid(byzantine_peer()) :: pid()
  defp get_peer_pid(byzantine_peer), do: byzantine_peer(byzantine_peer, :pid)

  # This is a private function used to get the peer_id of the byzantine peer.
  @spec get_peer_id(byzantine_peer()) :: Syncordian.Basic_Types.peer_id()
  defp get_peer_id(byzantine_peer), do: byzantine_peer(byzantine_peer, :peer_id)

  @spec update_peer_pid(pid(), byzantine_peer()) :: byzantine_peer()
  defp update_peer_pid(pid, byzantine_peer), do: byzantine_peer(byzantine_peer, pid: pid)

  # The adversary's traffic crosses the same network as everyone else's, so it is delayed and
  # accounted the same way. Giving the adversary a private delay range, as this module used
  # to, makes the attack's timing a hidden parameter of every reported result.
  @spec perform_broadcast_byzantine(byzantine_peer(), any) :: any
  defp perform_broadcast_byzantine(byzantine_peer, message) do
    peer_pid = get_peer_pid(byzantine_peer)
    Network.broadcast(get_peer_id(byzantine_peer), Utilities.broadcast_targets(peer_pid), message)
  end

  @spec save_peer_pid(pid) :: any
  defp save_peer_pid(pid),
    do: send(pid, {:save_pid, pid})

  @spec define(Syncordian.Basic_Types.peer_id()) :: byzantine_peer()
  defp define(peer_id) do
    byzantine_peer(
      pid: nil,
      peer_id: peer_id,
      supervisor_pid: nil,
      metadata: Syncordian.Metadata.metadata(),
      answered: answered_set()
    )
  end

  # The set of already-answered messages is only kept when the profile replays, because that
  # is the only capability whose output is indistinguishable from its input. Injected
  # messages carry a short tag and are recognized without any memory at all, and on a full
  # replay of a long history the set would otherwise grow to hold every message every
  # adversary ever saw.
  defp answered_set do
    if Run.adversary()[:replay_rate] > 0, do: MapSet.new(), else: nil
  end

  @doc """
  Spawns a Byzantine peer, registers it in `:global` under `peer_id`, and returns
  the result of seeding it with its own pid. Called by the supervisor once per
  requested Byzantine node.
  """
  @spec start_byzantine_peer(Syncordian.Basic_Types.peer_id()) :: pid
  def start_byzantine_peer(peer_id) do
    IO.puts("Starting byzantine peer with id: #{peer_id}")
    pid = spawn(__MODULE__, :byzantine_peer_loop, [define(peer_id)])
    :global.register_name(peer_id, pid)
    save_peer_pid(pid)
  end

  @doc """
  Receive loop for a Byzantine peer.

  Observes honest insert and delete broadcasts and answers them according to the run's
  adversary profile: an injected forgery, a verbatim replay, both, or neither. Also answers
  the supervisor's requests for metadata. Runs as the spawned process entry point, and is
  not called directly.
  """
  def byzantine_peer_loop(byzantine_peer) do
    receive do
      {:receive_delete_broadcast, {_target_op_id, _target_line_id, delete_tag, _op_id}, _alpha} =
          message ->
        byzantine_peer
        |> answer(message, delete_tag, :delete)
        |> byzantine_peer_loop()

      {:receive_insert_broadcast,
       {_line_id, _content, _peer_id, insert_tag, _incoming_vc, _op_id, _left_parent_op_id,
        _right_parent_op_id, _replaces_op_id}, _alpha} = message ->
        byzantine_peer
        |> answer(message, insert_tag, :insert)
        |> byzantine_peer_loop()

      # A captured message whose hold has elapsed, re-broadcast exactly as it was observed.
      {:replay_now, message, kind} ->
        perform_broadcast_byzantine(byzantine_peer, message)

        IO.puts("Byzantine peer #{get_peer_id(byzantine_peer)} is replaying a #{kind}")

        get_metadata(byzantine_peer)
        |> inc_byzantine_replay_counter()
        |> update_metadata(byzantine_peer)
        |> byzantine_peer_loop()

      # The first message this peer receives, and so where it seeds its generator for the
      # run. The adversary's role is separated from the honest peers' so that an adversary
      # and a peer sharing an identifier never draw the same sequence (Syncordian.Rng).
      {:save_pid, pid} ->
        Rng.seed_process!(:byzantine_peer, get_peer_id(byzantine_peer))

        pid
        |> update_peer_pid(byzantine_peer)
        |> byzantine_peer_loop()

      # The report is not cleared afterwards. Every other peer's counters are cumulative over
      # its life, and the supervisor keeps only the newest report from each peer, so clearing
      # this one made the reported attack volume the volume since the previous collection
      # rather than the volume of the run. The final report, taken after the network had gone
      # quiet, then said that almost no attack had happened.
      {:supervisor_request_metadata} ->
        send(
          :global.whereis_name(:supervisor),
          {:receive_metadata_from_peer, get_metadata(byzantine_peer), get_peer_id(byzantine_peer)}
        )

        byzantine_peer_loop(byzantine_peer)

      _ ->
        byzantine_peer_loop(byzantine_peer)
    end
  end

  ########################################################################################
  # Answering an observed message
  ########################################################################################

  # Decides what to do with one observed operation. A message that is another adversary's
  # forgery, or one this adversary has already answered, is left alone.
  @spec answer(byzantine_peer(), tuple(), String.t(), :insert | :delete) :: byzantine_peer()
  defp answer(byzantine_peer, message, tag, kind) do
    profile = Run.adversary()

    cond do
      String.length(tag) == @forged_tag_length ->
        byzantine_peer

      answered?(byzantine_peer, message) ->
        byzantine_peer

      true ->
        byzantine_peer
        |> remember(message)
        |> maybe_inject(message, kind, profile)
        |> maybe_replay(message, kind, profile)
    end
  end

  # Injection: the authorization tag is rewritten, the content is tampered with when the
  # profile says so, and the observed admission authenticator is carried over unchanged
  # because the adversary cannot compute a new one. The operation's identity and its authored
  # parents are preserved, so the forgery is rejected before the replay check and the genuine
  # operation is never afterwards mistaken for a repeat of it.
  defp maybe_inject(byzantine_peer, message, kind, profile) do
    peer_id = get_peer_id(byzantine_peer)

    if Rng.chance?({:inject, peer_id, message}, profile[:inject_rate]) do
      forged = forge(message, peer_id, profile[:tamper_content])
      perform_broadcast_byzantine(byzantine_peer, forged)

      IO.puts("Byzantine peer #{peer_id} is sending a forged #{kind} broadcast")

      count_injection(get_metadata(byzantine_peer), kind)
      |> update_metadata(byzantine_peer)
    else
      byzantine_peer
    end
  end

  # Replay: the message goes back on the wire exactly as it was observed, after the hold the
  # profile names. The hold is what makes the experiment difficult, because a replay that
  # arrives while the operation is still remembered is answered by the applied-operation set,
  # and one that arrives after that set has been collected is answered by the replica state
  # itself.
  defp maybe_replay(byzantine_peer, message, kind, profile) do
    peer_id = get_peer_id(byzantine_peer)

    if Rng.chance?({:replay, peer_id, message}, profile[:replay_rate]) do
      hold = profile[:replay_hold_ms]

      if hold > 0 do
        Process.send_after(get_peer_pid(byzantine_peer), {:replay_now, message, kind}, hold)
        byzantine_peer
      else
        perform_broadcast_byzantine(byzantine_peer, message)

        get_metadata(byzantine_peer)
        |> inc_byzantine_replay_counter()
        |> update_metadata(byzantine_peer)
      end
    else
      byzantine_peer
    end
  end

  defp count_injection(metadata, :insert), do: inc_byzantine_insert_counter(metadata)
  defp count_injection(metadata, :delete), do: inc_byzantine_delete_counter(metadata)

  # The forged copy of an observed message. Content tampering is what the evaluation claims
  # the adversary does, so it is what the adversary does when the profile enables it: the
  # inserted text is replaced, and a delete is aimed at a different position.
  defp forge({:receive_insert_broadcast, payload, alpha}, peer_id, tamper?) do
    {line_id, content, author_id, _tag, vector_clock, op_id, left_parent, right_parent, replaces} =
      payload

    forged_content = if tamper?, do: tamper(content, peer_id, op_id), else: content

    {:receive_insert_broadcast,
     {line_id, forged_content, author_id, Rng.token({:tag, peer_id, op_id}, @forged_tag_length),
      vector_clock, op_id, left_parent, right_parent, replaces}, alpha}
  end

  defp forge({:receive_delete_broadcast, payload, alpha}, peer_id, tamper?) do
    {target_op_id, target_line_id, _tag, op_id} = payload

    forged_line_id =
      if tamper?, do: tamper_position(target_line_id, peer_id, op_id), else: target_line_id

    {:receive_delete_broadcast,
     {target_op_id, forged_line_id, Rng.token({:tag, peer_id, op_id}, @forged_tag_length), op_id},
     alpha}
  end

  defp tamper(content, peer_id, op_id) when is_binary(content),
    do: "#{content} #{Rng.token({:content, peer_id, op_id}, 8)}"

  defp tamper(content, _peer_id, _op_id), do: content

  # A position identifier is a list of segments; aiming the delete elsewhere means changing
  # one of them. A shape the adversary does not recognize is left as observed, since a
  # malformed position would be rejected for the wrong reason.
  defp tamper_position([_segment | rest], peer_id, op_id),
    do: [{Rng.uniform({:position, peer_id, op_id}, 0, 65_535), peer_id} | rest]

  defp tamper_position(position, _peer_id, _op_id), do: position

  defp answered?(byzantine_peer, message) do
    case byzantine_peer(byzantine_peer, :answered) do
      nil -> false
      answered -> MapSet.member?(answered, :erlang.phash2(message))
    end
  end

  defp remember(byzantine_peer, message) do
    case byzantine_peer(byzantine_peer, :answered) do
      nil ->
        byzantine_peer

      answered ->
        byzantine_peer(byzantine_peer,
          answered: MapSet.put(answered, :erlang.phash2(message))
        )
    end
  end
end
