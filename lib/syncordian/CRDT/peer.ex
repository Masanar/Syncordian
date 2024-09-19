defmodule Syncordian.Peer do
  @moduledoc """
    This module is responsible for the peer structure and the peer operations provides the
    following functions:
    - start(peer_id) : starts a peer with the given peer_id
    - insert(pid,content,index) : inserts a content at the given index
    - info(pid) : prints the document of the peer
    - raw_print(pid) : prints the document of the peer without the peer structure
  """
  # use TypeCheck
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
            vector_clock: [integer]
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
    This function is use to delete a line at the given index in the current document of
    the peer by sending a message to the loop peer function. Where:
      - pid: the pid of the peer
      - index_position: the index position of the line to be deleted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.
  """
  @spec delete_line(pid, integer, integer, integer, integer) :: any
  def delete_line(pid, index_position, test_index, global_position, current_delete_ops),
    do:
      send(pid, {:delete_line, [index_position, test_index, global_position, current_delete_ops]})

  @doc """
    This function inserts a content at the given index and a pid by sending a message to
    the loop peer function. The messages uses the following format:
    {:insert,[content,index, global_position] }
    where:
      - content: the content to be inserted in the peers local document
      - index_position: the index position where the content will be inserted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.

  """
  @spec insert(pid, String.t(), integer, integer, integer, integer) :: any
  def insert(pid, content, index_position, test_index, global_position, current_delete_ops),
    do:
      send(
        pid,
        {:insert, [content, index_position, test_index, global_position, current_delete_ops]}
      )

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
      {:delete_line, [index_position, test_index, global_position, current_delete_ops]} ->
        document = get_peer_document(peer)
        document_len = get_document_length(document)

        case document_len - 1 <= index_position or document_len < 0 do
          true ->
            IO.puts("The to delete line does not exist! ")
            IO.inspect("Index position: #{index_position} ")
            IO.puts("Document length: #{document_len}")
            loop(peer)

          _ ->
            peer_id = get_peer_id(peer)

            shift_due_to_tombstone =
              get_number_of_tombstones_before_index(document, global_position)

            shift_due_other_peers_tombstones =
              get_number_of_tombstones_due_other_peers(
                document,
                global_position,
                index_position + shift_due_to_tombstone
              )

            no_check_until_no_tombstones =
              index_position + shift_due_to_tombstone +
                (shift_due_other_peers_tombstones - current_delete_ops)

            temp_new_index_position =
              check_until_no_tombstone(document, no_check_until_no_tombstones)

            # TODO: This seems to work, maybe need the same for the :insertion
            # also, code looks ugly find a way to refactor it
            new_index_position =
              cond do
                temp_new_index_position - no_check_until_no_tombstones == 1 and
                    no_check_until_no_tombstones < temp_new_index_position ->
                  temp_new_index_position

                no_check_until_no_tombstones < temp_new_index_position ->
                  case shift_due_other_peers_tombstones do
                    0 ->
                      if get_peer_id(peer) == 25 and global_position == 51 do
                      end

                      temp_new_index_position

                    _ ->
                      temp_new_index_position + (shift_due_other_peers_tombstones - 1)
                  end

                true ->
                  if get_peer_id(peer) == 25 and global_position == 51 do
                  end

                  temp_new_index_position
              end

            nicolas_index = nicolas_tenia_razon(document, test_index, 0, 0)
            peer =
              document
              |> update_document_line_status(nicolas_index, :tombstone)
              |> update_document_line_peer_id(nicolas_index, peer_id)
              |> update_peer_document(peer)

            line_deleted =
              get_document_line_by_index(document, nicolas_index)

            line_deleted_id = line_deleted |> get_line_id

            [left_parent, right_parent] =
              get_document_line_fathers(document, line_deleted)

            line_delete_signature = create_signature_delete(left_parent, right_parent)

          # if test_index == 85 and get_document_length(document) > 100 do
            # nicolas_index = nicolas_tenia_razon(document, test_index, 0, 0)
            # if nicolas_index != new_index_position do
            #   IO.puts("")
            #   IO.puts("DELETE OPERATION------------------------------------")
            #   IO.puts("Index from git parser new: #{test_index}")
            #   IO.puts("Index from git parser old: #{index_position}")
            #   IO.puts("Index used old: #{new_index_position}")
            #   IO.puts("Index used new: #{nicolas_index}")
            #   IO.puts("Line deleted: #{line_to_string(line_deleted)}")
            #   IO.puts("")
            # end
          # end

            send(
              get_peer_pid(peer),
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
            index_position = get_document_index_by_line_id(document, line_deleted_id)
            peer_id = get_peer_id(peer)

            peer =
              document
              |> update_document_line_status(index_position, :tombstone)
              |> update_document_line_peer_id(index_position, peer_id)
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
        loop(peer)

      # This correspond to the insert process do it by the peer
      {:insert, [content, index_position, test_index, global_position, current_delete_ops]} ->
        document = get_peer_document(peer)
        peer_id = get_peer_id(peer)
        # IO.inspect("Peer id: #{peer_id}")

        shift_due_to_tombstone =
          get_number_of_tombstones_before_index(document, global_position)

        shift_due_other_peers_tombstones =
          get_number_of_tombstones_due_other_peers(
            document,
            global_position,
            index_position + shift_due_to_tombstone
          )

        no_check_until_no_tombstones =
          index_position + shift_due_to_tombstone +
            shift_due_other_peers_tombstones

        temp_new_index =
          check_until_no_tombstone(
            document,
            no_check_until_no_tombstones - current_delete_ops
          )

        new_index_temp =
          check_until_no_tombstone(
            document,
            no_check_until_no_tombstones
          ) - current_delete_ops

        new_index =
          if new_index_temp < temp_new_index do
            temp_new_index
          else
            new_index_temp
          end

        nicolas_index = nicolas_tenia_razon(document, test_index, 0, 0)
        [left_parent, right_parent] =
          get_parents_by_index(
            document,
            nicolas_index
            # new_index
          )

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
        # if test_index == 85 and get_document_length(document) > 100 do
          # nicolas_index = nicolas_tenia_razon(document, test_index, 0, 0)
          # if nicolas_index != new_index do
          #   IO.puts("")
          #   IO.puts("INSERT OPERATION------------------------------------")
          #   IO.puts("Index from git parser new: #{test_index}")
          #   IO.puts("Index from git parser old: #{index_position}")
          #   IO.puts("Index used old: #{new_index}")
          #   IO.puts("Index used new: #{nicolas_index}")
          #   IO.puts("New line inserted: #{line_to_string(new_line)}")
          #   IO.puts("")
          # end
        # end

        send(get_peer_pid(peer), {:send_insert_broadcast, {new_line, current_vector_clock}})
        loop(peer)

      {:send_insert_broadcast, {new_line, insertion_state_vector_clock}} ->
        perform_broadcast(
          peer,
          {:receive_insert_broadcast, new_line, insertion_state_vector_clock}
        )

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
                  "Clock Distance: #{clock_distance}\n" <>
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
                    # TODO: Nothing is happening here
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

      {:request_live_view_document, live_view_pid} ->
        send(live_view_pid, {:receive_live_view_document, get_peer_document(peer)})
        loop(peer)

      {:save_pid, info} ->
        info
        |> update_peer_pid(peer)
        |> loop

      _ ->
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
  @spec get_local_vector_clock(peer()) :: [integer]
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
