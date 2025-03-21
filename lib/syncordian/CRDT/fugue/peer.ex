defmodule Syncordian.CRDT.Fugue.Peer do
  @moduledoc """
  A lightweight Fugue peer module that replicates the core structure of Syncordian.Peer:
  - Starts a peer process
  - Handles insert/delete operations via broadcast and local updates
  - Interacts with a supervisor process
  - Maintains metadata
  For someone reading this code:
    This is a naive copy of /syncordian/peer.ex with the same functions and structure.
    I really believe that there is a better way to achieve this. Maybe by defining some
    interface like and then implemente it in the peers corresponding file, but I really
    do not know how to do so in Elixir. Maybe by using macros? I do not know.
  """
  import Syncordian.Metadata
  import Syncordian.Utilities
  import Syncordian.Basic_Types
  alias Syncordian.CRDT.Fugue.{Tree, Info, Node}

  @peer_metadata_id 7

  defstruct peer_id: nil,
            document: Syncordian.CRDT.Fugue.Tree.new(),
            pid: nil,
            deleted_count: 0,
            supervisor_pid: nil,
            metadata: Syncordian.Metadata.metadata(),
            counter: 0,
            external_counter_list: [],
            network_size: 0,
            edit_count: 0

  @type t :: %__MODULE__{
          peer_id: Syncordian.Basic_Types.peer_id(),
          document: Syncordian.CRDT.Fugue.Tree.t(),
          pid: pid() | nil,
          deleted_count: integer(),
          supervisor_pid: pid() | nil,
          metadata: Syncordian.Metadata.metadata(),
          counter: integer(),
          external_counter_list: [integer()],
          network_size: integer(),
          edit_count: integer()
        }

  @type peer_fugue :: t

  @spec get_document_byte_size(peer_fugue()) :: integer()
  def get_document_byte_size(peer) do
    nodes = get_peer_document(peer) |> Tree.get_tree_nodes()
    nodes_str = "#{inspect(nodes)}"
    nodes_str |> byte_size
  end

  @spec get_edit_count(peer_fugue()) :: integer()
  def get_edit_count(%__MODULE__{edit_count: edit_count}), do: edit_count

  @spec tick_edit_count(peer_fugue()) :: peer_fugue()
  def tick_edit_count(%__MODULE__{} = peer) do
    new_count = get_edit_count(peer) + 1
    %{peer | edit_count: new_count}
  end

  @spec get_module_name() :: String.t()
  def get_module_name(), do: "fugue"

  @spec save_peer_metadata_edit(peer_fugue()) :: :ok
  defp save_peer_metadata_edit(peer) do
    file_prefix = "edit"
    folder = "fugue/"
    peer_pid = get_peer_pid(peer)
    current_edit = get_edit_count(peer)
    nodes_size = get_document_byte_size(peer)

    peer
    |> get_metadata()
    |> update_memory_info(peer_pid, nodes_size)
    |> save_metadata_one_peer(current_edit, folder, file_prefix)

    :ok
  end

  @doc """
  Creates a new Fugue peer with a given peer ID.
  """
  @spec new(Syncordian.Basic_Types.peer_id()) :: peer_fugue()
  def new(peer_id), do: %__MODULE__{peer_id: peer_id}

  ############################# Peer Data Structure Interface ############################

  @spec get_peer_external_counter_list(peer_fugue()) :: [integer()]
  def get_peer_external_counter_list(%__MODULE__{external_counter_list: external_counter_list}),
    do: external_counter_list

  @doc """
  Increments the external counter of the peer at the given peer id by 1.
  """
  @spec tick_peer_external_counter(peer_fugue(), integer()) :: peer_fugue()
  def tick_peer_external_counter(%__MODULE__{} = peer, peer_id) do
    external_counter_list = get_peer_external_counter_list(peer)
    ticked_projection = Enum.at(external_counter_list, peer_id) + 1

    new_external_counter_list =
      List.replace_at(external_counter_list, peer_id, ticked_projection)

    %{peer | external_counter_list: new_external_counter_list}
  end

  @spec get_peer_counter(peer_fugue()) :: integer()
  def get_peer_counter(%__MODULE__{counter: counter}), do: counter

  @spec increment_peer_counter(peer_fugue()) :: peer_fugue()
  def increment_peer_counter(%__MODULE__{} = peer) do
    new_counter = get_peer_counter(peer) + 1
    %{peer | counter: new_counter}
  end

  @doc """
  Retrieves the metadata of the Fugue peer.
  """
  @spec get_metadata(peer_fugue()) :: Syncordian.Metadata.metadata()
  def get_metadata(%__MODULE__{metadata: metadata}), do: metadata

  @doc """
  Updates the Fugue peer's metadata with a new map.
  """
  @spec update_metadata(Syncordian.Metadata.metadata(), peer_fugue()) :: peer_fugue()
  def update_metadata(new_metadata, %__MODULE__{} = peer), do: %{peer | metadata: new_metadata}

  @doc """
  Retrieves the PID of the supervisor process supervising this Fugue peer.
  """
  @spec get_peer_supervisor_pid(peer_fugue()) :: pid()
  def get_peer_supervisor_pid(%__MODULE__{supervisor_pid: supervisor_pid}), do: supervisor_pid

  @doc """
  Sets the supervisor PID for this Fugue peer.
  """
  @spec set_peer_supervisor_pid(peer_fugue(), pid()) :: peer_fugue()
  def set_peer_supervisor_pid(%__MODULE__{} = peer, supervisor_pid),
    do: %{peer | supervisor_pid: supervisor_pid}

  @doc """
  Retrieves the PID of this Fugue peer.
  """
  @spec get_peer_pid(peer_fugue()) :: pid()
  def get_peer_pid(%__MODULE__{pid: pid}), do: pid

  @doc """
  Retrieves the unique peer ID of this Fugue peer.
  """
  @spec get_peer_id(peer_fugue()) :: Syncordian.Basic_Types.peer_id()
  def get_peer_id(%__MODULE__{peer_id: peer_id}), do: peer_id

  @doc """
  Returns the Fugue tree (document) maintained by this peer.
  """
  @spec get_peer_document(peer_fugue()) :: Syncordian.CRDT.Fugue.Tree.t()
  def get_peer_document(%__MODULE__{document: document}), do: document

  @doc """
  Returns the number of deleted nodes recorded by this Fugue peer.
  """
  @spec get_peer_deleted_count(peer_fugue()) :: non_neg_integer()
  def get_peer_deleted_count(%__MODULE__{deleted_count: deleted_count}), do: deleted_count

  @doc """
  Updates the peer's Fugue tree (document) with a new tree structure.
  """
  @spec update_peer_document(Syncordian.CRDT.Fugue.Tree.t(), peer_fugue()) :: peer_fugue()
  def update_peer_document(document, %__MODULE__{} = peer),
    do: %{peer | document: document}

  @doc """
  Updates the peer's PID and peer ID. This is useful if you need to reassign the peer
  to a new process or re-identify it.
  """
  @spec update_peer_pid({pid(), Syncordian.Basic_Types.peer_id(), integer()}, peer_fugue()) ::
          peer_fugue()
  def update_peer_pid({pid, peer_id, network_size}, %__MODULE__{} = peer) do
    %{
      peer
      | pid: pid,
        peer_id: peer_id,
        network_size: network_size,
        external_counter_list: List.duplicate(0, network_size)
    }
  end

  @doc """
  Increments the deleted count for this Fugue peer by 1. This is useful when
  a delete operation occurs on the peer's document.
  """
  # I think that for fugue this is not needed, but I am going to keep it for now.
  @spec tick_peer_deleted_count(peer_fugue()) :: peer_fugue()
  def tick_peer_deleted_count(%__MODULE__{} = peer) do
    new_count = get_peer_deleted_count(peer) + 1
    %{peer | deleted_count: new_count}
  end

  ########################################################################################

  ################################## Peer Loop Interface #################################

  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop peer function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})

  @doc """
    This function prints in console the whole document no matter if the status of the line
    each line of the document is printed in a new line as a string.
  """
  @spec print_content(pid) :: any
  def print_content(pid), do: send(pid, {:print_content, :document})

  @doc """
    This function saves the content of the document of the peer in a file with the name
    document_peer_{peer_id} where peer_id is the id of the peer. The file is saved in the
    debug/documents folder. This function filter the first and last line of the document
    and the lines that are marked as tombstone.
  """
  @spec save_content(pid) :: any
  def save_content(pid), do: send(pid, {:save_content, :document})

  @doc """
    This function is use to delete a line at the given index in the current document of
    the peer by sending a message to the loop peer function. Where:
      - pid: the pid of the peer
      - index_position: the index position of the line to be deleted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.
  """
  @spec delete_line(pid, integer, integer, integer, integer) :: any
  def delete_line(pid, index_position, test_index, global_position, current_delete_ops),
    do:
      send(
        pid,
        {:delete_line, [index_position, test_index, global_position, current_delete_ops]}
      )

  @doc """
    This function inserts a content at the given index and a pid by sending a message to
    the loop peer function. The messages uses the following format:
    {:insert,[content,index, global_position] }
    where:
      - content: the content to be inserted in the peers local document
      - index_position: the index position where the content will be inserted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.

  """
  @spec insert(pid, String.t(), integer, integer, integer, integer) :: any
  def insert(pid, content, _index_position, test_index, _global_position, _current_delete_ops),
    do: send(pid, {:insert, [content, test_index]})

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer, integer) :: any
  def save_peer_pid(pid, peer_id, network_size),
    do: send(pid, {:save_pid, {pid, peer_id, network_size}})

  @doc """
    This function starts a peer with the given peer_id and registers it in the global
    registry. The returned content is the pid of the peer. The pid is the corresponding
    content of the pid of the spawned process.
  """
  @spec start(Syncordian.Basic_Types.peer_id(), integer) :: pid
  def start(peer_id, network_size) do
    pid = spawn(__MODULE__, :loop, [new(peer_id)])
    IO.puts("Fugue peer with id #{peer_id} started with pid #{inspect(pid)}")
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, peer_id, network_size)
    Process.send_after(pid, {:register_supervisor_pid}, 50)
    pid
  end

  ########################################################################################

  ################################ Peer utility ################################

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor. This one is define here because here the
  # delay makes sense to be define and then use the perform_broadcast function of the
  # utilities module.
  @spec perform_broadcast_peer(peer_fugue(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    # delay = 10..30
    delay = 0..0
    perform_broadcast(peer_pid, message, delay)
  end

  ########################################################################################
  # These peer are not going to be 'attack' by byzantine peers
  @spec loop(peer_fugue()) :: any
  def loop(peer) do
    receive do
      ###################################### Delete related messages
      {:delete_line, [_index_position, index, _global_position, _current_delete_ops]} ->
        peer_id = get_peer_id(peer)
        document = get_peer_document(peer)
        # Get node to be deleted
        delete_node = Tree.delete(document, index)
        delete_node_id = Node.get_id(delete_node)

        # Update the document with the deleted node, increment the deleted count and
        # increment the edit count
        updated_peer =
          Tree.delete_local(document, delete_node_id)
          |> update_peer_document(peer)
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
        current_counter = get_peer_counter(peer)

        insert_node =
          Tree.insert(document, peer_id, current_counter, index, content)

        send(get_peer_pid(peer), {:send_insert_broadcast, insert_node})

        new_node_peer =
          document
          |> Tree.insert_local(insert_node)
          |> update_peer_document(peer)
          |> increment_peer_counter()

        new_node_peer_new_metadata =
          new_node_peer
          |> get_metadata
          |> inc_insert_valid_counter
          |> update_metadata(new_node_peer)
          |> tick_edit_count

        if peer_id == @peer_metadata_id do
          save_peer_metadata_edit(new_node_peer)
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

        file_path = "debug/documents/fugue/raw/"
        File.write(file_path <> "tree", raw_tree_content)
        File.write(file_path <> "traverse", raw_traverse)
        File.write(file_path <> "full_traverse", raw_full_traverse)

        loop(peer)

      wrong_message ->
        IO.puts("Peer Fugue receive a wrong message")
        IO.inspect(wrong_message)
        loop(peer)

    end

  end
end
