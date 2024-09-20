defmodule Syncordian.Utilities do
  @moduledoc """
      This module provides utility functions used in the Syncordian implementation, that
      do not fit on the main modules.
  """

  @doc """
    Generates a random string of a given length, is length is not provided, it defaults to
    10.
  """
  @spec generate_string(integer()) :: String.t()
  def generate_string(length \\ 10) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode16()
    |> binary_part(0, length)
  end

  @spec update_list_value([any()], integer, any) :: [any()]
  def update_list_value([head | tail], index, value),
    do: update_list_value([head | tail], index, value, 0)

  @spec update_list_value([any()], integer, any, integer) :: [any()]
  defp update_list_value([head | tail], index, value, acc) do
    case index == acc do
      true -> [value | tail]
      false -> [head | update_list_value(tail, index, value, acc + 1)]
    end
  end

  def add_element_list_in_given_index(list, index, new_element) do
    Enum.concat(Enum.take(list, index + 1), [new_element | Enum.drop(list, index + 1)])
  end

  def get_less_than_one_positive_random() do
    random = abs(:rand.normal(0, 0.002))

    if random > 1 do
      get_less_than_one_positive_random()
    else
      random
    end
  end

  def get_random_range(right, left) do
    get_less_than_one_positive_random() * (right - left) + left
  end

  def remove_first_and_last([_head | []]), do: []
  def remove_first_and_last([_head | tail]), do: remove_last(tail)

  def remove_last([]), do: []
  def remove_last([_head | []]), do: []
  def remove_last([head | tail]), do: [head | remove_last(tail)]

  def delete_contents(directory) do
    directory
    |> Path.expand()
    |> File.ls!()
    |> Enum.reject(&(&1 == ".gitignore"))  # Exclude the .gitignore file
    |> Enum.each(&delete_entry(Path.join(directory, &1)))
  end

  defp delete_entry(path) do
    case File.stat!(path) do
      %File.Stat{type: :directory} ->
        File.ls!(path)
        |> Enum.each(&delete_entry(Path.join(path, &1)))

        File.rmdir!(path)

      _ ->
        File.rm!(path)
    end
  end

  @doc """
    Terminates all the processes
  """
  def kill do
    :global.registered_names()
    |> Enum.map(fn x -> :global.whereis_name(x) |> Process.exit(:kill) end)
  end
end
