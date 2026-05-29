defmodule Syncordian.Byzantine do
  # use TypeCheck

  @moduledoc """
    This module is responsible for the byzantine operations aiming to provide the features
    to support the byzantine fault tolerance in the Syncordian implementation.

    ## Signature invariant (immutable identifiers)

    A line carries exactly **one** signature, computed **once** at insertion by
    `create_signature_insert/4` as

        sig(line) = h( sig(left_parent) ++ content ++ sig(right_parent) ++ peer_id )

    where `sig(left_parent)` / `sig(right_parent)` are the parents' own (already
    immutable) signatures at the moment the line is inserted. This signature is an
    *immutable identifier*: it is never recomputed when the line's neighbors change.
    When concurrent edits shift a line's neighbors, a receiver does **not** rehash any
    line; instead it searches a bounded window of candidate parent pairs
    (`Syncordian.Document.window_stash_check_signature/3`) until the stored signature
    verifies. The honest protocol therefore never mutates a stored signature — the only
    code path that overwrites a signature is the adversary in
    `Syncordian.ByzantinePeer`, which forges one to model an attack.

    The delete operation does **not** introduce a second stored signature. Its
    authorization tag, produced by `create_signature_delete/2` as
    `h( sig(left_parent) ++ sig(right_parent) )`, is a *derived, transient* value:
    recomputed on demand from the (immutable) neighbor signatures, sent in the delete
    message, and never stored on any line. Its construction is deliberately different
    from the insert signature (no `content`, no `peer_id`) so that an insert signature
    can never be replayed as a delete authorization, nor vice versa.
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
  def get_trivial_signature(), do: "Omega"

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
  def check_signature_delete(_, nil, _), do: false
  def check_signature_delete(_, _, nil), do: false

  def check_signature_delete(
        deleted_line_signature,
        left_parent,
        right_parent
      ) do
    signature = create_signature_delete(left_parent, right_parent)
    signature == deleted_line_signature
  end

  @doc """
    Builds the delete authorization tag for a line from its two parents' (immutable)
    signatures, as `h( sig(left_parent) ++ sig(right_parent) )`.

    This tag is a *derived, transient* value: it is recomputed on demand at delete time,
    carried in the delete message, and never stored on a line. Its construction
    deliberately omits the `content` and `peer_id` terms used by
    `create_signature_insert/4`, so an insert signature cannot be replayed as a delete
    authorization (and vice versa). See the module-level signature invariant.
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
    Creates a line's signature — its *immutable identifier* — by concatenating the left
    parent's signature, the new content, the right parent's signature and the peer id,
    then hashing the result with sha256 (returned base16-encoded).

    This is the single signature a line ever carries. It is set once, at insertion, and
    never recomputed afterwards; neighbor changes are reconciled by the windowed search
    in `Syncordian.Document`, not by rehashing. See the module-level signature invariant.
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
