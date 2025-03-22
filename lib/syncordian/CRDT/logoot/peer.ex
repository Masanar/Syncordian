defmodule Syncordian.CRDT.Logoot.Peer do

    defstruct peer_id : @null_id, 
            clock: 0, 
            sequence: nil,
            metadata : Syncordian.Metadata.metadata()

    @type t :: [sequence_atom]

    @typedoc """
    A `sequence_atom` that represents the beginning of any `Logoot.Sequence.t`.
    """
    @type abs_min_atom_ident :: {nonempty_list({0, 0}), 0}

    @typedoc """
    A `sequence_atom` that represents the end of any `Logoot.Sequence.t`.
    """
    @type abs_max_atom_ident :: {nonempty_list({32767, 0}), 1}

    @doc """
    Get the minimum sequence atom.
    """
    @spec min :: abs_min_atom_ident
    def min, do: @abs_min_atom_ident

    @doc """
    Get the maximum sequence atom.
    """
    @spec max :: abs_max_atom_ident
    def max, do: @abs_max_atom_ident

    def start(peer_id, _network_size) do
        agent = %SyncordianCRDT.Logoot.Peer{}
        :global.register_name(peer_id, agent)
        save_peer_pid(pid, peer_id)
        agent
    end

    @spec save_peer_pid(pid, integer) :: any
    defp save_peer_pid(pid, peer_id), do: send(pid, {:save_pid, {pid, peer_id}})

    # This is a private function used whenever an update to the document is needed. It
  # updates the record peer with the new document.
  @spec update_peer_document(Syncordian.Basic_Types.document(), peer()) :: peer()
  defp update_peer_document(document, peer), do: peer(peer, document: document)

    @spec loop(peer_logoot()) :: any
    def loop(peer) do
        receive do
            ###################################### Delete related messages
            {:delete_line, [_index_position, index, _global_position, _current_delete_ops]} ->
            peer_id = get_peer_id(peer)
            document = get_peer_document(peer)

            # Get node to be deleted
            git_index_translated = translate_git_index_to_syncordian_index(document, test_index, 0, 0)

            [left_parent, right_parent] =
                get_parents_by_index(
                    document,
                    git_index_translated
                )
            atom_to_delete = gen_atom_ident(peer_pid, left_parent, right_parent)
            new_sequence = delete_atom(document, atom_to_delete)
            
            # Update the document with the deleted node, increment the deleted count and
            # increment the edit count
            updated_peer = update_peer_document(peer)
                |> tick_peer_deleted_count()
                |> tick_edit_count()

            # Update the metadata of the peer with the new values
            updated_peer_metadata = get_metadata(updated_peer) |> inc_delete_valid_counter()
            updated_peer_delete_metadata = update_metadata(updated_peer_metadata, updated_peer)
            peer_pid = get_peer_pid(updated_peer_delete_metadata)

            # Save the edit info is the peer is the chosen one
            if peer_id == @peer_metadata_id do
                save_peer_metadata_edit(updated_peer_delete_metadata)
            end

            # Send the broadcast to the network
            send(peer_pid, {:send_delete_broadcast, delete_node_id})

            # loop with the new peer node deleted and metadata updated
            loop(updated_peer_delete_metadata)

            {:send_delete_broadcast, delete_node_id} ->
            perform_broadcast_peer(peer, {:receive_delete_broadcast, delete_node_id})
            loop(peer)

            {:receive_delete_broadcast, delete_node_id} ->
            peer_id = get_peer_id(peer)
            # update the peer with the document with the deleted node
            updated_peer =
                get_peer_document(peer)
                |> Tree.delete_local(delete_node_id)
                |> update_peer_document(peer)

            # update the metadata of the new peer
            updated_peer_metadata = get_metadata(updated_peer) |> inc_delete_valid_counter()

            # Get the new peer with the metadata updated
            updated_peer_delete_metadata =
                update_metadata(updated_peer_metadata, updated_peer)
                |> tick_edit_count
                |> tick_peer_deleted_count

            # Save the edit info is the peer is the chosen one
            if peer_id == @peer_metadata_id do
                save_peer_metadata_edit(updated_peer_delete_metadata)
            end

            loop(updated_peer_delete_metadata)

            ###################################### Insert related messages
            {:insert, [content, index]} ->
            peer_id = get_peer_id(peer)
            document = get_peer_document(peer)
            
            git_index_translated = translate_git_index_to_syncordian_index(document, test_index, 0, 0)

            [left_parent, right_parent] =
                get_parents_by_index(
                    document,
                    git_index_translated
                )

            new_atom_index = gen_atom_ident(peer_pid, left_parent, right_parent)
            atom = {new_atom_index, content}
            {:ok, new_sequence} = insert_atom(document, atom)
            new_peer =  update_peer_document(new_sequence, peer)
                

            send(get_peer_pid(peer), {:send_insert_broadcast, atom})

            if peer_id == @peer_metadata_id do
                save_peer_metadata_edit(new_peeer)
            end

            loop(new_node_peer_new_metadata)

            {:send_insert_broadcast, insert_node} ->
            perform_broadcast_peer(
                peer,
                {:receive_insert_broadcast, insert_node}
            )

            loop(peer)

            {:receive_insert_broadcast, insert_node} ->
            peer_pid = get_peer_pid(peer)
            insert_node_origin_peer_id = Node.get_peer_id(insert_node)
            external_counter_list = get_peer_external_counter_list(peer)

            if Node.check_sender_counter_projection_distance(insert_node, external_counter_list) do
                new_node_peer =
                get_peer_document(peer)
                |> Tree.insert_local(insert_node)
                |> update_peer_document(peer)
                |> tick_peer_external_counter(insert_node_origin_peer_id)

                new_node_peer_new_metadata =
                new_node_peer
                |> get_metadata
                |> inc_insert_valid_counter
                |> update_metadata(new_node_peer)
                |> tick_edit_count()

                peer_id = get_peer_id(peer)

                if peer_id == @peer_metadata_id do
                save_peer_metadata_edit(new_node_peer_new_metadata)
                end

                loop(new_node_peer_new_metadata)
            else
                send(peer_pid, {:receive_insert_broadcast, insert_node})

                get_metadata(peer)
                |> inc_requeue_counter
                |> update_metadata(peer)
                |> loop
            end

            #################################### Gathering info related messages

            {:print_content, :document} ->
            peer_id = get_peer_id(peer)

            get_peer_document(peer)
            |> Info.print_tree_content(peer_id)

            loop(peer)

            {:save_content, :document} ->
            peer_id = get_peer_id(peer)
            document = get_peer_document(peer)
            Info.save_tree_content(document, peer_id)
            loop(peer)

            {:request_live_view_document, live_view_pid} ->
            list_document = get_peer_document(peer) |> Tree.full_traverse()
            peer_id = get_peer_id(peer)

            handler_function = fn
                node ->
                Syncordian.Utilities.create_map_live_view_node_document(
                    Syncordian.CRDT.Fugue.Node.get_value(node),
                    peer_id,
                    Syncordian.CRDT.Fugue.Node.get_id_str(node),
                    Syncordian.CRDT.Fugue.Node.get_side(node)
                )
            end

            send(live_view_pid, {:receive_live_view_document, list_document, handler_function})
            loop(peer)

            {:save_pid, info} ->
            info
            |> update_peer_pid(peer)
            |> loop

            {:print, _} ->
            IO.inspect(peer)
            loop(peer)

            {:register_supervisor_pid} ->
            supervisor_pid = :global.whereis_name(:supervisor)

            set_peer_supervisor_pid(peer, supervisor_pid)
            |> loop

            {:supervisor_request_metadata} ->
            peer_pid = get_peer_pid(peer)

            nodes_size = get_document_byte_size(peer)

            updated_memory_metadata =
                peer
                |> get_metadata()
                |> update_memory_info(peer_pid, nodes_size)

            send(
                get_peer_supervisor_pid(peer),
                {:receive_metadata_from_peer, updated_memory_metadata, peer_pid}
            )

            update_metadata(updated_memory_metadata, peer)
            |> loop()

            {:write_raw_document} ->
            document = get_peer_document(peer)
            traverse = Tree.traverse(document)
            full_traverse = Tree.full_traverse(document)

            helper = fn list ->
                list
                |> Enum.map(fn node -> Node.node_to_string(node) end)
                |> Enum.join("\n")
            end

            raw_traverse = traverse |> helper.()

            raw_full_traverse = full_traverse |> helper.()

            raw_tree_content =
                Tree.get_tree_nodes(document)
                |> Enum.map(fn {id, {node, left, right}} ->
                "Node ID: #{inspect(id)}\nNode: #{inspect(node)}\nLeft: #{inspect(left)}\nRight: #{inspect(right)}\n"
                end)
                |> Enum.join("\n")

            file_path = "debug/documents/logoot/raw/"
            File.write(file_path <> "doc", raw_tree_content)
            
            loop(peer)

            wrong_message ->
            IO.puts("Peer Logoot receive a wrong message")
            IO.inspect(wrong_message)
            loop(peer)
        end
    end

    @doc """
    Delete the given atom from the sequence.
    """
    @spec delete_atom(t, sequence_atom) :: t
    def delete_atom([atom | tail], atom), do: tail
    def delete_atom([head | tail], atom), do: [head | delete_atom(tail, atom)]
    def delete_atom([], _atom), do: []

    @doc """
    Insert the given atom into the sequence.
    """
    @spec insert_atom(t, sequence_atom) :: {:ok, t} | {:error, String.t}
    def insert_atom(list = [prev | tail = [next | _]], atom) do
    {{prev_position, _}, _} = prev
    {{next_position, _}, _} = next
    {{position, _}, _} = atom

    case {compare_positions(position, prev_position),
            compare_positions(position, next_position)} do
        {:gt, :lt} ->
        {:ok, [prev | [atom | tail]]}
        {:gt, :gt} ->
        case insert_atom(tail, atom) do
            error = {:error, _} -> error
            {:ok, tail} -> {:ok, [prev | tail]}
        end
        {:lt, :gt} ->
        {:error, "Sequence out of order"}
        {_, :eq} ->
        {:ok, list}
    end

    # Compare two positions.
    @spec compare_positions(position, position) :: comparison
    defp compare_positions([], []), do: :eq
    defp compare_positions(_, []), do: :gt
    defp compare_positions([], _), do: :lt

    defp compare_positions([head_a | tail_a], [head_b | tail_b]) do
        case compare_idents(head_a, head_b) do
        :gt -> :gt
        :lt -> :lt
        :eq -> compare_positions(tail_a, tail_b)
        end
    end
end
