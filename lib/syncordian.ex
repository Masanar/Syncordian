defmodule Syncordian do
  use TypeCheck
  import Syncordian.Peer
  @moduledoc """
  Documentation for `Syncordian`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Syncordian.test

  """
  def test do
    # pid = start(0)
    pid_0 = start(0,2)
    pid_1 = start(1,2)
    # pid_2 = start(2)


    insert(pid_0, "First of 0\n", 0)
    insert(pid_0, "Second of 0\n", 1)
    insert(pid_0, "Third of 0\n", 2)
    insert(pid_0, "test\n", 2)
    insert(pid_0, "test2\n", 2)

    # insert(pid_1, "first of 1\n", 2)
    # insert(pid_0, " of 0\n", 3)
    # delete_line(pid_0, 2)
    # delete_line(pid_0, 3)

    Process.sleep(8000)
    print_content(pid_1)
    Process.sleep(4000)
    print_content(pid_0)
    Process.sleep(4000)

    # IO.puts("\n----------------------------------------------\n")
    # Process.sleep(200)
    # raw_print(pid_0)
    # IO.puts("\n----------------------------------------------\n")
    # Process.sleep(200)
    # raw_print(pid_1)
    # Process.sleep(200)


    kill()
  end

  # defp name(peer_id), do: :global.whereis_name(peer_id)

  def kill do
    :global.registered_names()
    |> Enum.map(fn x -> :global.whereis_name(x) |> Process.exit(:kill) end)
  end

end
