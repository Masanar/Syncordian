defmodule Logoot do
  @moduledoc """
  Documentation for `BizantineLogoot`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Logoot.hello()
      :world

  """
  def test do
    pid = Logoot.Site.start(0)
    pid_0 = Logoot.Site.start(1)
    pid_1 = Logoot.Site.start(2)
    pid_2 = Logoot.Site.start(3)

    Logoot.Site.insert(pid_0, "first of 0\n", 0)
    Logoot.Site.insert(pid_1, "first of 1", 1)
    Logoot.Site.insert(pid_2, "first of 2\n", 2)

    for i <- 1..10 do
      Logoot.Site.insert(pid, "value#{i}\n", 0)
    end
    # Logoot.Site.info(pid)
    # Logoot.Site.raw_print(pid)
  end

  def name(peer_id), do: :global.whereis_name(peer_id)

  def kill do
    for i <- 0..3 do
      :global.whereis_name(i) |> Process.exit(:kill)
      IO.inspect("killed #{i}")
    end
  end

end
