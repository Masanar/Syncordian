defmodule Syncordian do
  use TypeCheck
  import Syncordian.Site
  @moduledoc """
  Documentation for `BizantineLogoot`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Syncordian.hello()
      :world

  """
  def test do
    # pid = Syncordian.Site.start(0)
    pid_0 = Syncordian.Site.start(1)
    pid_1 = Syncordian.Site.start(2)
    # pid_2 = Syncordian.Site.start(3)

    Syncordian.Site.insert(pid_0, "first of 0\n", 0)
    Syncordian.Site.insert(pid_0, "second of 0\n", 1)
    Syncordian.Site.insert(pid_0, "third of 0\n", 2)
    Syncordian.Site.insert(pid_0, "fourth of 0\n", 3)
    # Syncordian.Site.insert(pid_1, "first of 1", 1)
    # Syncordian.Site.insert(pid_2, "first of 2\n", 2)

    # for i <- 1..10 do
    #   Syncordian.Site.insert(pid, "value#{i}\n", 0)
    # end
    # Syncordian.Site.info(pid)
    # Syncordian.Site.raw_print(pid_0)
    # delete_line(pid_0, 2)
    # delete_line(pid_0, 3)
    Process.sleep(2000)
    Syncordian.Site.raw_print(pid_1)
    # Process.sleep(3000)
    # kill()
  end

  defp name(peer_id), do: :global.whereis_name(peer_id)

  def kill do
    :global.registered_names()
    |> Enum.map(fn x -> :global.whereis_name(x) |> Process.exit(:kill) end)
  end

end
