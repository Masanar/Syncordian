defmodule Syncordian.Fugue.Node do
  @null_id {"", 0}
  @tombstone :tombstone

  @type nodeID :: {String.t(), integer()}
  @type treeSide :: :left | :right | nil
  @type nodeValue :: String.t() | :tombstone

  defstruct id: @null_id, value: @tombstone, parent: @null_id, side: nil

  @type t :: %__MODULE__{
          id: nodeID,
          value: nodeValue,
          parent: nodeID,
          side: treeSide
        }

  @spec root() :: t
  def root(), do: %__MODULE__{}

  @spec new(nodeID, nodeValue, nodeID, treeSide) :: t
  def new(id, value, parent, side),
    do: %__MODULE__{id: id, value: value, parent: parent, side: side}

  @spec is_root?(t) :: boolean()
  def is_root?(node), do: node.id == @null_id

  @spec is_leaf?(t) :: boolean()
  def is_leaf?(node), do: node.id != @null_id

  @spec get_null_id() :: nodeID
  def get_null_id(), do: @null_id

  @spec get_tombstone() :: nodeValue
  def get_tombstone(), do: @tombstone

  # Getters
  @spec get_id(t) :: nodeID
  def get_id(%__MODULE__{id: id}), do: id

  @spec get_value(t) :: nodeValue
  def get_value(%__MODULE__{value: value}), do: value

  @spec get_parent(t) :: nodeID
  def get_parent(%__MODULE__{parent: parent}), do: parent

  @spec get_side(t) :: treeSide
  def get_side(%__MODULE__{side: side}), do: side

  # Setters
  @spec set_id(t, nodeID) :: t
  def set_id(%__MODULE__{} = node, id), do: %__MODULE__{node | id: id}

  @spec set_value(t, nodeValue) :: t
  def set_value(%__MODULE__{} = node, value), do: %__MODULE__{node | value: value}

  @spec set_parent(t, nodeID) :: t
  def set_parent(%__MODULE__{} = node, parent), do: %__MODULE__{node | parent: parent}

  @spec set_side(t, treeSide) :: t
  def set_side(%__MODULE__{} = node, side), do: %__MODULE__{node | side: side}
end
