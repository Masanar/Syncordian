defmodule Syncordian.Fugue.Tree do
  alias Syncordian.Fugue.Node

  defstruct nodes: %{}
  @type nodeValue_list :: [Node.nodeValue()]
  @type nodeID_List :: [Node.nodeID()]
  @type node_entry :: {Node.t(), nodeID_List(), nodeID_List()}
  @type t :: %__MODULE__{
          nodes: %{Node.nodeID() => node_entry}
        }

  @spec new() :: t
  def new do
    root = Node.root()

    %__MODULE__{
      nodes: %{root.id => {root, [], []}}
    }
  end

  @spec values(t) :: nodeValue_list()
  def values(tree), do: traverse(tree)

  @spec traverse(t, Node.nodeID()) :: nodeValue_list()
  def traverse(tree, id \\ Node.get_null_id()) do
    traverse_acc_reduce =
      fn id, acc
        -> traverse(tree, id) ++ acc
      end
    recursion =
      fn nodeId_List
        -> Enum.reduce(nodeId_List, [], traverse_acc_reduce)
      end

    case Map.get(tree.nodes, id) do
      {node, left, right} ->
        left_values = recursion.(left)

        node_value =
          if Node.get_value(node) != Node.get_tombstone(),
            do: [Node.get_value(node)],
            else: []

        right_values = recursion.(right)

        left_values ++ node_value ++ right_values

      nil -> []
    end

  end

end
