defmodule Syncordian.Fugue.Peer do
  @moduledoc """
  A lightweight Fugue peer module that replicates the core structure of Syncordian.Peer:
  - Starts a peer process
  - Handles insert/delete operations via broadcast and local updates
  - Interacts with a supervisor process
  - Maintains metadata
  """
  import Syncordian.Metadata
  import Syncordian.Fugue.Tree
  import Syncordian.Basic_Types

  defstruct peer_id: nil,
            document: nil,
            pid: nil,
            deleted_count: 0,
            supervisor_pid: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          peer_id: Syncordian.Basic_Types.peer_id(),
          document: Syncordian.Fugue.Tree.t(),
          pid: pid() | nil,
          deleted_count: non_neg_integer(),
          supervisor_pid: pid() | nil,
          metadata: Syncordian.Metadata.metadata()
        }

  @type peer_fugue :: t

  @doc """
  Creates a new Fugue peer with a given peer ID, document, PID, supervisor PID, and metadata.
  """
  @spec new(Syncordian.Basic_Types.peer_id(),
            Syncordian.Fugue.Tree.t(),
            pid(),
            pid(),
            Syncordian.Metadata.metadata()) :: peer_fugue()
  def new(peer_id, document, pid, supervisor_pid, metadata) do
    %__MODULE__{
      peer_id: peer_id,
      document: document,
      pid: pid,
      deleted_count: 0,
      supervisor_pid: supervisor_pid,
      metadata: metadata
    }
  end

  ############################# Peer Data Structure Interface ############################

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
  @spec get_peer_document(peer_fugue()) :: Syncordian.Fugue.Tree.t()
  def get_peer_document(%__MODULE__{document: document}), do: document

  @doc """
  Returns the number of deleted nodes recorded by this Fugue peer.
  """
  @spec get_peer_deleted_count(peer_fugue()) :: non_neg_integer()
  def get_peer_deleted_count(%__MODULE__{deleted_count: deleted_count}), do: deleted_count

  @doc """
  Updates the peer's Fugue tree (document) with a new tree structure.
  """
  @spec update_peer_document(Syncordian.Fugue.Tree.t(), peer_fugue()) :: peer_fugue()
  def update_peer_document(document, %__MODULE__{} = peer),
    do: %{peer | document: document}

  @doc """
  Updates the peer's PID and peer ID. This is useful if you need to reassign the peer
  to a new process or re-identify it.
  """
  @spec update_peer_pid({pid(), Syncordian.Basic_Types.peer_id()}, peer_fugue()) :: peer_fugue()
  def update_peer_pid({pid, peer_id}, %__MODULE__{} = peer) do
    %{peer | pid: pid, peer_id: peer_id}
  end

  @doc """
  Increments the deleted count for this Fugue peer by 1. This is useful when
  a delete operation occurs on the peer's document.
  """
  @spec tick_peer_deleted_count(peer_fugue()) :: peer_fugue()
  def tick_peer_deleted_count(%__MODULE__{} = peer) do
    new_count = get_peer_deleted_count(peer) + 1
    %{peer | deleted_count: new_count}
  end

  ########################################################################################

  ################################## Peer Loop Interface #################################
end
