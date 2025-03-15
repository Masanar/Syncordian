defmodule Syncordian.Fugue.Tree do
  @moduledoc """
  This module defines the `Syncordian.Fugue.Tree` structure and provides utility functions
  for creating, manipulating, and querying a CRDT-based tree structure.

  The tree is composed of nodes (`Syncordian.Fugue.Node`) and maintains a map of node IDs
  to their corresponding entries. Each entry contains:
  - The node itself.
  - A list of left child node IDs.
  - A list of right child node IDs.

  ## Types
  - `node_fugue`: Represents a node in the tree (`Syncordian.Fugue.Node.t()`).
  - `nodeValue_list`: A list of node values.
  - `nodeID_List`: A list of node IDs.
  - `node_entry`: A tuple `{node_fugue, nodeID_List, nodeID_List}` representing a node and its children.
  - `tree`: The struct representing the tree.
  """

  alias Syncordian.Fugue.Node

  defstruct nodes: %{}

  @type node_fugue :: Node.t()
  @type nodeValue_list :: [Node.node_value()]
  @type nodeID_List :: [Node.node_ID()]
  @type node_entry :: {node_fugue(), nodeID_List(), nodeID_List()}
  @type t :: %__MODULE__{
          nodes: %{Node.node_ID() => node_entry}
        }
  @type tree :: t()

  @doc """
  Creates a new tree with a single root node.

  ## Returns
  A new tree struct with the root node initialized.
  """
  @spec new() :: tree()
  def new do
    root = Node.root()

    %__MODULE__{
      nodes: %{root.id => {root, [], []}}
    }
  end

  @doc """
  Retrieves the map of nodes in the tree.

  ## Parameters
  - `tree`: The tree to retrieve nodes from.

  ## Returns
  A map where keys are node IDs and values are node entries.
  """
  @spec get_tree_nodes(tree()) :: %{Node.node_ID() => node_entry}
  def get_tree_nodes(tree), do: tree.nodes

  @doc """
  Retrieves the root node of the tree.

  ## Parameters
  - `tree`: The tree to retrieve the root node from.

  ## Returns
  The root node if it exists, otherwise `nil`.
  """
  @spec get_root(tree()) :: node_fugue() | nil
  def get_root(tree) do
    case Map.get(get_tree_nodes(tree), Node.get_null_id()) do
      {node, _left, _right} -> node
      nil -> nil
    end
  end

  @doc """
  Retrieves a node from the tree by its ID.

  ## Parameters
  - `tree`: The tree to retrieve the node from.
  - `id`: The ID of the node to retrieve.

  ## Returns
  The node if it exists, otherwise the root node.
  """
  @spec get_node(tree(), Node.node_ID()) :: node_fugue()
  def get_node(tree, id) do
    case Map.get(get_tree_nodes(tree), id) do
      {node, _left, _right} -> node
      nil -> Node.root()
    end
  end

  @doc """
  Retrieves a full node entry from the tree by its ID.

  ## Parameters
  - `tree`: The tree to retrieve the node entry from.
  - `id`: The ID of the node to retrieve.

  ## Returns
  A tuple `{node, left_children, right_children}` if the node exists,
  otherwise a tuple with the root node and empty child lists.
  """
  @spec get_full_node(tree(), Node.node_ID()) :: node_entry
  def get_full_node(tree, id) do
    case Map.get(get_tree_nodes(tree), id) do
      {node, left, right} -> {node, left, right}
      nil -> {Node.root(), [], []}
    end
  end

  @doc """
  Retrieves all node values in the tree.

  ## Parameters
  - `tree`: The tree to retrieve values from.

  ## Returns
  A list of node values.
  """
  @spec values(tree()) :: [node_fugue()]
  def values(tree), do: traverse(tree)

  @doc """
  Traverses the tree and retrieves all nodes.

  ## Parameters
  - `tree`: The tree to traverse.

  ## Returns
  A list of nodes in the tree.
  """
  @spec traverse(tree()) :: [node_fugue()]
  def traverse(tree), do: traverse(tree, Node.get_null_id())

  @doc """
  Traverses the tree and retrieves all nodes, including tombstones.

  ## Parameters
  - `tree`: The tree to traverse.

  ## Returns
  A list of nodes in the tree, including tombstones.
  """
  @spec full_traverse(tree()) :: [node_fugue()]
  def full_traverse(tree) do
    traverse(tree, Node.get_null_id(), true)
  end

  @doc """
  Traverses the tree starting from a specific node ID.

  ## Parameters
  - `tree`: The tree to traverse.
  - `id`: The ID of the starting node.
  - `tombstone`: Whether to include tombstones in the traversal.

  ## Returns
  A list of nodes in the tree starting from the given node ID.
  """
  @spec traverse(tree(), Node.node_ID(), boolean()) :: [node_fugue()]
  def traverse(tree, id, tombstone \\ false) do
    traverse_acc_reduce = fn id, acc ->
      traverse(tree, id) ++ acc
    end

    recursion = fn nodeId_List ->
      Enum.reduce(nodeId_List, [], traverse_acc_reduce)
    end

    case get_full_node(get_tree_nodes(tree), id) do
      {node, left, right} ->
        left_values = recursion.(left)

        node_value =
          if Node.get_value(node) != Node.get_tombstone() or tombstone,
            do: [Node.get_value(node)],
            else: []

        right_values = recursion.(right)
        # TODO: ++ is O(n) is could be optimized by using acc in the reduce, but this
        #       implies to make a reverse: first right, then node, then left.
        left_values ++ node_value ++ right_values

      nil ->
        []
    end
  end

  @doc """
  Checks if a right child exists for a given node ID.

  ## Parameters
  - `tree`: The tree to check.
  - `id`: The ID of the node to check.

  ## Returns
  `true` if a right child exists, `false` otherwise.
  """
  @spec right_child_exists?(tree(), Node.node_ID()) :: boolean()
  defp right_child_exists?(tree, id) do
    Enum.any?(get_tree_nodes(tree), fn
      {_id, {node, _left, _right}} ->
        Node.get_parent(node) == id and Node.get_side(node) == Node.get_right_value()
    end)
  end

  @doc """
  Inserts a new node into the tree.

  ## Parameters
  - `tree`: The tree to insert the node into.
  - `replica_id`: The replica ID for the new node.
  - `counter`: The counter value for the new node.
  - `position`: The position to insert the node at.
  - `value`: The value of the new node.

  ## Returns
  The newly created node.
  """
  @spec insert(tree(), String.t(), integer(), integer(), Node.node_value()) :: node_fugue()
  def insert(tree, replica_id, counter, position, value) do
    id = {replica_id, counter}

    left_origin =
      case traverse(tree) do
        [] -> get_root(tree) || Node.root()
        list -> Enum.at(list, position - 1) || get_root(tree)
      end

    left_origin_id = Node.get_id(left_origin)

    full_traversal = full_traverse(tree)

    left_origin_index =
      Enum.find_index(full_traversal, fn node ->
        Node.get_id(node) == left_origin_id
      end)

    right_origin = Enum.at(full_traversal, left_origin_index + 1)
    right_origin_id =
      if right_origin,
        do: Node.get_id(right_origin),
        else: Node.get_null_id()

    case right_child_exists?(tree, left_origin_id) do
      false ->
        Node.new(id, value, left_origin_id, Node.get_right_value())

      true ->
        Node.new(id, value, right_origin_id, Node.get_left_value())
    end
  end

  @spec insert_local(tree(), node_fugue()) :: tree()
  def insert_local(tree, node) do
    node_side = Node.get_side(node)
    node_parent = Node.get_parent(node)
    {parent, left_sibs, right_sibs}= get_full_node(get_tree_nodes(tree), node_parent)

  end

  # THE END
end
