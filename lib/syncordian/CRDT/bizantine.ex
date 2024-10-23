defmodule Syncordian.Byzantine do
  # use TypeCheck

  @moduledoc """
    This module is responsible for the byzantine operations aiming to provide the features
    to support the byzantine fault tolerance in the Syncordian implementation.
  """
  import Syncordian.Line_Object

  # This function defines the hash function that is used to create the signatures
  defp hash_function(content) do
    :crypto.hash(:sha256, content) |> Base.encode16()
  end

  @doc """
    This function is important just for seek of keeping the types consistent. The content
    is just the name of my dog 🐕
  """
  @spec get_trivial_signature() :: Syncordian.Basic_Types.signature()
  def get_trivial_signature(), do:  "Omega"

  @doc """
    This function checks if the signature is trivial by comparing it with the trivial
    signature.
  """
  @spec is_trivial_signature(Syncordian.Basic_Types.signature()) :: boolean()
  def is_trivial_signature(signature), do: signature == get_trivial_signature()

  @doc """
    This function checks if the delete signature is valid by comparing it with the
    signature created by the left parent and right parent content. Because the delete
    signature is created in such manner.
  """
  @spec check_signature_delete(
          deleted_line_signature :: Syncordian.Basic_Types.signature(),
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) :: boolean()
  # This two definition were introduce due to the byzantine peer, see fix in the function
  # window_stash_check_signature. This was made just after commit f8ac522 syncordian
  # repository
  def check_signature_delete(_, nil, _) , do: false
  def check_signature_delete(_, _, nil) , do: false
  def check_signature_delete(
        deleted_line_signature,
        left_parent,
        right_parent
      ) do
    signature = create_signature_delete(left_parent, right_parent)
    signature == deleted_line_signature
  end

  @doc """
    As a security feature the signature the creation of the signature for the delete
    operation is different from the insert operation. This function, create a signature
    just by using the left parent and right parent signatures.
  """
  @spec create_signature_delete(
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) ::
          Syncordian.Basic_Types.signature()
  def create_signature_delete(left_parent, right_parent) do
    left_parent_signature = get_signature(left_parent)
    right_parent_signature = get_signature(right_parent)
    element = "#{left_parent_signature}#{right_parent_signature}"
    hash_function(element)
  end

  @doc """
    This function checks if the signature is valid by comparing it with the signature
    created by the left parent content, the new content, the right parent content and the
    peer id.
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
          left_parent_signature :: Syncordian.Basic_Types.content(),
          content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.content(),
          peer_id :: Syncordian.Basic_Types.peer_id(),
          signature :: Syncordian.Basic_Types.signature()
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
          left_parent_signature :: Syncordian.Basic_Types.content(),
          new_content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.content(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_signature_insert(
        left_parent_signature,
        new_content,
        right_parent_signature,
        peer_id
      ) do
    element = "#{left_parent_signature}#{new_content}#{right_parent_signature}#{peer_id}"
    hash_function(element)
  end
end
