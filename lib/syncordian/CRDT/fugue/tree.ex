defmodule Syncordian.Fugue.Tree do
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

  @spec new() :: tree()
  def new do
    root = Node.root()

    %__MODULE__{
      nodes: %{root.id => {root, [], []}}
    }
  end

  @spec get_root(tree()) :: node_fugue() | nil
  def get_root(tree) do
    case Map.get(tree.nodes, Node.get_null_id()) do
      {node, _left, _right} -> node
      nil -> nil
    end
  end

  @spec values(tree()) :: [node_fugue()]
  def values(tree), do: traverse(tree)

  @spec traverse(tree()) :: [node_fugue()]
  def traverse(tree), do: traverse(tree, Node.get_null_id())

  @spec full_traverse(tree()) :: [node_fugue()]
  def full_traverse(tree) do
    traverse(tree, Node.get_null_id(), true)
  end

  @spec traverse(tree(), Node.node_ID(), boolean()) :: [node_fugue()]
  def traverse(tree, id, tombstone \\ false) do
    traverse_acc_reduce = fn id, acc ->
      traverse(tree, id) ++ acc
    end

    recursion = fn nodeId_List ->
      Enum.reduce(nodeId_List, [], traverse_acc_reduce)
    end

    case Map.get(tree.nodes, id) do
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

  @spec right_child_exists?(tree(), Node.node_ID()) :: boolean()
  defp right_child_exists?(tree, id) do
    Enum.any?(tree.nodes, fn
      {_id, {node, _left, _right}} ->
        Node.get_parent(node) == id and Node.get_side(node) == Node.get_right_value()
    end)
  end

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
      Enum.find_index(full_traversal,
      fn node ->
        Node.get_id(node) == left_origin_id
      end)

    right_origin = Enum.at(full_traversal, left_origin_index + 1)
    right_origin_id = if right_origin,
                      do: Node.get_id(right_origin),
                      else: Node.get_null_id()

    case right_child_exists?(tree, left_origin_id) do
      false ->
        Node.new(id, value, left_origin_id, Node.get_right_value())

      true ->
        Node.new(id, value, right_origin_id, Node.get_left_value())
    end
  end

  # THE END
end
