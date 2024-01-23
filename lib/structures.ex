defmodule Logoot.Structures do
  @min_int 130
  @max_int 32767

  @moduledoc """
    This module provides the structures used in the CRDT implementation   
  """

  """
  TODO: The system type in Elixir basically is just for documentation purposes, it does
  not enforce any type checking. Thus, in the type definition module I have to define
  the structure mainly based on tuples instead of list, due to type constraints (a list
  can't have multiple types). You will notice that the actual implementation uses lists
  instead of tuples but I used aforementioned tuples in the type definition module. I
  would change the implementation to use tuples instead as the type definition module
  proposes I would do it progressively.
  """

  @doc """
    Returns the document lower bound given the site_id 
  """
  @spec lower_bound(CRDT.Types.peer_id()) :: [CRDT.Types.id()]
  # def lower_bound(site_id), do: [{@min_int, site_id}]
  def lower_bound(site_id), do: [[@min_int, site_id]]

  @doc """
    Returns the document upper bound given the site_id   
  """
  @spec upper_bound(CRDT.Types.peer_id()) :: [CRDT.Types.id()]
  def upper_bound(site_id), do: [[@max_int, site_id]]

  @doc """
    Given a line and a document, it adds the line to the document in the right position.
  """
  @spec add_sequence_to_document(CRDT.Types.line(), CRDT.Types.document()) ::
          CRDT.Types.document()
  def add_sequence_to_document(atom = [[position, _], _], document = [head | tail = [next | _]]) do
    [[previous_position, _], _] = head
    [[next_position, _], _] = next

    case {compare_positions(position, next_position),
          compare_positions(position, previous_position)} do
      {1, 1} ->
        [head | add_sequence_to_document(atom, tail)]

      {1, -1} ->
        IO.puts("Sequence Error")

      {0, 0} ->
        document

      {_, 1} ->
        [head | [atom | tail]]

      {-1, -1} ->
        [head | [atom | tail]]
        # {0, 1} -> [head | [atom | tail]]
    end
  end

  @doc """
    Giving a pid and a content, it returns a line
  """
  @spec create_sequence_atom(CRDT.Types.id(), String.t()) :: CRDT.Types.line()
  def create_sequence_atom(atom_id, content), do: [atom_id, content]

  @doc """
    Given two lines, it returns a pid for a line between them
  """
  @spec create_atom_identifier_between_two_sequence(
          CRDT.Types.peer_id(),
          CRDT.Types.clock(),
          CRDT.Types.line(),
          CRDT.Types.line()
        ) :: CRDT.Types.pid_()
  def create_atom_identifier_between_two_sequence(site_id, current_clock, previous_seq, next_seq) do
    [previous_atom, _] = previous_seq
    [next_atom, _] = next_seq
    create_atom_identifier_between_two_atoms(site_id, current_clock, previous_atom, next_atom)
  end

  @doc """
    Given two pids, it returns a pid for a line between them
  """
  @spec create_atom_identifier_between_two_atoms(
          CRDT.Types.peer_id(),
          CRDT.Types.clock(),
          CRDT.Types.pid_(),
          CRDT.Types.pid_()
        ) :: CRDT.Types.pid_()
  defp create_atom_identifier_between_two_atoms(site_id, current_clock, previous_atom, next_atom) do
    [previous_position, _] = previous_atom
    [next_position, _] = next_atom
    position = new_position_between_two(site_id, previous_position, next_position)
    [position, current_clock + 1]
  end

  @doc """
    Given two list of id (i.e a pid without clock), the function defines a order between
    the ids
  """
  def compare_positions([], []), do: 0
  def compare_positions([], _), do: -1
  def compare_positions(_, []), do: 1

  @spec compare_positions([CRDT.Types.id()], [CRDT.Types.id()]) :: 0 | 1 | -1
  def compare_positions([head_p | tail_p], [head_q | tail_q]) do
    case compare_identifiers(head_p, head_q) do
      0 -> compare_positions(tail_p, tail_q)
      1 -> 1
      -1 -> -1
    end
  end

  @doc """
    Given two identifiers, the function defines a order between the identifiers
  """
  @spec compare_identifiers(CRDT.Types.id(), CRDT.Types.id()) :: 0 | 1 | -1
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

  @doc """
    Given two list[id] (i.e a pid without clock), the function returns a new list[id]
    between the two list[id] for a particular peer_id 
  """
  @spec new_position_between_two(
          CRDT.Types.peer_id(),
          [CRDT.Types.id()],
          [CRDT.Types.id()]
        ) :: [CRDT.Types.id()]
  def new_position_between_two(site_id, pos0, pos1) do
    new_position_between_two_aux(site_id, pos0, pos1)
  end

  @doc """
    Given two list[id] (i.e a pid without clock), the function returns a new list[id]
    between the two list[id] for a particular peer_id 
  """
  @spec new_position_between_two_aux(
          CRDT.Types.peer_id(),
          [CRDT.Types.id()],
          [CRDT.Types.id()]
        ) :: [CRDT.Types.id()]
  defp new_position_between_two_aux(site_id, [[head_pos0, head_site0] | tail_pos0], [
         [head_pos1, head_site1] | tail_pos1
       ]) do
    head_0 = [head_pos0, head_site0]
    head_1 = [head_pos1, head_site1]

    case compare_identifiers(head_0, head_1) do
      -1 ->
        distance = head_pos1 - head_pos0

        case {distance > 1, distance == 1 and site_id > head_site0} do
          {true, _} ->
            site_id |> random_position(head_pos0, head_pos1)

          {_, true} ->
            [[head_pos0, site_id]]

          {_, _} ->
            case {tail_pos0, tail_pos1} do
              {[], []} -> [head_0] ++ random_position(site_id, @min_int, @max_int)
              {_, _} -> [head_0] ++ new_position_between_two(site_id, tail_pos0, tail_pos1)
            end
        end

      0 ->
        [head_0] ++ new_position_between_two(site_id, tail_pos0, tail_pos1)

      1 ->
        new_position_between_two(site_id, [[head_pos1, head_site1] | tail_pos1], [
          [head_pos0, head_site0] | tail_pos0
        ])
    end
  end

  @doc """
    Given a site_id and a range, the function returns a random position between the range
  """
  @spec random_position(CRDT.Types.peer_id(), integer, integer) :: [CRDT.Types.id()]
  defp random_position(site_id, range0, range1) do
    random = :rand.uniform(range1 - range0 - 1) + range0
    [[random, site_id]]
  end
end
