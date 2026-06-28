defmodule Syncordian.CRDT.Treedoc.Node do
  @moduledoc """
  A single node of a Treedoc binary tree.

  Treedoc encodes each line's position as the path from the root to its node, so
  the in-order traversal of the tree yields the document in order. A node holds
  its `data` (the line content) plus optional `left`/`right` children; the tree
  operations live in `Syncordian.CRDT.Treedoc.Bst`. This module is pure data — it
  defines only the struct and its type.
  """
  defstruct [:data, :left, :right]

  @type t :: %__MODULE__{
          data: Syncordian.Basic_Types.content(),
          left: t() | nil,
          right: t() | nil
        }
end
