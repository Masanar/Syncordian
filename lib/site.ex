defmodule Logoot.Site do
  @moduledoc """
    This module is responsible for the site structure and the site operations provides the
    following functions:
    - start(site_id) : starts a site with the given id
    - insert(pid,value,index) : inserts a value at the given index
    - info(pid) : prints the document of the site
    - raw_print(pid) : prints the document of the site without the site structure
  """
  import Logoot.Structures
  import Logoot.Info
  require Record

  Record.defrecord(:site, id: None, clock: 1, document: None, pid: None)
  @min_float 130.0
  @max_float 230_584_300_921_369.0

  @doc """
  This function is the main loop of the site, it receives messages and calls the 
  appropriate functions to handle them.
  """
  @spec loop(CRDT.Types.site()) :: any
  def loop(site) do
    receive do
      {:info, _} ->
        site(site, :document)
        |> print_document_info

        loop(site)

      {:insert, [value, pos]} ->
        document = site(site, :document)
        [previous, next] = get_position_index(document, pos)
        current_clock = site(site, :clock)
        site_new_clock = tick_site_clock(site, current_clock + 1)

        sequence =
          site
          |> site(:id)
          |> create_atom_identifier_between_two_sequence(current_clock, previous, next)
          |> create_sequence_atom(value)

        send(self(), {:send_broadcast, sequence})

        sequence
        |> add_sequence_to_document(document)
        |> update_site_document(site_new_clock)
        |> loop

      {:send_broadcast, sequence} ->
        :global.registered_names()
        |> Enum.filter(fn x -> self() != :global.whereis_name(x) end)
        |> Enum.map(fn x -> send(x |> :global.whereis_name(), {:receive_broadcast, sequence}) end)

        loop(site)

      {:receive_broadcast, sequence} ->
        document = site(site, :document)
        current_clock = site(site, :clock)
        site_new_clock = tick_site_clock(site, current_clock + 1)

        sequence
        |> add_sequence_to_document(document)
        |> update_site_document(site_new_clock)
        |> loop

      {:print, _} ->
        IO.inspect(site)
        loop(site)

      {:save_pid, pid} ->
        pid
        |> update_site_pid(site)
        |> loop

      {_, _} ->
        IO.puts("Wrong message")
        loop(site)
    end
  end

  @doc """
    This function inserts a value at the given index and a pid by sending a message to the
    loop site function. The messages uses the following format:
    {:insert,[value,index]}
  """
  @spec insert(pid, String.t(), integer) :: any
  def insert(pid, content, index_position), do: send(pid, {:insert, [content, index_position]})

  @doc """
    This function prints the document as an string and the length of the document by
    sending a message to the loop site function with the atom :info.
  """
  @spec info(pid) :: any
  def info(pid), do: send(pid, {:info, :document})

  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop site function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})

  @doc """
    This function starts a site with the given id and registers it in the global registry.
    The returned value is the pid of the site. The pid is the corresponding value of the
    pid of the spawned process.
  """
  @spec start(CRDT.Types.peer_id()) :: pid
  def start(site_id) do
    pid = spawn(__MODULE__, :loop, [define(site_id)])
    :global.register_name(site_id, pid)
    save_site_pid(pid)
    IO.puts("#{inspect(site_id)} registered at #{inspect(pid)}")
    pid
  end

  @doc """
  This is a private function used to save the pid of the site in the record.
  """
  @spec save_site_pid(pid) :: any
  defp save_site_pid(pid), do: send(pid, {:save_pid, pid})

  @doc """
  This is a private function used whenever an update to the document is needed. It
  updates the record site with the new document.
  """
  @spec update_site_document(CRDT.Types.document(), CRDT.Types.site()) :: any
  defp update_site_document(document, site), do: site(site, document: document)

  @doc """
  This is a private function used whenever an update to the pid is needed. It updates
  the record site with the new pid.
  """
  @spec update_site_pid(pid, CRDT.Types.site()) :: any
  defp update_site_pid(pid, site), do: site(site, pid: pid)

  @doc """
  This is a private function used to get the position index of the document. 
  """
  @spec get_position_index(CRDT.Types.document(), integer) :: any
  defp get_position_index(document, 0), do: [Enum.at(document, 0), Enum.at(document, 1)]

  defp get_position_index(document, pos_index) do
    len = length(document)
    case {Enum.at(document, pos_index), Enum.at(document, pos_index - 1)} do
      {nil, _} -> [Enum.at(document, len - 2), Enum.at(document, len - 1)]
      {next, previous} -> [previous, next]
    end
  end

  @doc """
  This is a private function used to update the clock of record  site.
  """
  defp tick_site_clock(site, new_clock_value) do
    site(site, clock: new_clock_value)
  end

  @doc """
    This is a private function used to instance the initial document of the site within
    the record site.
  """
  defp define(site_id) do
    initial_site_document = [{@min_float, "Start"}, {@max_float, "End"}]
    site(id: site_id, document: initial_site_document)
  end
end
