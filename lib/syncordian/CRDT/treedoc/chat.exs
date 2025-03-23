defmodule Chat do

  def insert({pos_id, msg}) do
    # IO.puts(msg)
    Agent.update(Tree, fn state -> CRDT.insert(state, {pos_id, msg}) end)
  end

  def delete(pos_id) do
    # IO.inspect(pos_id)
    Agent.update(Tree, fn state -> CRDT.delete(state, pos_id) end)
  end

  def print_all_messages() do
    Agent.get(Tree, &(&1)) |> CRDT.print_all_messages()
  end

  def print_actual() do
    Agent.get(Tree, &(&1)) |> CRDT.print_actual()
  end
end

defmodule CRDT do
  def new() do
    Agent.start(fn -> BST.new([], fn a, b -> a.id - b.id end) end, name: Tree)
  end

  def insert(tree, {pos_id, msg}) when is_number(pos_id) do
    new = %{id: pos_id, msg: msg, status: true}
    BST.insert(tree, new)
  end

  def insert(tree, {pos_id, msg}) when is_number(pos_id) == false do
    pos_id = String.split(pos_id, "_")
    id = Enum.at(pos_id, 0)
    {id, _} = Integer.parse(id)
    new = %{id: id, msg: msg, status: true}
    BST.insert(tree, new)
  end

  def delete(tree, pos_id) do
    pos_id = String.split(pos_id, "_")
    id = Enum.at(pos_id, 0)
    {id, _} = Integer.parse(id)
    BST.update(tree, %{id: id, status: false}, fn a, b ->
      %{a | status: b.status} end)
  end

  def print_all_messages(tree) do
    messages = BST.to_list(tree)
    Enum.each(messages, fn map ->
      IO.puts(map.msg)
    end)
  end

  def print_actual(tree) do
    BST.to_list(tree)
      |> Enum.filter(fn map -> map.status == true end)
      |> Enum.each(fn map -> IO.puts(map.msg) end)
  end
end
