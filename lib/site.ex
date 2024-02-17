defmodule Syncordian.Site do
  @moduledoc """
    This module is responsible for the site structure and the site operations provides the
    following functions:
    - start(peer_id) : starts a site with the given peer_id
    - insert(pid,content,index) : inserts a content at the given index
    - info(pid) : prints the document of the site
    - raw_print(pid) : prints the document of the site without the site structure
  """
  use TypeCheck
  import Syncordian.Info
  import Syncordian.Document
  import Syncordian.Byzantine
  import Syncordian.Line
  import Syncordian.Line_Object
  require Record
  @delete_limit 10_000
  Record.defrecord(:site,
    peer_id: None,
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

  def delete_line(pid, index_position), do: send(pid, {:delete_line, index_position})

  @doc """
    This function inserts a content at the given index and a pid by sending a message to the
    loop site function. The messages uses the following format:
    {:insert,[content,index]}
  """
  @spec insert(pid, String.t(), integer) :: any
  def insert(pid, content, index_position), do: send(pid, {:insert, [content, index_position]})

  @doc """
    This function starts a site with the given peer_id and registers it in the global registry.
    The returned content is the pid of the site. The pid is the corresponding content of the
    pid of the spawned process.
  """
  @spec start(Syncordian.Types.peer_id()) :: pid
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
  @spec loop(Syncordian.Types.site()) :: any
  def loop(site) do
    receive do
      {:delete_line, index_position} ->
        # TODO: Check if the deleted limit is reached, I think that this is possible by 
        # checking the length of the document and the number of deleted lines, or maybe
        # change the clock to be just the number of lines deleted. 
        # TODO: Send the broadcast to the other sites and migrate that implementation
        document = site(site, :document)
        document_len = get_document_length(document)

        case document_len - 1 <= index_position or document_len < 0 do
          true ->
            IO.puts("This line does not exist! \n")
            loop(site)

          _ ->
            site =
              document
              |> update_line_status(index_position, true)
              |> update_site_document(site)

            tick_site_deleted_count(site)
            |> check_deleted_lines_limit
        end

      # This correspond to the insert process do it by the peer
      {:insert, [content, index_position]} ->
        # TODO: Send the broadcast to the other sites and migrate that implementation
        document = site(site, :document)
        [left_parent, right_parent] = get_parents_by_index(document, index_position)
        # site_new_clock = tick_site_clock(site, current_clock + 1)

        new_line = create_line_between_two_lines(content, left_parent, right_parent)

        send(self(), {:send_broadcast, new_line})

        new_line
        |> add_line_to_document(document)
        |> update_site_document(site)
        |> loop

      {:receive_broadcast, line} ->
        # TODO: check the information and reduce the count if the line is not ready yet
        document = site(site, :document)
        line_content = get_content(line)
        line_index = get_document_index_by_line_id(line, document)
        [left_parent, right_parent] = get_parents_by_index(document, line_index)

        valid_line? = check_signature(left_parent, line, right_parent)
        insertion_attempts_reach? = get_line_insertion_attempts(line) > @max_insertion_attempts

        case {valid_line?, insertion_attempts_reach?} do
          {true, false} ->
            add_line_to_document(line, document)
            |> update_site_document(site)
            |> loop

          {false, false} ->
            new_line = tick_line_insertion_attempts(line)
            send(self(), {:receive_broadcast, new_line})
            loop(site)

          {false, true} ->
            IO.inspect("A line has reach its insertion attempts limit! in peer #{get_site_peer_id(site)} \n")
            loop(site)
        end

      {:send_broadcast, sequence} ->
        :global.registered_names()
        |> Enum.filter(fn x -> self() != :global.whereis_name(x) end)
        |> Enum.map(fn x -> send(x |> :global.whereis_name(), {:receive_broadcast, sequence}) end)

        loop(site)

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

  defp check_deleted_lines_limit(site) do
    case get_document_deleted_lines(site) > @delete_limit do
      true ->
        # TODO: HERE call the mechanism of broadcast consensus
        IO.puts(
          " \n __________________________________________________________________________ \n "
        )

        IO.puts(
          " The deleted lines limit has been reached by #{inspect(get_site_peer_id(site))} "
        )

        IO.puts(" __________________________________________________________________________ \n ")
        loop(site)

      _ ->
        loop(site)
    end
  end

  @doc """
    This is a private function used to get the index (position in the document i.e. list)
    of new line by its line_id. It calls an auxiliary function to do the job, passing the
    line_id, the document as arguments ant the initial index 0.
  """
  @spec get_document_index_by_line_id(Syncordian.Types.line(), Syncordian.Types.document()) :: integer
  defp get_document_index_by_line_id(line, document = [head | tail]) do
    line_id = get_line_id(line)
    get_document_index_by_line_id_aux(line_id, document, 0)
  end

  @doc """
    This is an private recursive auxiliar function over the length of the document to get
    the index of the line by its line_id.
    NOTE: It is important to keep the precondition of not having any line ID greater than
    the @max_float defined at Syncordian.Line module! or else this function will get to an empty
    document and will return an error. I define a case for this situation, but it is better
    just to ensure that the line_id is always less than the @max_float.
  """
  @spec get_document_index_by_line_id_aux(
          Syncordian.Types.line_id(),
          Syncordian.Types.document(),
          integer()
        ) :: integer

  defp get_document_index_by_line_id_aux(_, document = [], _) do
    IO.puts("There is an error with the line id it is greater than the maximum float")
    1
  end

  defp get_document_index_by_line_id_aux(line_id, document = [head | tail], index) do
    head_line_id = get_line_id(head)

    case line_id < head_line_id do
      true -> index
      _ -> get_document_index_by_line_id_aux(line_id, tail, index + 1)
    end
  end

  @doc """
    This is a private function used to get the number of marked as deleted lines of the
    document of the site.
  """
  @spec get_document_deleted_lines(Syncordian.Types.site()) :: integer
  defp get_document_deleted_lines(site), do: site(site, :deleted_count)

  @doc """
    This is a private function used whenever an update to the document is needed. It
    updates the record site with the new document.
  """
  @spec update_site_document(Syncordian.Types.document(), Syncordian.Types.site()) :: any
  defp update_site_document(document, site), do: site(site, document: document)

  @doc """
    This is a private function used whenever an update to the pid is needed. It updates
    the record site with the new pid.
  """
  @spec update_site_pid(pid, Syncordian.Types.site()) :: any
  defp update_site_pid(pid, site), do: site(site, pid: pid)

  defp get_site_peer_id(site), do: site(site, :peer_id)

  @doc """
    This is a private function used to save the pid of the site in the record.
  """
  @spec save_site_pid(pid) :: any
  defp save_site_pid(pid), do: send(pid, {:save_pid, pid})

  @doc """
    Given a document and a position index, this function returns the previous and next
    parents of the given index.
  """
  @spec get_parents_by_index(Syncordian.Types.document(), integer) :: any
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
    site(peer_id: peer_id, document: initial_site_document)
  end
end
