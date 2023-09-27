defmodule Logoot.Structures do
  @min_int 0
  @max_int 32767
  def lower_bound(site_id), do: [[@min_int, site_id]]
  def upper_bound(site_id), do: [[@max_int, site_id]]

  def show_document_str(document), do: Enum.reduce(document, "", fn [_,value], acc -> acc <> value end)
  def show_document_map(document) do 
    document 
    |> Enum.reduce([%{},0], fn [_,value],[map,count] -> [Map.put(map,count,value) ,count+1] end)
  end

  def add_atom_to_document(document = [head | tail = [next, _]], atom = [[position, _], _]) do
    [[previous_position, _], _] = head
    [[next_position, _], _] = next

    case {compare_positions(position, next_position),
          compare_positions(position, previous_position)} do
      {1, -1} -> [head | [atom | tail]]
      {1, 1} -> [head | add_atom_to_document(tail, atom)]
      {-1, 1} -> IO.puts("Sequence Error")
      {0, 0} -> document
    end
  end

  def create_atom_identifier_between_two(site_id, current_clock, previous_atom, next_atom) do
    [previous_position, _] = previous_atom
    [next_position, _] = next_atom
    position = new_position_between_two(site_id, previous_position, next_position)
    [position, current_clock + 1]
  end

  def compare_positions([], []), do: 0
  def compare_positions([], _), do: -1
  def compare_positions(_, []), do: 1

  def compare_positions([head_p | tail_p], [head_q | tail_q]) do
    case compare_identifiers(head_p, head_q) do
      0 -> compare_positions(tail_p, tail_q)
      1 -> 1
      -1 -> -1
    end
  end

  defp compare_identifiers([pos_p, site_p], [pos_q, site_q]) do
    case {pos_p < pos_q or (pos_p == pos_q and site_p < site_q),
          pos_p > pos_q or (pos_p == pos_q and site_p > site_q)} do
      {true, _} -> -1
      {_, true} -> 1
      {_, _} -> 0
    end
  end

  def new_position_between_two(_, [], []), do: []

  def new_position_between_two(site_id, [], pos1) do
    new_position_between_two_aux(site_id, lower_bound(site_id), pos1)
  end

  def new_position_between_two(site_id, pos0, []) do
    new_position_between_two_aux(site_id, pos0, upper_bound(site_id))
  end

  def new_position_between_two(site_id, pos0, pos1) do
    new_position_between_two_aux(site_id, pos0, pos1)
  end

  defp new_position_between_two_aux(site_id, [[head_pos0, head_site0] | tail_pos0], [
         [head_pos1, head_site1] | tail_pos1
       ]) do
    head_0 = [head_pos0, head_site0]
    head_1 = [head_pos1, head_site1]

    case compare_identifiers(head_0, head_1) do
      -1 ->
        distance = head_pos1 - head_pos0

        case {distance > 1, distance == 1 and site_id > head_site0} do
          {true, _} -> site_id |> random_position(head_pos0, head_pos1)
          {_, true} -> [[head_pos0, site_id]]
          {_, _} -> [head_0] ++ new_position_between_two(site_id, tail_pos0, tail_pos1)
        end

      0 ->
        [head_0] ++ new_position_between_two(site_id, tail_pos0, tail_pos1)

      1 ->
        new_position_between_two(site_id, [[head_pos1, head_site1] | tail_pos1], [
          [head_pos0, head_site0] | tail_pos0
        ])
    end
  end

  defp random_position(site_id, range0, range1),
    do: [[Enum.random((range0 + 1)..(range1 - 1)), site_id]]
end