defmodule Syncordian.CRDT.Fugue.Node do
  @moduledoc """
  This module defines the `Syncordian.CRDT.Fugue.Node` structure and provides utility functions
  for creating, manipulating, and querying nodes in a CRDT-based tree (fugue) structure.

  A node represents an element in the tree and contains the following fields:
  - `id`: A unique identifier for the node, represented as a tuple `{String.t(), integer()}`.
  - `value`: The value stored in the node, which can be a string or a tombstone marker.
  - `parent`: The ID of the parent node.
  - `side`: Indicates the side of the parent node (`:left`, `:right`, or `nil`).

  ## Types
  - `node_ID`: A tuple `{String.t(), integer()}` representing a unique node identifier.
  - `tree_side`: Represents the side of the parent node (`:left`, `:right`, or `nil`).
  - `node_value`: The value of the node, which can be a string or `:tombstone`.
  - `t`: The struct representing a node.
  """

  @null_id     {"root", 0}
  @left_value  :left
  @right_value :right
  @tombstone   :tombstone

  @type node_ID :: {String.t(), integer()}
  @type tree_side :: :left | :right | nil
  @type node_value :: String.t() | :tombstone

  defstruct id: @null_id, value: @tombstone, parent: @null_id, side: nil

  @type t :: %__MODULE__{
          id: node_ID,
          value: node_value,
          parent: node_ID,
          side: tree_side
        }

  @doc """
  Returns the root node of the tree.

  The root node has the default `id`, `value`, `parent`, and `side` values.
  """
  @spec root() :: t
  def root(), do: %__MODULE__{}

  @doc """
  Creates a new node with the given attributes.

  ## Parameters
  - `id`: The unique identifier for the node.
  - `value`: The value to store in the node.
  - `parent`: The ID of the parent node.
  - `side`: The side of the parent node (`:left` or `:right`).

  ## Returns
  A new node struct.
  """
  @spec new(node_ID, node_value, node_ID, tree_side) :: t
  def new(id, value, parent, side),
    do: %__MODULE__{id: id, value: value, parent: parent, side: side}

  @doc """
  Checks if the given node is a tombstone.

  ## Parameters
  - `node`: The node to check.

  ## Returns
  `true` if the node is a tombstone, `false` otherwise.
  """
  @spec is_tombstone?(node) :: boolean()
  def is_tombstone?(%__MODULE__{value: @tombstone}), do: true
  def is_tombstone?(%__MODULE__{value: _}), do: false

  @doc """
  Checks if the given node is the root node.

  ## Parameters
  - `node`: The node to check.

  ## Returns
  `true` if the node is the root, `false` otherwise.
  """
  @spec is_root?(t) :: boolean()
  def is_root?(node), do: node.id == @null_id

  @doc """
  Checks if the given node is a leaf node.

  A leaf node is any node that is not the root.

  ## Parameters
  - `node`: The node to check.

  ## Returns
  `true` if the node is a leaf, `false` otherwise.
  """
  @spec is_leaf?(t) :: boolean()
  def is_leaf?(node), do: node.id != @null_id

  @doc """
  Returns the null ID, which represents the root node's ID.
  """
  @spec get_null_id() :: node_ID
  def get_null_id(), do: @null_id

  @doc """
  Returns the tombstone value, which is used to mark deleted nodes.
  """
  @spec get_tombstone() :: node_value
  def get_tombstone(), do: @tombstone

  # Getters

  @doc """
  Retrieves the ID of the given node.

  ## Parameters
  - `node`: The node to retrieve the ID from. If `nil`, returns the null ID.

  ## Returns
  The ID of the node.
  """
  @spec get_id(t | nil) :: node_ID
  def get_id(nil), do: @null_id
  def get_id(%__MODULE__{id: id}), do: id

  @spec get_number_id(node_ID) :: integer()
  def get_number_id({_, id}), do: id

  @doc """
  Retrieves the value of the given node.

  ## Parameters
  - `node`: The node to retrieve the value from.

  ## Returns
  The value of the node.
  """
  @spec get_value(t) :: node_value
  def get_value(%__MODULE__{value: value}), do: value

  @doc """
  Retrieves the parent ID of the given node.

  ## Parameters
  - `node`: The node to retrieve the parent ID from.

  ## Returns
  The parent ID of the node.
  """
  @spec get_parent(t) :: node_ID
  def get_parent(%__MODULE__{parent: parent}), do: parent

  @doc """
  Retrieves the side of the given node.

  ## Parameters
  - `node`: The node to retrieve the side from.

  ## Returns
  The side of the node (`:left`, `:right`, or `nil`).
  """
  @spec get_side(t) :: tree_side
  def get_side(%__MODULE__{side: side}), do: side

  @doc """
  Returns the value representing the right side of a parent node.
  """
  @spec get_right_value() :: tree_side()
  def get_right_value(), do: @right_value

  @doc """
  Returns the value representing the left side of a parent node.
  """
  @spec get_left_value() :: tree_side()
  def get_left_value(), do: @left_value

  # Setters

  @doc """
  Updates the ID of the given node.

  ## Parameters
  - `node`: The node to update.
  - `id`: The new ID.

  ## Returns
  A new node with the updated ID.
  """
  @spec set_id(t, node_ID) :: t
  def set_id(%__MODULE__{} = node, id), do: %__MODULE__{node | id: id}

  @doc """
  Updates the value of the given node.

  ## Parameters
  - `node`: The node to update.
  - `value`: The new value.

  ## Returns
  A new node with the updated value.
  """
  @spec set_value(t, node_value) :: t
  def set_value(%__MODULE__{} = node, value), do: %__MODULE__{node | value: value}

  @doc """
  Updates the parent ID of the given node.

  ## Parameters
  - `node`: The node to update.
  - `parent`: The new parent ID.

  ## Returns
  A new node with the updated parent ID.
  """
  @spec set_parent(t, node_ID) :: t
  def set_parent(%__MODULE__{} = node, parent), do: %__MODULE__{node | parent: parent}

  @doc """
  Updates the side of the given node.

  ## Parameters
  - `node`: The node to update.
  - `side`: The new side (`:left` or `:right`).

  ## Returns
  A new node with the updated side.
  """
  @spec set_side(t, tree_side) :: t
  def set_side(%__MODULE__{} = node, side), do: %__MODULE__{node | side: side}

  @doc """
  Compares two node IDs to determine if the first is less than the second.

  ## Parameters
  - `id1`: The first node ID.
  - `id2`: The second node ID.

  ## Returns
  `true` if `id1` is less than `id2`, `false` otherwise.
  """
  @spec id_less_than(node_ID, node_ID) :: boolean()
  def id_less_than({_, a}, {_, b}), do: a < b
end
