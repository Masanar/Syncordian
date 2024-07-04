defmodule Syncordian.Peer do
  @moduledoc """
    This module is responsible for the peer structure and the peer operations provides the
    following functions:
    - start(peer_id) : starts a peer with the given peer_id
    - insert(pid,content,index) : inserts a content at the given index
    - info(pid) : prints the document of the peer
    - raw_print(pid) : prints the document of the peer without the peer structure
  """
  use TypeCheck
  require Record
  import Syncordian.Info
  import Syncordian.Line
  import Syncordian.Document
  import Syncordian.Byzantine
  import Syncordian.Line_Object
  import Syncordian.Utilities
  import Syncordian.Vector_Clock
  @delete_limit 10_000
  Record.defrecord(:peer,
    peer_id: None,
    document: None,
    pid: None,
    deleted_count: 0,
    deleted_limit: @delete_limit,
    vector_clock: []
  )

  @type peer ::
          record(:peer,
            peer_id: Syncordian.Basic_Types.peer_id(),
            document: Syncordian.Basic_Types.document(),
            pid: pid(),
            deleted_count: integer(),
            deleted_limit: integer(),
            vector_clock: list[integer]
          )

  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop peer function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})

  def print_content(pid), do: send(pid, {:print_content, :document})

  def save_content(pid), do: send(pid, {:save_content, :document})

  @doc """
    This function is used to delete a line at the given index in the current document of the
    peer by sending a message to the loop peer function.
  """
  # def delete_line(pid, index_position, local_tombstones, empty_found) do
  #   case empty_found do
  #     true ->
  #       send(pid, {:delete_line, index_position, local_tombstones})
  #     false ->
  #       send(pid, {:delete_line, index_position, 0})
  #   end
  # end

  # @doc """
  #   This function inserts a content at the given index and a pid by sending a message to the
  #   loop peer function. The messages uses the following format:
  #   {:insert,[content,index]}
  # """
  # # @spec insert(pid, String.t(), integer, integer) :: any
  # def insert(pid, content, index_position, local_tombstones,empty_found) do
  #   case empty_found do
  #     true ->
  #       send(pid, {:insert, content, index_position, local_tombstones})
  #     false ->
  #       send(pid, {:insert, content, index_position, 0})
  #   end

  # end
  @doc """
    This function is used to delete a line at the given index in the current document of the
    peer by sending a message to the loop peer function.
  """
  def delete_line(pid, index_position), do: send(pid, {:delete_line, index_position})

  @doc """
    This function inserts a content at the given index and a pid by sending a message to the
    loop peer function. The messages uses the following format:
    {:insert,[content,index]}
  """
  @spec insert(pid, String.t(), integer) :: any
  def insert(pid, content, index_position), do: send(pid, {:insert, [content, index_position]})

  @doc """
    This function starts a peer with the given peer_id and registers it in the global registry.
    The returned content is the pid of the peer. The pid is the corresponding content of the
    pid of the spawned process.
  """
  @spec start(Syncordian.Basic_Types.peer_id(), integer) :: pid
  def start(peer_id, network_size) do
    pid = spawn(__MODULE__, :loop, [define(peer_id, network_size)])
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, network_size, peer_id)
    pid
  end

  defp get_peer_pid(peer), do: peer(peer, :pid)

  @doc """
    This function is the main loop of the peer, it receives messages and calls the
    appropriate functions to handle them.
  """
  @spec loop(peer()) :: any
  def loop(peer) do
    receive do
      # {:delete_line, index_position, local_tombstones} ->
      {:delete_line, index_position} ->
        document = get_peer_document(peer)
        document_len = get_document_length(document)

        case document_len - 1 <= index_position or document_len < 0 do
          true ->
            IO.puts("The to delete line does not exist! ")
            IO.inspect("Index position: #{index_position} ")
            IO.puts("Document length: #{document_len}")
            loop(peer)

          _ ->
            # shift_due_to_tombstone = get_number_of_tombstones_before_index_delete(document, index_position) - local_tombstones
            shift_due_to_tombstone =
              get_number_of_tombstones_before_index_delete(document, index_position)

            peer =
              document
              |> update_document_line_status(index_position + shift_due_to_tombstone, :tombstone)
              |> update_peer_document(peer)

            line_deleted =
              get_document_line_by_index(document, index_position + shift_due_to_tombstone)

            line_deleted_id = line_deleted |> get_line_id

            [left_parent, right_parent] =
              get_document_line_fathers(document, line_deleted)

            line_delete_signature = create_signature_delete(left_parent, right_parent)

            # if peer(peer, :peer_id) == 25 and index_position < 15 do
            # if peer(peer, :peer_id) == 27  do
            #   IO.puts("--------------------------------------------------------")
            #   IO.inspect("Index position: #{index_position} ")
            #   IO.inspect("local tombstones: #{local_tombstones}")
            #   IO.inspect("Shift due to tombstone: #{shift_due_to_tombstone}")
            #   IO.inspect("Line deleted: #{line_to_string(line_deleted)}")
            #   document = get_peer_document(peer) |> Enum.slice(index_position..index_position + 5)
            #   IO.inspect(document)
            #   IO.puts("--------------------------------------------------------")
            # end

            send(
              get_peer_id(peer),
              {:send_delete_broadcast, {line_deleted_id, line_delete_signature, 0}}
            )

            tick_peer_deleted_count(peer)
        end

      {:receive_delete_broadcast, {line_deleted_id, line_delete_signature, attempt_count}} ->
        # TODO: (question) Should we keep the delete attempt count? I think that YES
        document = get_peer_document(peer)
        current_document_line = get_document_line_by_line_id(document, line_deleted_id)
        current_document_line? = current_document_line != nil
        [left_parent, right_parent] = get_document_line_fathers(document, current_document_line)

        valid_signature? =
          check_signature_delete(
            line_delete_signature,
            left_parent,
            right_parent
          )

        max_attempts_reach? = compare_max_insertion_attempts(attempt_count)

        case {valid_signature? and current_document_line?, max_attempts_reach?} do
          {true, false} ->
            index_position_tmp = get_document_index_by_line_id(document, line_deleted_id)

            # shift_due_to_tombstone = get_number_of_tombstones_before_index(document, index_position_tmp)
            # index_position = index_position_tmp - shift_due_to_tombstone
            index_position = index_position_tmp

            peer =
              document
              |> update_document_line_status(index_position, :tombstone)
              |> update_peer_document(peer)

            tick_peer_deleted_count(peer)

          {false, false} ->
            IO.inspect("Requesting a deletion requeue: #{line_deleted_id}")

            send(
              get_peer_pid(peer),
              {:receive_delete_broadcast,
               {line_deleted_id, line_delete_signature, attempt_count + 1}}
            )

            loop(peer)

          {_, true} ->
            IO.inspect(
              "A line has reach its deletion attempts limit! in peer #{get_peer_id(peer)} \n"
            )

            loop(peer)
        end

      {:send_delete_broadcast, delete_line_info} ->
        perform_broadcast(peer, {:receive_delete_broadcast, delete_line_info})
        # :global.registered_names()
        # |> Enum.filter(fn x -> get_peer_pid(peer) != :global.whereis_name(x) end)
        # |> Enum.map(fn x ->
        #   send(x |> :global.whereis_name(), {:receive_delete_broadcast, delete_line_info})
        # end)

        loop(peer)

      # This correspond to the insert process do it by the peer
      # {:insert, content, index_position, local_tombstones} ->
      {:insert, [content, index_position]} ->
        document = get_peer_document(peer)
        peer_id = get_peer_id(peer)

        # shift_due_to_tombstone = get_number_of_tombstones_before_index(document, index_position) - local_tombstones
        shift_due_to_tombstone =
          get_number_of_tombstones_before_index(document, index_position) - 0

        [left_parent, right_parent] =
          get_parents_by_index(document, index_position + shift_due_to_tombstone)

        new_line =
          create_line_between_two_lines(
            content,
            left_parent,
            right_parent,
            peer_id
          )

        peer =
          new_line
          |> add_line_to_document(document)
          |> update_peer_document(peer)
          |> tick_individual_peer_clock

        current_vector_clock = peer(peer, :vector_clock)

        # if peer(peer, :peer_id) == 25 and index_position < 15 do
        #   IO.puts("--------------------------------------------------------")
        #   IO.inspect("Index position: #{index_position} ")
        #   IO.inspect("Shift due to tombstone: #{shift_due_to_tombstone}")
        #   IO.inspect("New line: #{line_to_string(new_line)}")
        #   IO.puts("")
        #   document = get_peer_document(peer) |> Enum.take(12)
        #   IO.inspect(document)
        #   IO.puts("--------------------------------------------------------")
        # end

        send(get_peer_pid(peer), {:send_insert_broadcast, {new_line, current_vector_clock}})
        loop(peer)

      {:send_insert_broadcast, {new_line, insertion_state_vector_clock}} ->
        perform_broadcast(
          peer,
          {:receive_insert_broadcast, new_line, insertion_state_vector_clock}
        )

        # :global.registered_names()
        # |> Enum.filter(fn x -> get_peer_pid(peer) != :global.whereis_name(x) end)
        # |> Enum.map(fn x ->
        #   send(
        #     x |> :global.whereis_name(),
        #     {:receive_insert_broadcast, new_line, insertion_state_vector_clock}
        #   )
        # end)
        loop(peer)

      {:receive_confirmation_line_insertion, {inserted_line_id, received_peer_id}} ->
        get_peer_document(peer)
        |> update_document_line_commit_at(inserted_line_id, received_peer_id)
        |> update_peer_document(peer)
        |> loop

      {:receive_insert_broadcast, line, incoming_vc} ->
        # TODO: In some part the local vc of the incoming peer need to be updated
        incoming_peer_id = get_line_peer_id(line)
        local_vector_clock = get_local_vector_clock(peer)

        clock_distance_usual =
          distance_between_vector_clocks(
            local_vector_clock,
            incoming_vc,
            incoming_peer_id
          )

        clock_distance =
          if clock_distance_usual == 0 do
            projection_distance(local_vector_clock, incoming_vc)
          else
            clock_distance_usual
          end

        case {clock_distance > 1, clock_distance == 1} do
          {true, _} ->
            # debug_function.(1)
            send(get_peer_pid(peer), {:receive_insert_broadcast, line, incoming_vc})
            loop(peer)

          {_, true} ->
            order_vc =
              order_vector_clocks_definition(
                local_vector_clock,
                incoming_vc
              )

            document = get_peer_document(peer)
            # HERE this function get_document_... was afected for HERE changes
            line_index = get_document_new_index_by_incoming_line_id(line, document)
            [left_parent, right_parent] = get_parents_by_index(document, line_index)

            debug_function = fn x ->
              local_peer_id = get_peer_id(peer)
              line_id = get_line_id(line)

              file_name =
                "debug/local:#{local_peer_id}_" <>
                  "#{line_id}_incoming:#{incoming_peer_id}" <>
                  "_insertions:#{get_line_insertion_attempts(line)}"

              file_content =
                "Reason  : #{x}\n" <>
                  "Local   : #{Enum.join(local_vector_clock, ", ")}\n" <>
                  "Incoming: #{Enum.join(incoming_vc, ", ")}\n" <>
                  "Distance: #{clock_distance}\n" <>
                  "Line index: #{line_index} \n" <>
                  "Projection Distance: #{projection_distance(local_vector_clock, incoming_vc)}\n" <>
                  "Left line content : #{line_to_string(left_parent)}\n" <>
                  "Line content      : #{line_to_string(line)}\n" <>
                  "Right line content: #{line_to_string(right_parent)}"

              File.write!(file_name, file_content)
            end

            case order_vc do
              # local_vc < incoming_vc
              true ->
                # check the signature of the incoming line
                # - if it is valid merge the line
                # - else:
                #   - if room for lines attempts requeue and loop over
                #   - else delete the line from the queue and loop over
                # TODO: check if the next code could be refactored into a function
                valid_line? = check_signature_insert(left_parent, line, right_parent)
                insertion_attempts_reach? = check_insertions_attempts(line)

                case {valid_line?, insertion_attempts_reach?} do
                  {true, false} ->
                    send_confirmation_line_insertion(
                      get_peer_id(peer),
                      incoming_peer_id,
                      get_line_id(line)
                    )

                    add_line_to_document(line, document)
                    |> update_peer_document(peer)
                    |> tick_projection_peer_clock(incoming_peer_id)
                    |> loop

                  {false, false} ->
                    debug_function.("Requesting requeue")
                    # new_line = tick_line_insertion_attempts(line)
                    # send(get_peer_pid(peer), {:receive_insert_broadcast, new_line, incoming_vc})
                    loop(peer)

                  {false, true} ->
                    loop(peer)
                end

              # local_vc > incoming_vc
              false ->
                # HERE
                # TODO: Check the interleaving!
                {valid_line?, _} =
                  stash_document_lines(document, line, local_vector_clock, incoming_vc)

                case valid_line? do
                  true ->
                    # TODO: This is repeted code! Should be a function!
                    send_confirmation_line_insertion(
                      get_peer_id(peer),
                      incoming_peer_id,
                      get_line_id(line)
                    )

                    add_line_to_document(line, document)
                    |> update_peer_document(peer)
                    |> tick_projection_peer_clock(incoming_peer_id)
                    |> loop

                  false ->
                    IO.inspect("Stash process failed")
                    IO.inspect("peer: #{get_peer_id(peer)} \n")
                    loop(peer)
                end
            end

          {_, _} ->
            IO.inspect("Something happen")
            loop(peer)
        end

      {:print, _} ->
        IO.inspect(peer)
        loop(peer)

      {:print_content, :document} ->
        print_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      {:save_content, :document} ->
        save_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      {:save_pid, info} ->
        info
        |> update_peer_pid(peer)
        |> loop

      {_, _} ->
        IO.puts("Wrong message")
        loop(peer)
    end
  end

  defp check_deleted_lines_limit(peer) do
    case get_document_deleted_lines(peer) > @delete_limit do
      true ->
        # TODO: HERE call the mechanism of broadcast consensus -> update
        IO.puts(
          " \n __________________________________________________________________________ \n "
        )

        IO.puts(" The deleted lines limit has been reached by #{inspect(get_peer_id(peer))} ")

        IO.puts(" __________________________________________________________________________ \n ")
        loop(peer)

      _ ->
        loop(peer)
    end
  end

  defp should_filter_out?(name, peer_pid) do
    pid = :global.whereis_name(name)

    pid == peer_pid or
      pid == :global.whereis_name(:supervisor) or
      pid == :global.whereis_name(Swoosh.Adapters.Local.Storage.Memory)
  end

  # Function to perform the filtering and sending messages
  defp perform_broadcast(peer, message) do
    peer_pid = get_peer_pid(peer)

    :global.registered_names()
    |> Enum.filter(fn name -> not should_filter_out?(name, peer_pid) end)
    |> Enum.each(fn name ->
      pid = :global.whereis_name(name)
      send(pid, message)
    end)
  end

  # Getter for the current vector clock of the peer
  @spec get_local_vector_clock(peer()) :: list[integer]
  defp get_local_vector_clock(peer), do: peer(peer, :vector_clock)

  # This is a private function used to get the number of marked as deleted lines of the
  # document of the peer.
  @spec get_document_deleted_lines(peer()) :: integer
  defp get_document_deleted_lines(peer), do: peer(peer, :deleted_count)

  # This is a private function used whenever an update to the document is needed. It
  # updates the record peer with the new document.
  @spec update_peer_document(Syncordian.Basic_Types.document(), peer()) ::
          any
  defp update_peer_document(document, peer), do: peer(peer, document: document)

  # This is a private function used whenever an update to the pid is needed. It updates
  # the record peer with the new pid.
  @spec update_peer_pid({pid, integer(), Syncordian.Basic_Types.peer_id()}, peer()) :: peer()
  defp update_peer_pid({pid, network_size, peer_id}, peer),
    # TODO: Be careful when using this function the vector clock is always set to 0
    do:
      peer(peer,
        pid: pid,
        vector_clock: List.duplicate(0, network_size),
        peer_id: peer_id
      )

  defp get_peer_id(peer), do: peer(peer, :peer_id)

  defp get_peer_document(peer), do: peer(peer, :document)

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer, integer) :: any
  defp save_peer_pid(pid, network_size, peer_id),
    do: send(pid, {:save_pid, {pid, network_size, peer_id}})

  # This is a private function used to update the deleted count of the peer.
  defp tick_peer_deleted_count(peer) do
    new_count = peer(peer, :deleted_count) + 1

    peer(peer, deleted_count: new_count)
    |> check_deleted_lines_limit
  end

  # This is a private function used to instance the initial document of the peer within
  # the record peer.
  @spec define(Syncordian.Basic_Types.peer_id(), integer) :: peer()
  defp define(peer_id, network_size) do
    initial_peer_document = [
      create_infimum_line(peer_id, network_size),
      create_supremum_line(peer_id, network_size)
    ]

    peer(peer_id: peer_id, document: initial_peer_document)
  end

  # This function is used to update the vector clock of the peer, it increments only the
  # value of the peer_id in the vector clock. The tick is done by adding 1 to the value of
  # the peer_id in the vector clock.
  @spec tick_individual_peer_clock(peer()) :: peer()
  defp tick_individual_peer_clock(peer) do
    peer_id = peer(peer, :peer_id)
    vector_clock = peer(peer, :vector_clock)
    new_peer_clock_value = Enum.at(vector_clock, peer_id) + 1
    new_vector_clock = update_list_value(vector_clock, peer_id, new_peer_clock_value)
    peer(peer, vector_clock: new_vector_clock)
  end

  # This function is used to update only the specific projection in the vector clock of
  # the local peer, it increments the current projection value by one.
  @spec tick_projection_peer_clock(peer(), integer) :: peer()
  defp tick_projection_peer_clock(peer, projection) do
    local_vector_clock = peer(peer, :vector_clock)
    new_peer_clock_value = Enum.at(local_vector_clock, projection) + 1
    new_vector_clock = update_list_value(local_vector_clock, projection, new_peer_clock_value)
    peer(peer, vector_clock: new_vector_clock)
  end

  @doc """
    This function send a messages to the sending peer to update the commit list of the
    line that was inserted in the document of the receiving peer. As it just receive the
    peer id it has to search the pid of the sending peer in the global registry.
    When the message is received by the sending peer it is handled by the loop function
    of the peer module.
  """
  @spec send_confirmation_line_insertion(
          receiving_peer_id :: Syncordian.Basic_Types.peer_id(),
          sending_peer_id :: Syncordian.Basic_Types.peer_id(),
          inserted_line_id :: Syncordian.Basic_Types.line_id()
        ) :: any
  def send_confirmation_line_insertion(receiving_peer_id, sending_peer_id, inserted_line_id) do
    sending_peer_pid = :global.whereis_name(sending_peer_id)

    send(
      sending_peer_pid,
      {:receive_confirmation_line_insertion, {inserted_line_id, receiving_peer_id}}
    )
  end
end
