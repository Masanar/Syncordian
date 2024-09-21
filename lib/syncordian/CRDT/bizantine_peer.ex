defmodule Syncordian.ByzantinePeer do
  require Record
  import Syncordian.Metadata
  import Syncordian.Utilities
  import Syncordian.Line_Object

  Record.defrecord(:byzantine_peer,
    pid: nil,
    peer_id: nil,
    supervisor_pid: nil,
    metadata: Syncordian.Metadata.metadata()
  )

  @type byzantine_peer ::
          record(:byzantine_peer,
            pid: pid(),
            peer_id: Syncordian.Basic_Types.peer_id(),
            supervisor_pid: pid(),
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
  @spec perform_broadcast(byzantine_peer(), any) :: any
  defp perform_broadcast(byzantine_peer, message) do
    peer_pid = get_peer_pid(byzantine_peer)
    delay = Enum.random(70..90)
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

  defp send?(), do: Enum.random(0..5) == 0

  def byzantine_peer_loop(byzantine_peer) do
    receive do
      {:receive_delete_broadcast,
       {line_deleted_id, line_delete_signature, attempt_count, incoming_vc}} ->
        # This is the way to prevent the feedback between the byzantine peers, the
        # signature from a valid peer muts be a hash from sha256 (or similar) and such
        # signatures have a length of 64 characters. Then is the signature is different
        # from 10 (the length of a signature from a byzantine peer) then the signature is
        # valid and the message is broadcasted to the network. In the other case the
        # message is ignored.
        # if String.length(line_delete_signature) != 10 and send?() do
        #   byzantine_signature = generate_string()

        #   IO.puts(
        #     "Byzantine peer #{get_peer_id(byzantine_peer)} is sending a delete broadcast with a byzantine signature"
        #   )

        #   perform_broadcast(
        #     byzantine_peer,
        #     {:receive_delete_broadcast,
        #      {line_deleted_id, byzantine_signature, attempt_count, incoming_vc}}
        #   )

        #   get_metadata(byzantine_peer)
        #   |> inc_byzantine_delete_counter()
        #   |> update_metadata(byzantine_peer)
        #   |> byzantine_peer_loop()
        # else
        #   byzantine_peer_loop(byzantine_peer)
        # end

      {:receive_insert_broadcast, line, incoming_vc} ->
        if String.length(get_signature(line)) != 10 and send?() do
          byzantine_signature = generate_string()

          perform_broadcast(
            byzantine_peer,
            {:receive_insert_broadcast, update_line_signature(line, byzantine_signature),
             incoming_vc}
          )

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

        byzantine_peer_loop(byzantine_peer)

      _ ->
        byzantine_peer_loop(byzantine_peer)
    end
  end
end
