defmodule Syncordian.ByzantinePeer do
  require Record
  import Syncordian.Metadata
  import Syncordian.Utilities

  Record.defrecord(:byzantine_peer,
    pid: nil,
    peer_id: nil,
    supervisor_pid: nil,
    metadata: Syncordian.Metadata.metadata()
  )

  @type byzantine_peer ::
          record(:byzantine_peer,
            pid: pid() | nil,
            peer_id: Syncordian.Basic_Types.peer_id(),
            supervisor_pid: pid() | nil,
            metadata: Syncordian.Metadata.metadata()
          )

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

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor.
  @spec perform_broadcast_byzantine(byzantine_peer(), any) :: any
  defp perform_broadcast_byzantine(byzantine_peer, message) do
    peer_pid = get_peer_pid(byzantine_peer)
    delay = 70..100
    perform_broadcast(peer_pid, message, delay)
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
      metadata: Syncordian.Metadata.metadata()
    )
  end

  @spec start_byzantine_peer(Syncordian.Basic_Types.peer_id()) :: pid
  def start_byzantine_peer(peer_id) do
    IO.puts("Starting byzantine peer with id: #{peer_id}")
    pid = spawn(__MODULE__, :byzantine_peer_loop, [define(peer_id)])
    :global.register_name(peer_id, pid)
    save_peer_pid(pid)
  end

  defp send?(), do: Enum.random(0..10) == 0

  def byzantine_peer_loop(byzantine_peer) do
    receive do
      {:receive_delete_broadcast, {line_deleted_id, delete_tag, op_id}, alpha} ->
        # This guard prevents feedback between byzantine peers: an honest delete tag is a
        # sha256 digest of 64 characters, while a forged one is the 10-character string
        # generated below, so a byzantine peer never re-forges another byzantine forgery.
        if String.length(delete_tag) != 10 and send?() do
          byzantine_tag = generate_string()

          # The attack: tamper with the authorization tag and rebroadcast, keeping the
          # observed admission authenticator UNCHANGED. The simulator models an outsider
          # that does not hold the boundary secret, so it cannot recompute a valid
          # authenticator over its mutated payload — replaying the stale one is its
          # strongest available move (garbling it too is strictly weaker). Honest peers
          # therefore drop the forgery at admission (admission_rejected_counter), never
          # applying or buffering it. The op_id is preserved from the observed message;
          # since the forged copy is rejected before the replay check, it is never
          # recorded, and the genuine delete is not later mistaken for a replay.
          perform_broadcast_byzantine(
            byzantine_peer,
            {:receive_delete_broadcast, {line_deleted_id, byzantine_tag, op_id}, alpha}
          )

          IO.puts("Byzantine peer #{get_peer_id(byzantine_peer)} is sending a delete broadcast")

          get_metadata(byzantine_peer)
          |> inc_byzantine_delete_counter()
          |> update_metadata(byzantine_peer)
          |> byzantine_peer_loop()
        else
          byzantine_peer_loop(byzantine_peer)
        end

      {:receive_insert_broadcast, {line_id, content, peer_id, insert_tag, incoming_vc, op_id},
       alpha} ->
        if String.length(insert_tag) != 10 and send?() do
          byzantine_tag = generate_string()

          # The forged wire tag is the attack; the stale admission authenticator no
          # longer matches the mutated payload, so honest receivers reject the message at
          # admission — see the delete clause above for the modeling rationale.
          perform_broadcast_byzantine(
            byzantine_peer,
            {:receive_insert_broadcast,
             {line_id, content, peer_id, byzantine_tag, incoming_vc, op_id}, alpha}
          )

          IO.puts("Byzantine peer #{get_peer_id(byzantine_peer)} is sending an insert broadcast")

          get_metadata(byzantine_peer)
          |> inc_byzantine_insert_counter()
          |> update_metadata(byzantine_peer)
          |> byzantine_peer_loop()
        else
          byzantine_peer_loop(byzantine_peer)
        end

      {:save_pid, pid} ->
        pid
        |> update_peer_pid(byzantine_peer)
        |> byzantine_peer_loop()

      {:supervisor_request_metadata} ->
        send(
          :global.whereis_name(:supervisor),
          {:receive_metadata_from_peer, get_metadata(byzantine_peer), get_peer_id(byzantine_peer)}
        )

        update_metadata(Syncordian.Metadata.metadata(), byzantine_peer)
        |> byzantine_peer_loop()

      _ ->
        byzantine_peer_loop(byzantine_peer)
    end
  end
end
