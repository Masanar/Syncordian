defmodule Syncordian.Utilities do
  @moduledoc """
      This module provides utility functions used in the Syncordian implementation, that
      do not fit on the main modules.
  """
  @debug true
  @spec debug_print(String.t(), any()) :: any
  def debug_print(message, content) do
    case @debug do
      true ->
        IO.puts("")
        IO.puts("**********")
        IO.puts("DEBUG----> #{message}")
        IO.inspect(content)
        IO.puts("**********")
        IO.puts("")
      false -> :ok
    end
  end

  # Function to filter weather the peer is the current peer, the supervisor or the storage
  @spec should_filter_out?(any, pid) :: boolean
  defp should_filter_out?(name, peer_pid) do
    pid = :global.whereis_name(name)

    pid == peer_pid or
      pid == :global.whereis_name(:supervisor) or
      pid == :global.whereis_name(Swoosh.Adapters.Local.Storage.Memory)
  end

  @doc """
  Function to perform the filtering and broadcast messages to all peers in the network
  except the current peer. or the supervisor.
  """
  @spec perform_broadcast(pid(), any, any) :: any
  def perform_broadcast(pid, message, range) do
    :global.registered_names()
    |> Enum.filter(fn name -> not should_filter_out?(name, pid) end)
    |> Enum.each(fn name ->
      delay = Enum.random(range)
      pid = :global.whereis_name(name)
      Process.send_after(pid, message, delay)
    end)
  end

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

  def add_element_list_in_given_index(list, 0, new_element),
    do: [hd(list) | [new_element | tl(list)]]

  def add_element_list_in_given_index([head | tail], index, new_element) when index > 0 do
    [head | add_element_list_in_given_index(tail, index - 1, new_element)]
  end

  # def add_element_list_in_given_index(list, index, new_element) do
  #   Enum.concat(Enum.take(list, index + 1), [new_element | Enum.drop(list, index + 1)])
  # end

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
    # Exclude the .gitignore file
    |> Enum.reject(&(&1 == ".gitignore"))
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

  @doc """
    Function to get the process memory information returns given a list of process names.
    Returns a list of tuples with the total heap size and the message queue length.
    Overloaded function to get the memory information of a single process.
  """
  def process_memory_info(process_info = [_head | _tail]) do
    process_info
    |> Enum.map(fn x ->
      [total_heap_size: s, message_queue_len: m] =
        Process.info(x, [:total_heap_size, :message_queue_len])
      [s, m]
    end)
  end

  def process_memory_info(single_process_name) do
    [total_heap_size: s, message_queue_len: m] =
    Process.info(single_process_name, [:total_heap_size, :message_queue_len])
    [s, m]
  end

  @doc """
  Recursive helper to translate a Git index into the corresponding document/tree index,
  accounting for tombstones elements.

  This function traverses a list of elements (e.g., document lines or tree nodes) and skips
  elements based on the provided predicate `is_tombstone?`. The `target` represents the number
  of non-tombstones elements to skip. As the function traverses the list, it decrements `target`
  and increments the tombstone counter when a tombstone element is encountered. When `target` reaches
  zero, if the current element is not a tombstone it returns the current index; otherwise, it continues
  traversing. If the list is exhausted without finding a valid element, it returns -1.

  Parameters:
    - list: The list of elements to traverse.
    - target: The number of non-tombstones elements to skip.
    - tombstones: The count of tombstones elements encountered so far.
    - index: The current traversal index.
    - is_tombstone?: A function that accepts an element and returns `true` if it is considered tombstone.

  Returns:
    The computed index corresponding to the Git index or -1 if no valid position is found.
  """
  def do_translate_index([], 0, 0, index, _is_tombstone?), do: index - 1
  def do_translate_index([], _target, _tombstones, _index, _is_tombstone?), do: -1

  def do_translate_index([h | t], 0, 0, index, is_tombstone?) do
    if is_tombstone?.(h) do
      do_translate_index(t, 0, 0, index + 1, is_tombstone?)
    else
      index
    end
  end

  def do_translate_index([h | t], target, tombstones, index, is_tombstone?) do
    if is_tombstone?.(h) do
      do_translate_index(t, target - 1, tombstones + 1, index + 1, is_tombstone?)
    else
      do_translate_index(t, target - 1, tombstones, index + 1, is_tombstone?)
    end
  end
end
