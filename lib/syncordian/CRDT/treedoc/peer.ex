defmodule Syncordian.CRDT.Treedoc.Peer do

  import Syncordian.Metadata
  import Syncordian.Utilities
  alias Syncordian.CRDT.Treedoc.{Bst, Node}

  @peer_metadata_id 7

  defstruct peer_id: nil,
            document: nil,
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
          document: Syncordian.CRDT.Treedoc.Bst.t(),
          pid: pid() | nil,
          deleted_count: integer(),
          supervisor_pid: pid() | nil,
          metadata: Syncordian.Metadata.metadata(),
          counter: integer(),
          external_counter_list: [integer()],
          network_size: integer(),
          edit_count: integer()
        }

  @type peer_treedoc :: t

  @doc """
  Creates a new Tree peer with a given peer ID.
  """
  @spec new(Syncordian.Basic_Types.peer_id()) :: peer_treedoc()
  def new(peer_id), do: %__MODULE__{peer_id: peer_id}

  @doc """
  Sets the supervisor PID for this Fugue peer.
  """
  @spec set_peer_supervisor_pid(peer_treedoc(), pid()) :: peer_treedoc()
  def set_peer_supervisor_pid(%__MODULE__{} = peer, supervisor_pid),
    do: %{peer | supervisor_pid: supervisor_pid}

  @doc """
  Retrieves the PID of this Fugue peer.
  """
  @spec get_peer_pid(peer_treedoc()) :: pid()
  def get_peer_pid(%__MODULE__{pid: pid}), do: pid

  @doc """
  Retrieves the unique peer ID of this Fugue peer.
  """
  @spec get_peer_id(peer_treedoc()) :: Syncordian.Basic_Types.peer_id()
  def get_peer_id(%__MODULE__{peer_id: peer_id}), do: peer_id

  @doc """
  Returns the Fugue tree (document) maintained by this peer.
  """
  @spec get_peer_document(peer_treedoc()) :: Syncordian.CRDT.Fugue.Tree.t()
  def get_peer_document(%__MODULE__{document: document}), do: document


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
    IO.puts("Treedoc peer with id #{peer_id} started with pid #{inspect(pid)}")
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, peer_id, network_size)
    Process.send_after(pid, {:register_supervisor_pid}, 50)
    pid
  end

  ########################################################################################

  ################################ Peer utility ################################
  ################################ Peer utility ################################

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor. This one is define here because here the
  # delay makes sense to be define and then use the perform_broadcast function of the
  # utilities module.
  @spec perform_broadcast_peer(peer_treedoc(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    # delay = 10..30
    delay = 0..0
    perform_broadcast(peer_pid, message, delay)
  end

  def loop(peer) do
    receive do
      ###################################### Delete related messages
      {:delete_line, [_index_position, index, _global_position, _current_delete_ops]} ->
        IO.inspect(index)
        # peer_id = get_peer_id(peer)
        # document = get_peer_document(peer)
        loop(peer)
    end
  end

end
