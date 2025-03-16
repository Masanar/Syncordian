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
  - `node_value_list`: A list of node values.
  - `node_id_list`: A list of node IDs.
  - `node_entry`: A tuple `{node_fugue, node_id_list, node_id_list}` representing a node and its children.
  - `tree`: The struct representing the tree.
  """

  alias Syncordian.Fugue.Node

  defstruct nodes: %{}

  @type node_fugue :: Node.t()
  @type node_value_list :: [Node.node_value()]
  @type node_id_list :: [Node.node_ID()]
  @type node_entry :: {node_fugue(), node_id_list(), node_id_list()}
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
  Inserts a new node into the tree.

  This function is used internally to add a new node to the tree's `nodes` map.

  ## Parameters
  - `tree`: The tree to update.
  - `node`: The node to insert.
  - `left`: A list of IDs representing the left children of the node.
  - `right`: A list of IDs representing the right children of the node.

  ## Returns
  A new
  """
  @spec put_node(tree(), node_fugue(), node_id_list(), node_id_list()) :: tree()
  def put_node(tree, node, left \\ [], right \\ []) do
    %{nodes: nodes} = tree
    new_nodes = Map.put(nodes, Node.get_id(node), {node, left, right})
    %__MODULE__{nodes: new_nodes}
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
  Retrieves the node at a specific position from the list of nodes in the tree.
  This function traverses the tree to get a list of nodes and returns the node
  at the specified position. If the position is out of bounds or the tree is empty,
  it returns the root node.

  ## Parameters
  - `tree`: The tree to retrieve the node from.
  - `position`: The position of the node in the list (0-based index).

  ## Returns
  The node at the specified position, or the root node if the position is invalid.
  """
  @spec node_i_position_from_values(tree(), integer()) :: node_fugue()
  def node_i_position_from_values(tree, position) do
    case traverse(tree) do
      [] -> get_root(tree) || Node.root()
      list -> Enum.at(list, position) || get_root(tree)
    end
  end

  @doc """
  Inserts a node ID into a sorted list of node IDs while maintaining the order.

  ## Parameters
  - `node_ID`: The node ID to insert.
  - `node_id_list`: The sorted list of node IDs.

  ## Returns
  A new list with the node ID inserted at the correct position.
  """
  @spec insert_index_on_node_id_list(Node.node_ID(), node_id_list()) :: node_id_list()
  def insert_index_on_node_id_list(node_ID, node_id_list) do
    index = Enum.find_index(node_id_list, fn x -> Node.id_less_than(Node.get_id(x), node_ID) end)
    List.insert_at(node_id_list, index, node_ID)
  end

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

  ########################### CRDT Functions ##################################

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
  Traverses the tree starting from a specific node ID.

  ## Parameters
  - `tree`: The tree to traverse.
  - `id`: The ID of the starting node.
  - `include_tombstones`: Whether to include tombstones in the traversal.

  ## Returns
  A list of nodes in the tree starting from the given node ID.
  """
  @spec traverse(tree(), Node.node_ID(), boolean()) :: [node_fugue()]
  def traverse(tree, id, include_tombstones \\ false) do
    traverse_acc_reduce = fn id, acc ->
      traverse(tree, id) ++ acc
    end

    recursion = fn node_id_list ->
      Enum.reduce(node_id_list, [], traverse_acc_reduce)
    end
    root_node = Node.root()
    case get_full_node(tree, id) do
      # TODO: This patter should be mactched else the function will never halt!!!!
      # SUPER IMPORTANT!!!!!!!!!!!!!!!!!!!!!!!!
      {^root_node, [],[]} ->
        []
      {node, left, right} ->
        left_values = recursion.(left)

        node_value =
          if Node.get_value(node) != Node.get_tombstone() or include_tombstones,
            do: [Node.get_value(node)],
            else: []

        right_values = recursion.(right)
        # TODO: ++ is O(n) is could be optimized by using acc in the reduce, but this
        #       implies to make a reverse: first right, then node, then left.
        left_values ++ node_value ++ right_values
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
  def right_child_exists?(tree, id) do
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

    left_origin = node_i_position_from_values(tree, position - 1)

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

  @doc """
  Inserts a node into the tree at the correct position based on its parent and side.

  This function updates the tree's structure by adding the node to the appropriate
  sibling lists of its parent.

  ## Parameters
  - `tree`: The tree to update.
  - `node`: The node to insert.

  ## Returns
  A new tree struct with the node inserted.
  """
  @spec insert_local(tree(), node_fugue()) :: tree()
  def insert_local(tree, node) do
    node_id = Node.get_id(node)
    node_side = Node.get_side(node)
    node_parent = Node.get_parent(node)
    {parent, left_sibs, right_sibs} = get_full_node(tree, node_parent)

    new_right_sibs =
      if node_side == Node.get_right_value(),
        do: insert_index_on_node_id_list(node_id, right_sibs),
        else: right_sibs

    new_left_sibs =
      if node_side == Node.get_left_value(),
        do: insert_index_on_node_id_list(node_id, left_sibs),
        else: left_sibs

    put_node(tree, parent, new_left_sibs, new_right_sibs)
    |> put_node(node)
  end

  @doc """
  Deletes a node from the tree by its position.

  This function retrieves the node at the specified position in the tree and returns its ID.
  Note that this function does not actually remove the node from the tree structure; it only
  retrieves the ID of the node at the given position.

  ## Parameters
  - `tree`: The tree from which to delete the node.
  - `position`: The position of the node to delete (0-based index).

  ## Returns
  The ID of the node at the specified position.
  """
  @spec delete(tree(), integer()) :: Node.node_ID()
  def delete(tree, position) do
    node = node_i_position_from_values(tree, position)
    Node.get_id(node)
  end

  @doc """
  Marks a node as deleted in the tree by setting its value to a tombstone.

  This function updates the specified node in the tree by replacing its value with
  a tombstone marker. The node itself is not removed from the tree structure, but
  its value is marked as deleted.

  ## Parameters
  - `tree`: The tree to update.
  - `node_ID`: The ID of the node to mark as deleted.

  ## Returns
  A new tree struct with the specified node marked as deleted.
  """
  @spec delete_local(tree(), Node.node_ID()) :: tree()
  def delete_local(tree, node_ID) do
    tombstone_value = Node.get_tombstone()
    {node, ls, rs} = get_full_node(tree, node_ID)
    updated_node = Node.set_value(node, tombstone_value)
    put_node(tree, updated_node, ls, rs)
  end
end
