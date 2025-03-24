defmodule Syncordian.CRDT.Logoot.Peer do
  import Syncordian.Metadata
  alias Syncordian.Utilities
  alias Syncordian.CRDT.Logoot.{Agent, Sequence, Info}

  defstruct agent: Agent.new(),
            metadata: Syncordian.Metadata.metadata(),
            supervisor_pid: nil,
            pid: nil,
            edit_count: 0

  @type t :: %__MODULE__{
          agent: Agent.t(),
          metadata: Syncordian.Metadata.metadata(),
          supervisor_pid: pid | nil,
          pid: pid | nil,
          edit_count: integer()
        }

  @type peer_logoot :: t
  @peer_metadata_id 7

  @spec get_module_name() :: String.t()
  def get_module_name(), do: "logoot"

  @spec get_edit_count(peer_logoot()) :: integer()
  def get_edit_count(%__MODULE__{edit_count: edit_count}), do: edit_count

  @spec tick_edit_count(peer_logoot()) :: peer_logoot()
  def tick_edit_count(%__MODULE__{} = peer) do
    new_count = get_edit_count(peer) + 1
    %{peer | edit_count: new_count}
  end

  ################################## Getters ##################################

  @spec get_document_byte_size(peer_logoot()) :: integer()
  def get_document_byte_size(peer) do
    sequence = get_peer_sequence(peer)

    inspect(sequence, limit: :infinity, printable_limit: :infinity)
    |> byte_size
  end

  @spec get_peer_supervisor_pid(peer_logoot) :: pid() | nil
  def get_peer_supervisor_pid(peer), do: peer.supervisor_pid

  @spec get_peer_pid(peer_logoot) :: pid()
  def get_peer_pid(peer), do: peer.pid

  @spec get_peer_agent(peer_logoot) :: Agent.t()
  def get_peer_agent(peer), do: peer.agent

  @spec get_peer_metadata(peer_logoot) :: Syncordian.Metadata.metadata()
  def get_peer_metadata(peer), do: peer.metadata

  @spec get_peer_id(peer_logoot) :: Syncordian.Basic_Types.peer_id()
  def get_peer_id(peer), do: Agent.get_id(get_peer_agent(peer))

  @spec get_peer_clock(peer_logoot) :: non_neg_integer()
  def get_peer_clock(peer), do: Agent.get_clock(get_peer_agent(peer))

  @spec get_peer_sequence(peer_logoot) :: Sequence.t()
  def get_peer_sequence(peer), do: Agent.get_sequence(get_peer_agent(peer))

  ################################## Setters ##################################

  @spec set_peer_supervisor_pid(peer_logoot(), pid()) :: peer_logoot()
  def set_peer_supervisor_pid(%__MODULE__{} = peer, supervisor_pid),
    do: %{peer | supervisor_pid: supervisor_pid}

  @spec update_peer_pid(
          {pid(), Syncordian.Basic_Types.peer_id()},
          peer_logoot()
        ) ::
          peer_logoot()
  def update_peer_pid({pid, peer_id}, %__MODULE__{} = peer) do
    updated_peer = update_peer_id(peer_id, peer)
    %{updated_peer | pid: pid}
  end

  @spec update_peer_agent(Agent.t(), peer_logoot) :: peer_logoot
  def update_peer_agent(new_agent, peer) do
    %{peer | agent: new_agent}
  end

  @spec update_peer_metadata(Syncordian.Metadata.metadata(), peer_logoot) :: peer_logoot
  def update_peer_metadata(new_metadata, peer) do
    %{peer | metadata: new_metadata}
  end

  @spec update_peer_id(Syncordian.Basic_Types.peer_id(), peer_logoot) :: peer_logoot
  def update_peer_id(new_id, peer) do
    agent = get_peer_agent(peer)
    updated_agent = Agent.update_id(agent, new_id)
    update_peer_agent(updated_agent, peer)
  end

  @spec update_peer_sequence(Sequence.t(), peer_logoot) :: peer_logoot
  def update_peer_sequence(new_sequence, peer) do
    updated_agent = Agent.update_sequence(get_peer_agent(peer), new_sequence)
    update_peer_agent(updated_agent, peer)
  end

  ################################## Peer Initialization ##################################

  @spec new(Syncordian.Basic_Types.peer_id()) :: peer_logoot()
  def new(peer_id), do: %__MODULE__{agent: Agent.new(peer_id)}

  # This part of code is basically the same in all peers definition! if you have time
  # in the future improve this.
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
  def insert(pid, content, _, test_index, _, _),
    do: send(pid, {:insert, [content, test_index]})

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer) :: any
  def save_peer_pid(pid, peer_id),
    do: send(pid, {:save_pid, {pid, peer_id}})

  @doc """
      This function starts a peer with the given peer_id and registers it in the global
      registry. The returned content is the pid of the peer. The pid is the corresponding
      content of the pid of the spawned process.
  """
  @spec start(Syncordian.Basic_Types.peer_id(), integer) :: pid
  def start(peer_id, _network_size) do
    pid = spawn(__MODULE__, :loop, [new(peer_id)])
    IO.puts("Logoot peer with id #{peer_id} started with pid #{inspect(pid)}")
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, peer_id)
    Process.send_after(pid, {:register_supervisor_pid}, 50)
    pid
  end

  ########################################################################################

  @spec perform_broadcast_peer(peer_logoot(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    delay = 0..0
    Utilities.perform_broadcast(peer_pid, message, delay)
  end

  @spec save_peer_metadata_edit(peer_logoot()) :: :ok
  defp save_peer_metadata_edit(peer) do
    folder = "logoot/"
    file_prefix = "edit"
    peer_pid = get_peer_pid(peer)
    current_edit = get_edit_count(peer)
    nodes_size = get_document_byte_size(peer)

    peer
    |> get_peer_metadata()
    |> update_memory_info(peer_pid, nodes_size)
    |> save_metadata_one_peer(current_edit, folder, file_prefix)

    :ok
  end

  @spec perform_delete(Sequence.sequence_atom(), peer_logoot()) :: peer_logoot()
  def perform_delete(to_delete_atom, peer) do
    peer_id = get_peer_id(peer)

    new_peer =
      get_peer_sequence(peer)
      |> Sequence.delete_atom(to_delete_atom)
      |> update_peer_sequence(peer)
      |> tick_edit_count()

    if peer_id == @peer_metadata_id do
      save_peer_metadata_edit(new_peer)
    end

    new_peer
  end

  @spec loop(peer_logoot) :: any
  def loop(peer) do
    receive do
      ###################################### Delete related messages
      {:delete_line, [_index_position, index, _global_position, _current_delete_ops]} ->
        peer_pid = get_peer_pid(peer)
        sequence = get_peer_sequence(peer)
        to_delete_atom = Sequence.get_sequence_atom_by_index(sequence, index)
        peer = perform_delete(to_delete_atom, peer)

        if index < 10 and length(sequence) > 100 do
          peer_id = get_peer_id(peer)
          IO.puts("Delete on #{peer_id} with index #{index}")
          IO.inspect(Enum.take(sequence,12))
          IO.inspect(to_delete_atom)
          IO.puts("\n\n")
        end

        # Send the broadcast to the network
        send(peer_pid, {:send_delete_broadcast, to_delete_atom})

        loop(peer)

      {:send_delete_broadcast, delete_node_id} ->
        perform_broadcast_peer(peer, {:receive_delete_broadcast, delete_node_id})
        loop(peer)

      {:receive_delete_broadcast, to_delete_atom} ->
        peer = perform_delete(to_delete_atom, peer)

        loop(peer)

      ###################################### Insert related messages
      {:insert, [content, index]} ->
        peer_pid = get_peer_pid(peer)
        agent = get_peer_agent(peer)
        sequence = get_peer_sequence(peer)

        {atom_ident, _term} =
          cond do
            index == 0 ->
              Sequence.get_sequence_atom_by_index(sequence, index)
            true ->
              Sequence.get_sequence_atom_by_index(sequence, index - 1)
          end
        if index < 10 and length(sequence) > 100 do
          peer_id = get_peer_id(peer)
          IO.puts("Insert on #{peer_id} with index #{index}")
          IO.inspect(Enum.take(sequence,12))
          IO.inspect(atom_ident)
          IO.puts("\n\n")
        end

        case Sequence.get_and_insert_after(sequence, atom_ident, content, agent) do
          {:ok, {new_sequence_atom, new_agent}} ->
            peer_id = get_peer_id(peer)
            new_peer = update_peer_agent(new_agent, peer) |> tick_edit_count()
            send(peer_pid, {:send_insert_broadcast, new_sequence_atom})

            if peer_id == @peer_metadata_id do
              save_peer_metadata_edit(new_peer)
            end

            loop(new_peer)

          {:error, error} ->
            IO.puts("Error inserting the content")
            IO.inspect(error)
            loop(peer)
        end

      {:send_insert_broadcast, new_sequence_atom} ->
        perform_broadcast_peer(
          peer,
          {:receive_insert_broadcast, new_sequence_atom}
        )

        loop(peer)

      {:receive_insert_broadcast, new_sequence_atom} ->
        sequence = get_peer_sequence(peer)

        case Sequence.insert_atom(sequence, new_sequence_atom) do
          {:ok, new_sequence} ->
            peer_id = get_peer_id(peer)
            new_peer = update_peer_sequence(new_sequence, peer) |> tick_edit_count()

            if peer_id == @peer_metadata_id do
              save_peer_metadata_edit(new_peer)
            end

            loop(new_peer)

          {:error, error} ->
            IO.puts("Error inserting local content Logoot peer")
            IO.inspect(error)
            loop(peer)
        end

      #################################### Gathering info related messages

      {:request_live_view_document, live_view_pid} ->
        peer_id = get_peer_id(peer)
        list_document = get_peer_sequence(peer)

        handler_function = fn
          node ->
            Utilities.create_map_live_view_node_document(
              Syncordian.CRDT.Logoot.Sequence.get_sequence_atom_value(node),
              peer_id,
              Syncordian.CRDT.Logoot.Sequence.get_sequence_atom_position_str(node)
            )
        end

        send(live_view_pid, {:receive_live_view_document, list_document, handler_function})
        loop(peer)

      {:supervisor_request_metadata} ->
        peer_pid = get_peer_pid(peer)
        supervisor_pid = get_peer_supervisor_pid(peer)

        nodes_size = get_document_byte_size(peer)

        updated_memory_metadata =
          peer
          |> get_peer_metadata()
          |> update_memory_info(peer_pid, nodes_size)

        send(
          supervisor_pid,
          {:receive_metadata_from_peer, updated_memory_metadata, peer_pid}
        )

        update_peer_metadata(updated_memory_metadata, peer)
        |> loop()

      {:save_content, :document} ->
        peer_id = get_peer_id(peer)
        document = get_peer_sequence(peer)
        Info.save_tree_content(document, peer_id)
        loop(peer)

      {:write_raw_document} ->
        document = get_peer_sequence(peer)

        helper_raw = fn list ->
          list
          |> inspect(limit: :infinity, printable_limit: :infinity)
        end

        raw_document = helper_raw.(document)

        file_path = "debug/documents/logoot/raw/"

        # Ensure the directory exists
        unless File.dir?(file_path) do
          File.mkdir_p!(file_path)
        end

        # Write the file
        File.write!(file_path <> "document", raw_document)

        loop(peer)

      {:register_supervisor_pid} ->
        supervisor_pid = :global.whereis_name(:supervisor)

        set_peer_supervisor_pid(peer, supervisor_pid)
        |> loop

      {:save_pid, info} ->
        info
        |> update_peer_pid(peer)
        |> loop

      wrong ->
        IO.puts("Wrong message received at Logoot per")
        IO.inspect(wrong)
        loop(peer)
    end
  end
end
