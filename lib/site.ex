defmodule CRDT.Site do
  @moduledoc """
    This module is responsible for the site structure and the site operations provides the
    following functions:
    - start(peer_id) : starts a site with the given id
    - insert(pid,content,index) : inserts a content at the given index
    - info(pid) : prints the document of the site
    - raw_print(pid) : prints the document of the site without the site structure
  """
  import CRDT.Line
  import CRDT.Document
  import CRDT.Info
  require Record
  @delete_limit 10_000
  Record.defrecord(:site,
    id: None,
    document: None,
    pid: None,
    deleted_count: 0,
    deleted_limit: @deleted_limit
  )

  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop site function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})


  def delete_line(pid,index_position) ,do:
    send(pid, {:delete_line, index_position})

  @doc """
    This function inserts a content at the given index and a pid by sending a message to the
    loop site function. The messages uses the following format:
    {:insert,[content,index]}
  """
  @spec insert(pid, String.t(), integer) :: any
  def insert(pid, content, index_position), do: send(pid, {:insert, [content, index_position]})

  @doc """
    This function starts a site with the given id and registers it in the global registry.
    The returned content is the pid of the site. The pid is the corresponding content of the
    pid of the spawned process.
  """
  @spec start(CRDT.Types.peer_id()) :: pid
  def start(peer_id) do
    pid = spawn(__MODULE__, :loop, [define(peer_id)])
    :global.register_name(peer_id, pid)
    save_site_pid(pid)
    IO.puts("#{inspect(peer_id)} registered at #{inspect(pid)}")
    pid
  end

  @doc """
  This function is the main loop of the site, it receives messages and calls the
  appropriate functions to handle them.
  """
  @spec loop(CRDT.Types.site()) :: any
  def loop(site) do
    receive do
      # {:info, _} ->
      #   site(site, :document)
      #   |> print_document_info
      #   loop(site)
      {:delete_line, index_position} ->
        document = site(site, :document)
        document_len = get_document_length(document)
        case document_len - 1 <= index_position or document_len < 0  do
          true ->
            IO.puts("This line does not exist! \n")
            loop(site)
          _ -> 
            site = document
            |> update_line_status(index_position, true)
            |> update_site_document(site)

            tick_site_deleted_count(site)
            |> loop
            # TODO: Check if the deleted limit is reached, I think that this is possible by 
            # checking the length of the document and the number of deleted lines, or maybe
            # change the clock to be just the number of lines deleted. 
        end

      # This correspond to the insert process do it by the peer
      {:insert, [content, index_position]} ->
        document = site(site, :document)
        [left_parent, right_parent] = get_parents_by_index(document, index_position)
        # site_new_clock = tick_site_clock(site, current_clock + 1)

        create_line_between_two_lines(content, left_parent, right_parent)
        |> add_line_to_document(document)
        |> update_site_document(site)
        |> loop

      # TODO: Send the broadcast to the other sites and migrate that implementation
      # send(self(), {:send_broadcast, sequence})

      # {:send_broadcast, sequence} ->
      #   :global.registered_names()
      #   |> Enum.filter(fn x -> self() != :global.whereis_name(x) end)
      #   |> Enum.map(fn x -> send(x |> :global.whereis_name(), {:receive_broadcast, sequence}) end)

      #   loop(site)

      # {:receive_broadcast, sequence} ->
      #   document = site(site, :document)
      #   current_clock = site(site, :clock)
      #   site_new_clock = tick_site_clock(site, current_clock + 1)

      #   sequence
      #   |> add_sequence_to_document(document)
      #   |> update_site_document(site_new_clock)
      #   |> loop

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
    This is a private function used to save the pid of the site in the record.
  """
  @spec save_site_pid(pid) :: any
  defp save_site_pid(pid), do: send(pid, {:save_pid, pid})

  @doc """
  Given a document and a position index, this function returns the previous and next
  parents of the given index.
  """
  @spec get_parents_by_index(CRDT.Types.document(), integer) :: any
  defp get_parents_by_index(document, 0), do: [Enum.at(document, 0), Enum.at(document, 1)]

  defp get_parents_by_index(document, pos_index) do
    pos_index = pos_index + 1
    len = get_document_length(document)

    case {Enum.at(document, pos_index), Enum.at(document, pos_index - 1)} do
      {nil, _} -> [Enum.at(document, len - 2), Enum.at(document, len - 1)]
      {next, previous} -> [previous, next]
    end
  end

  @doc """
  This is a private function used to update the deleted count of the site.
  """
  defp tick_site_deleted_count(site) do
    new_count = site(site, :deleted_count) + 1
    site(site, deleted_count: new_count)
  end

  @doc """
    This is a private function used to instance the initial document of the site within
    the record site.
  """
  defp define(peer_id) do
    initial_site_document = [create_infimum_line(peer_id), create_supremum_line(peer_id)]
    site(id: peer_id, document: initial_site_document)
  end
end
