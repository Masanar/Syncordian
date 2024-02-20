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
    pid_0 = start(0)
    pid_1 = start(1)
    # pid_2 = start(2)

    insert(pid_0, "first of 0\n", 0)
    insert(pid_0, "second of 0\n", 1)
    insert(pid_0, "third of 0\n", 2)
    insert(pid_0, "fourth of 0\n", 3)
    #
    Process.sleep(9000)
    #
    insert(pid_1, "first of 1", 1)
    insert(pid_1, "second of 1", 1)
    Process.sleep(4000)

    # insert(pid_2, "first of 2\n", 2)

    # for i <- 1..10 do
    #   insert(pid, "value#{i}\n", 0)
    # end
    # info(pid)
    # raw_print(pid_0)
    # delete_line(pid_0, 2)
    # delete_line(pid_0, 3)
    Process.sleep(2000)
    raw_print(pid_0)
    IO.inspect("\n\n\n")
    Process.sleep(2000)
    raw_print(pid_1)
    # IO.inspect("\n\n\n")
    # Process.sleep(2000)
    # raw_print(pid_2)
    # IO.inspect("\n\n\n")
    # Process.sleep(2000)
    # raw_print(pid_0)
    # IO.inspect("\n\n\n")
    # Process.sleep(3000)
    # kill()
  end

  defp name(peer_id), do: :global.whereis_name(peer_id)

  def kill do
    :global.registered_names()
    |> Enum.map(fn x -> :global.whereis_name(x) |> Process.exit(:kill) end)
  end

end
