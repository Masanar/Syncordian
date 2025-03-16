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
          metadata: map()
        }

  @type peer_fugue :: t

  @spec new(peer_id(), document(), pid(), supervisor_pid(), metadata()) :: peer_fugue()
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

  @spec get_metadata(peer_fugue()) :: Syncordian.Metadata.metadata()
  defp get_metadata(%__MODULE__{metadata: metadata}), do: metadata

  @spec update_metadata(Syncordian.Metadata.metadata(), peer_fugue()) :: peer_fugue()
  defp update_metadata(new_metadata, %__MODULE__{} = peer), do: %{peer | metadata: new_metadata}

  @spec get_peer_supervisor_pid(peer_fugue()) :: pid()
  defp get_peer_supervisor_pid(%__MODULE__{supervisor_pid: supervisor_pid}), do: supervisor_pid

  @spec set_peer_supervisor_pid(peer_fugue(), pid()) :: peer_fugue()
  defp set_peer_supervisor_pid(%__MODULE__{} = peer, supervisor_pid), do:
  %{peer | supervisor_pid: supervisor_pid}

  @spec get_peer_pid(peer_fugue()) :: pid()
  defp get_peer_pid(%__MODULE__{pid: pid}), do: pid

  @spec get_peer_id(peer_fugue()) :: Syncordian.Basic_Types.peer_id()
  defp get_peer_id(%__MODULE__{peer_id: peer_id}), do: peer_id

  @spec get_peer_document(peer_fugue()) :: Syncordian.Fugue.Tree.t()
  defp get_peer_document(%__MODULE__{document: document}), do: document

  @spec get_peer_deleted_count(peer_fugue()) :: non_neg_integer()
  defp get_peer_deleted_count(%__MODULE__{deleted_count: deleted_count}), do: deleted_count

  @spec update_peer_document(Syncordian.Fugue.Tree.t(), peer_fugue()) :: peer_fugue()
  defp update_peer_document(document, %__MODULE__{} = peer), do: %{peer | document: document}

  @spec update_peer_pid({pid(), Syncordian.Basic_Types.peer_id()}, peer_fugue()) :: peer_fugue()
  defp update_peer_pid({pid, peer_id}, %__MODULE__{} = peer) do
    %{peer |
      pid: pid,
      peer_id: peer_id
    }
  end
end
