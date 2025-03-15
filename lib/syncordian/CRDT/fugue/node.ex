defmodule Syncordian.Fugue.Node do
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

  @spec root() :: t
  def root(), do: %__MODULE__{}

  @spec new(node_ID, node_value, node_ID, tree_side) :: t
  def new(id, value, parent, side),
    do: %__MODULE__{id: id, value: value, parent: parent, side: side}

  @spec is_root?(t) :: boolean()
  def is_root?(node), do: node.id == @null_id

  @spec is_leaf?(t) :: boolean()
  def is_leaf?(node), do: node.id != @null_id

  @spec get_null_id() :: node_ID
  def get_null_id(), do: @null_id

  @spec get_tombstone() :: node_value
  def get_tombstone(), do: @tombstone

  # Getters
  @spec get_id(t | nil) :: node_ID
  def get_id(nil), do: @null_id
  def get_id(%__MODULE__{id: id}), do: id

  @spec get_value(t) :: node_value
  def get_value(%__MODULE__{value: value}), do: value

  @spec get_parent(t) :: node_ID
  def get_parent(%__MODULE__{parent: parent}), do: parent

  @spec get_side(t) :: tree_side
  def get_side(%__MODULE__{side: side}), do: side

  @spec get_right_value() :: tree_side()
  def get_right_value(), do: @right_value

  @spec get_left_value() :: tree_side()
  def get_left_value(), do: @left_value

  # Setters
  @spec set_id(t, node_ID) :: t
  def set_id(%__MODULE__{} = node, id), do: %__MODULE__{node | id: id}

  @spec set_value(t, node_value) :: t
  def set_value(%__MODULE__{} = node, value), do: %__MODULE__{node | value: value}

  @spec set_parent(t, node_ID) :: t
  def set_parent(%__MODULE__{} = node, parent), do: %__MODULE__{node | parent: parent}

  @spec set_side(t, tree_side) :: t
  def set_side(%__MODULE__{} = node, side), do: %__MODULE__{node | side: side}

end
