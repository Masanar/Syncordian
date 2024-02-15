defmodule CRDT.Byzantine do
  @moduledoc """
    This module is responsible for the byzantine operations aiming to provide the features
    to support the byzantine fault tolerance in the CRDT implementation.
  """
  import CRDT.Line_Object

  @spec check_signature(
          left_parent :: CRDT.Types.line(),
          to_check_line :: CRDT.Types.line(),
          right_parent :: CRDT.Types.line()
        ) :: boolean()
  def check_signature(left_parent, to_check_line, right_parent) do
    left_parent_signature = get_signature(left_parent)
    right_parent_signature = get_signature(right_parent)
    peer_id = get_peer_id(to_check_line)
    signature = get_signature(to_check_line)
    content = get_content(to_check_line)
    check_signature(left_parent_signature,
                    content, 
                    right_parent_signature, 
                    peer_id, 
                    signature)
  end

  @doc """
    This function checks if the signature is valid by comparing it with the signature created
    by the left parent content, the new content, the right parent content and the peer id.
  """
  @spec check_signature(
          left_parent_signature :: CRDT.Types.content(),
          content :: CRDT.Types.content(),
          right_parent_signature :: CRDT.Types.content(),
          peer_id :: CRDT.Types.peer_id(),
          signature :: CRDT.Types.signature()
        ) :: boolean()
  defp check_signature(
         left_parent_signature,
         content,
         right_parent_signature,
         peer_id,
         signature
       ),
       do:
         signature ==
           create_signature(left_parent_signature,
                            content, 
                            right_parent_signature, 
                            peer_id)

  @doc """
    This function creates a signature based on the left parent content, the new content, 
    the right parent content and the peer id by concatenating them and hashing the result
    using the sha256 algorithm. It returns the hash encoded in base16.
  """
  @spec create_signature(
          left_parent_signature :: CRDT.Types.content(),
          new_content :: CRDT.Types.content(),
          right_parent_signature :: CRDT.Types.content(),
          peer_id :: CRDT.Types.peer_id()
        ) :: CRDT.Types.signature()
  def create_signature(left_parent_signature,
                       new_content, 
                       right_parent_signature, 
                       peer_id) do
    element = "#{left_parent_signature}#{new_content}#{right_parent_signature}#{peer_id}"
    :crypto.hash(:sha256, element) |> Base.encode16()
  end
end
