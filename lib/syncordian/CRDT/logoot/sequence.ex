defmodule Syncordian.CRDT.Logoot.Sequence do
  @moduledoc """
  A sequence of atoms identified by `Logoot.atom_ident`s.
  """

  alias Syncordian.Basic_Types
  alias Syncordian.CRDT.Logoot.Agent

  @max_pos 32767
  @abs_min_atom_ident {[{0, 0}], 0}
  @abs_max_atom_ident {[{@max_pos, 0}], 1}

  @typedoc """
  The result of a comparison.
  """
  @type comparison :: :gt | :lt | :eq

  @typedoc """
  A tuple `{int, site}` where `int` is an integer and `site` is a site
  identifier.
  """
  @type ident :: {0..32767, Basic_Types.peer_id()}

  @typedoc """
  A list of `ident`s.
  """
  @type position :: [ident]

  @typedoc """
  A tuple `{pos, v}` generated at site `s` where
  `^pos = [ident_1, ident_2, {int, ^s}]` is a position and `v` is the value of
  the vector clock of site `s`.
  """
  @type atom_ident :: {position, non_neg_integer}
  @spec get_atom_ident_position_str(atom_ident) :: String.t()
  def get_atom_ident_position_str({position, _vc}) do
    position
    # Format each `ident` as "int@site"
    |> Enum.map(fn {int, site} -> "#{int}@#{site}" end)
    # Join the formatted `ident`s with " -> "
    |> Enum.join(" -> ")
  end

  @spec get_atom_ident_vc_str(atom_ident) :: String.t()
  def get_atom_ident_vc_str({_position, vc}), do: Integer.to_string(vc)

  @typedoc """
  An item in a sequence represented by a tuple `{atom_ident, data}` where
  `atom_ident` is a `atom_ident` and `data` is any term.
  """
  @type sequence_atom :: {atom_ident, Basic_Types.content()}

  @spec get_sequence_atom_ident(sequence_atom) :: atom_ident
  def get_sequence_atom_ident({atom_ident, _}), do: atom_ident

  @spec get_sequence_atom_value(sequence_atom) :: term
  def get_sequence_atom_value({_, value}), do: value

  @spec get_sequence_atom_position_str(sequence_atom) :: String.t()
  def get_sequence_atom_position_str(sequence_atom) do
    "position: " <>
      get_atom_ident_position_str(get_sequence_atom_ident(sequence_atom)) <>
      " vc: " <>
      get_atom_ident_vc_str(get_sequence_atom_ident(sequence_atom))
  end

  @spec get_sequence_atom_vc_str(sequence_atom) :: String.t()
  def get_sequence_atom_vc_str(sequence_atom) do
    get_atom_ident_vc_str(get_sequence_atom_ident(sequence_atom))
  end

  @typedoc """
  A sequence of `sequence_atoms` used to represent an ordered set.

  The first atom in a sequence will always be `@min_sequence_atom` and the last
  will always be `@max_sequence_atom`.

      [
        {{[{0, 0}], 0}, nil},
        {{[{32767, 0}], 1}, nil}
      ]
  """
  @type t :: [sequence_atom]
  @spec get_sequence_atom_by_index_delete(t, integer) :: sequence_atom
  def get_sequence_atom_by_index_delete(sequence, index) do
    cond do
      # Case: Sequence is empty (only contains min and max)
      length(sequence) == 2 ->
        # Return the min atom
        Enum.at(sequence, 0)

      # Case: Index is out of bounds (greater than the max index)
      index >= length(sequence) - 1 ->
        # Return the last valid atom (before max)
        Enum.at(sequence, length(sequence) - 2)

      # Case: Valid index
      true ->
        Enum.at(sequence, index)
    end
  end

  @spec get_sequence_atom_by_index(t, integer) :: sequence_atom
  def get_sequence_atom_by_index(sequence, index) do
    cond do
      index == 0 or length(sequence) == 2 ->
        Enum.at(sequence, 0)

      # Case: Index is out of bounds (greater than the max index)
      index >= length(sequence) - 2 ->
        # Return the last valid atom (before max)
        Enum.at(sequence, length(sequence) - 2)

      # Case: Valid index
      true ->
        Enum.at(sequence, index - 1)
    end
  end

  @typedoc """
  A `sequence_atom` that represents the beginning of any `Logoot.Sequence.t`.
  """
  @type abs_min_atom_ident :: {nonempty_list({0, 0}), 0}

  @typedoc """
  A `sequence_atom` that represents the end of any `Logoot.Sequence.t`.
  """
  @type abs_max_atom_ident :: {nonempty_list({32767, 0}), 1}

  @doc """
  Get the minimum sequence atom.
  """
  @spec min :: abs_min_atom_ident
  def min, do: @abs_min_atom_ident

  @doc """
  Get the maximum sequence atom.
  """
  @spec max :: abs_max_atom_ident
  def max, do: @abs_max_atom_ident

  @doc """
  Compare two atom identifiers.

  Returns `:gt` if first is greater than second, `:lt` if it is less, and `:eq`
  if they are equal.
  """
  @spec compare_atom_idents(atom_ident, atom_ident) :: comparison
  def compare_atom_idents(atom_ident_a, atom_ident_b) do
    compare_positions(elem(atom_ident_a, 0), elem(atom_ident_b, 0))
  end

  @doc """
  Delete the given atom from the sequence.
  """
  @spec delete_atom(t, sequence_atom) :: t
  def delete_atom([atom | tail], atom), do: tail
  def delete_atom([head | tail], atom), do: [head | delete_atom(tail, atom)]
  def delete_atom([], _atom), do: []

  @doc """
  Get the empty sequence.
  """
  @spec empty_sequence :: [{abs_min_atom_ident | abs_max_atom_ident, nil}]
  def empty_sequence, do: [{min(), nil}, {max(), nil}]

  @doc """
  Insert a value into a sequence after the given atom identifier.

  Returns a tuple containing the new atom and the updated sequence.
  """
  @spec get_and_insert_after(t, atom_ident, term, Agent.t()) ::
          {:ok, {sequence_atom, Agent.t()}} | {:error, String.t()}
  def get_and_insert_after(sequence, prev_sibling_ident, value, agent) do
    prev_sibling_index =
      Enum.find_index(sequence, fn {atom_ident, _} ->
        atom_ident == prev_sibling_ident
      end)

    {next_sibling_ident, _} = Enum.at(sequence, prev_sibling_index + 1)

    case gen_atom_ident(agent, prev_sibling_ident, next_sibling_ident) do
      error = {:error, _} ->
        error

      {:ok, {atom_ident, agent}} ->
        new_sequence_atom = {atom_ident, value}
        new_sequence = List.insert_at(sequence, prev_sibling_index + 1, new_sequence_atom)
        new_agent = Agent.update_sequence(agent, new_sequence)

        {:ok, {new_sequence_atom, new_agent}}
    end
  end

  @doc """
  Insert the given atom into the sequence.
  """
  @spec insert_atom(t, sequence_atom) :: {:ok, t} | {:error, String.t()}
  def insert_atom(list = [prev | tail = [next | _]], atom) do
    {{prev_position, _}, _} = prev
    {{next_position, _}, _} = next
    {{position, _}, _} = atom

    case {compare_positions(position, prev_position), compare_positions(position, next_position)} do
      {:gt, :lt} ->
        {:ok, [prev | [atom | tail]]}

      {:gt, :gt} ->
        case insert_atom(tail, atom) do
          error = {:error, _} -> error
          {:ok, tail} -> {:ok, [prev | tail]}
        end

      {:lt, :gt} ->
        {:error, "Sequence out of order"}

      {_, :eq} ->
        {:ok, list}
    end
  end

  @doc """
  Return only the values from the sequence.
  """
  @spec get_values(t) :: [term]
  def get_values(sequence) do
    sequence
    # Drop the first element
    |> Enum.drop(1)
    # Drop the last element
    |> Enum.drop(-1)
    |> Enum.map(&elem(&1, 1))
  end

  # Compare two positions.
  @spec compare_positions(position, position) :: comparison
  defp compare_positions([], []), do: :eq
  defp compare_positions(_, []), do: :gt
  defp compare_positions([], _), do: :lt

  defp compare_positions([head_a | tail_a], [head_b | tail_b]) do
    case compare_idents(head_a, head_b) do
      :gt -> :gt
      :lt -> :lt
      :eq -> compare_positions(tail_a, tail_b)
    end
  end

  @doc """
  Generate an atom identifier between `min` and `max`.
  """
  @spec gen_atom_ident(Agent.t(), atom_ident, atom_ident) ::
          {:ok, {atom_ident, Agent.t()}} | {:error, String.t()}
  def gen_atom_ident(agent, min_atom_ident, max_atom_ident) do
    agent = Agent.tick_clock(agent)
    agent_clock = Agent.get_clock(agent)
    agent_id = Agent.get_id(agent)

    case gen_position(agent_id, elem(min_atom_ident, 0), elem(max_atom_ident, 0)) do
      {:error, _error_message} = error ->
        error

      position ->
        {:ok, {{position, agent_clock}, agent}}
    end
  end

  # Generate a position from an agent ID, min, and max
  @spec gen_position(Basic_Types.peer_id(), position, position) ::
          nonempty_list(ident) | {:error, String.t()}
  defp gen_position(agent_id, min_position, max_position) do
    {min_head, min_tail} = get_logical_head_tail(min_position, :min)
    {max_head, max_tail} = get_logical_head_tail(max_position, :max)

    {min_int, min_id} = min_head
    {max_int, _max_id} = max_head

    case compare_idents(min_head, max_head) do
      :lt ->
        case max_int - min_int do
          diff when diff > 1 ->
            [{random_int_between(min_int, max_int), agent_id}]

          diff when diff == 1 and agent_id > min_id ->
            [{min_int, agent_id}]

          _diff ->
            [min_head | gen_position(agent_id, min_tail, max_tail)]
        end

      :eq ->
        [min_head | gen_position(agent_id, min_tail, max_tail)]

      :gt ->
        {:error, "Max atom was lesser than min atom"}
    end
  end

  # Get the logical min or max head and tail.
  @spec get_logical_head_tail(position, :min | :max) :: {ident, position}
  defp get_logical_head_tail([], :min), do: {Enum.at(elem(min(), 0), 0), []}
  defp get_logical_head_tail([], :max), do: {Enum.at(elem(max(), 0), 0), []}
  defp get_logical_head_tail(position, _), do: {hd(position), tl(position)}

  # Generate a random int between two ints.
  @spec random_int_between(0..32767, 1..32767) :: 1..32766
  defp random_int_between(min, max) do
    :rand.uniform(max - min - 1) + min
  end

  # Compare two `ident`s, returning `:gt` if first is greater than second,
  # `:lt` if first is less than second, `:eq` if equal.
  @spec compare_idents(ident, ident) :: comparison
  defp compare_idents({int_a, _}, {int_b, _}) when int_a > int_b, do: :gt
  defp compare_idents({int_a, _}, {int_b, _}) when int_a < int_b, do: :lt
  defp compare_idents({_, site_a}, {_, site_b}) when site_a > site_b, do: :gt
  defp compare_idents({_, site_a}, {_, site_b}) when site_a < site_b, do: :lt
  defp compare_idents(_, _), do: :eq
end
