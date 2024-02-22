defmodule Syncordian.Byzantine do
  use TypeCheck

  @moduledoc """
    This module is responsible for the byzantine operations aiming to provide the features
    to support the byzantine fault tolerance in the Syncordian implementation.
  """
  import Syncordian.Line_Object

  @spec check_signature_delete(
          deleted_line_signature :: Syncordian.Types.signature(),
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) :: boolean()
  def check_signature_delete(
        deleted_line_signature,
        left_parent,
        right_parent
      ) do
    signature = create_signature_delete(left_parent, right_parent)
    signature == deleted_line_signature
  end

  @doc """
    As a security feature the signature the creation of the signature for the delete operation
    is different from the insert operation. This function, create a signature just by using
    the left parent and right parent signatures.
    # TODO (small) -> Notice that deleted_line is not used in this function, refactor it.
  """
  @spec create_signature_delete(
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) ::
          Syncordian.Types.signature()
  def create_signature_delete(left_parent, right_parent) do
    left_parent_signature = get_signature(left_parent)
    right_parent_signature = get_signature(right_parent)
    element = "#{left_parent_signature}#{right_parent_signature}"
    :crypto.hash(:sha256, element) |> Base.encode16()
  end

  @doc """
    This function checks if the signature is valid by comparing it with the signature created
    by the left parent content, the new content, the right parent content and the peer id.
  """
  @spec check_signature_insert(
          left_parent :: Syncordian.Line_Object.line(),
          to_check_line :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) :: boolean()
  def check_signature_insert(left_parent, to_check_line, right_parent) do
    left_parent_signature = get_signature(left_parent)
    right_parent_signature = get_signature(right_parent)
    peer_id = get_line_peer_id(to_check_line)
    signature = get_signature(to_check_line)
    content = get_content(to_check_line)

    check_signature_insert(
      left_parent_signature,
      content,
      right_parent_signature,
      peer_id,
      signature
    )
  end

  # This function checks if the signature is valid by comparing it with the signature
  # created by the left parent content, the new content, the right parent content and the
  # peer id.
  @spec check_signature_insert(
          left_parent_signature :: Syncordian.Types.content(),
          content :: Syncordian.Types.content(),
          right_parent_signature :: Syncordian.Types.content(),
          peer_id :: Syncordian.Types.peer_id(),
          signature :: Syncordian.Types.signature()
        ) :: boolean()
  defp check_signature_insert(
         left_parent_signature,
         content,
         right_parent_signature,
         peer_id,
         signature
       ),
       do:
         signature ==
           create_signature_insert(
             left_parent_signature,
             content,
             right_parent_signature,
             peer_id
           )

  @doc """
    This function creates a signature based on the left parent content, the new content,
    the right parent content and the peer id by concatenating them and hashing the result
    using the sha256 algorithm. It returns the hash encoded in base16.
  """
  @spec create_signature_insert(
          left_parent_signature :: Syncordian.Types.content(),
          new_content :: Syncordian.Types.content(),
          right_parent_signature :: Syncordian.Types.content(),
          peer_id :: Syncordian.Types.peer_id()
        ) :: Syncordian.Types.signature()
  def create_signature_insert(
        left_parent_signature,
        new_content,
        right_parent_signature,
        peer_id
      ) do
    element = "#{left_parent_signature}#{new_content}#{right_parent_signature}#{peer_id}"
    :crypto.hash(:sha256, element) |> Base.encode16()
  end
end
