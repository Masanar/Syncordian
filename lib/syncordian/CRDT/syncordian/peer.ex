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
  import Syncordian.Metadata
  import Syncordian.Info
  import Syncordian.Line
  import Syncordian.Document
  import Syncordian.Byzantine
  import Syncordian.Line_Object
  import Syncordian.Utilities
  import Syncordian.Vector_Clock
  @delete_limit 10_000
  @peer_metadata_id 7
  Record.defrecord(:peer,
    peer_id: None,
    document: None,
    pid: None,
    deleted_count: 0,
    deleted_limit: @delete_limit,
    vector_clock: [],
    supervisor_pid: None,
    metadata: Syncordian.Metadata.metadata(),
    edit_count: 0
  )

  @type peer ::
          record(:peer,
            peer_id: Syncordian.Basic_Types.peer_id(),
            document: Syncordian.Basic_Types.document(),
            pid: pid(),
            deleted_count: integer(),
            deleted_limit: integer(),
            vector_clock: [integer],
            supervisor_pid: pid(),
            edit_count: integer()
          )

  ############################# Peer Data Structure Interface ############################
  # Getter and setter for the peer structure

  @spec get_edit_count(peer) :: integer()
  def get_edit_count(peer), do: peer(peer, :edit_count)

  @spec tick_edit_count(peer) :: peer
  def tick_edit_count(peer) do
    new_count = get_edit_count(peer) + 1
    peer(peer, edit_count: new_count)
  end

  @spec get_document_byte_size(peer()) :: integer
  def get_document_byte_size(peer) do
    document = get_peer_document(peer)
    inspect(document, limit: :infinity, printable_limit: :infinity)
    |> byte_size
  end

  @spec get_module_name() :: String.t()
  def get_module_name(), do: "syncordian"

  @spec get_metadata(peer()) :: Syncordian.Metadata.metadata()
  defp get_metadata(peer), do: peer(peer, :metadata)

  @spec update_metadata(Syncordian.Metadata.metadata(), peer()) :: peer()
  defp update_metadata(metadata, peer), do: peer(peer, metadata: metadata)

  @spec get_peer_supervisor_pid(peer()) :: pid()
  defp get_peer_supervisor_pid(peer), do: peer(peer, :supervisor_pid)

  @spec set_peer_supervisor_pid(peer(), pid()) :: peer()
  defp set_peer_supervisor_pid(peer, supervisor_pid),
    do: peer(peer, supervisor_pid: supervisor_pid)

  # This is a private function used to get the pid of the peer.
  @spec get_peer_pid(peer()) :: pid()
  defp get_peer_pid(peer), do: peer(peer, :pid)

  # This is a private function used to get the peer_id of the peer.
  @spec get_peer_id(peer()) :: Syncordian.Basic_Types.peer_id()
  defp get_peer_id(peer), do: peer(peer, :peer_id)

  # This is a private function used to get the document of the peer.
  @spec get_peer_document(peer()) :: Syncordian.Basic_Types.document()
  defp get_peer_document(peer), do: peer(peer, :document)

  # Getter for the current vector clock of the peer
  @spec get_peer_vector_clock(peer()) :: Syncordian.Basic_Types.vector_clock()
  defp get_peer_vector_clock(peer), do: peer(peer, :vector_clock)

  # This is a private function used to get the number of marked as deleted lines of the
  # document of the peer.
  @spec get_peer_deleted_count(peer()) :: integer
  defp get_peer_deleted_count(peer), do: peer(peer, :deleted_count)

  # This is a private function used whenever an update to the document is needed. It
  # updates the record peer with the new document.
  @spec update_peer_document(Syncordian.Basic_Types.document(), peer()) :: peer()
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

  # This function check is the deleted lines limit has been reached by the peer, in
  # theory this function should trigger the update mechanism of the peer. This feature
  # is not implemented yet. Instead it just prints a message in the console and continues
  # as usual.
  @spec check_deleted_lines_limit(peer()) :: any()
  defp check_deleted_lines_limit(peer) do
    if get_peer_deleted_count(peer) > @delete_limit do
      # TODO: HERE call the mechanism of broadcast consensus -> update
      IO.puts(" The deleted lines limit has been reached by #{get_peer_id(peer)} ")
    end

    loop(peer)
  end

  # This is a private function used to update the deleted count of the peer.
  @spec tick_peer_deleted_count(peer()) :: peer()
  defp tick_peer_deleted_count(peer) do
    new_count = get_peer_deleted_count(peer) + 1

    peer(peer, deleted_count: new_count)
    |> check_deleted_lines_limit
  end

  # This function is used to update the vector clock of the peer, it increments only the
  # value of the peer_id in the vector clock. The tick is done by adding 1 to the value of
  # the peer_id in the vector clock.
  @spec tick_individual_peer_clock(peer()) :: peer()
  defp tick_individual_peer_clock(peer) do
    peer_id = get_peer_id(peer)
    vector_clock = get_peer_vector_clock(peer)
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

  ########################################################################################

  ################################## Peer Loop Interface #################################
  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop peer function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})

  @doc """
    This function prints in console the whole document no matter if the status of the line
    each line of the document is printed in a new line as a string.
  """
  @spec print_content(pid) :: any
  def print_content(pid), do: send(pid, {:print_content, :document})

  @doc """
    This function saves the content of the document of the peer in a file with the name
    document_peer_{peer_id} where peer_id is the id of the peer. The file is saved in the
    debug/documents folder. This function filter the first and last line of the document
    and the lines that are marked as tombstone.
  """
  @spec save_content(pid) :: any
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
      send(
        pid,
        {:delete_line, [index_position, test_index, global_position, current_delete_ops]}
      )

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
    This function starts a peer with the given peer_id and registers it in the global
    registry. The returned content is the pid of the peer. The pid is the corresponding
    content of the pid of the spawned process.
  """
  @spec start(Syncordian.Basic_Types.peer_id(), integer) :: pid
  def start(peer_id, network_size) do
    pid = spawn(__MODULE__, :loop, [define(peer_id, network_size)])
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, network_size, peer_id)
    IO.puts("Logoot peer with id #{peer_id} started with pid #{inspect(pid)}")
    Process.send_after(pid, {:register_supervisor_pid}, 50)
    pid
  end

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer, integer) :: any
  defp save_peer_pid(pid, network_size, peer_id),
    do: send(pid, {:save_pid, {pid, network_size, peer_id}})

  ########################################################################################

  ################################ Peer utility ################################

  @spec save_peer_metadata_edit(peer()) :: peer()
  defp save_peer_metadata_edit(peer) do
    file_prefix = "edit"
    folder = "syncordian/"
    peer_pid = get_peer_pid(peer)
    current_edit = get_edit_count(peer)
    nodes_size = get_document_byte_size(peer)

    peer_up = peer
    |> get_metadata()
    |> update_memory_info(peer_pid, nodes_size)
    |> update_metadata(peer)

    get_metadata(peer_up)
    |> save_metadata_one_peer(current_edit, folder, file_prefix)

    peer_up
  end

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor. This one is define here because here the
  # delay makes sense to be define and then use the perform_broadcast function of the
  # utilities module.
  @spec perform_broadcast_peer(peer(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    # delay = 10..30
    delay = 0..0
    perform_broadcast(peer_pid, message, delay)
  end

  @doc """
    This function send a messages to the sending peer to update the commit list of the
    line that was inserted in the document of the receiving peer. As it just receive the
    peer id it has to search the pid of the sending peer in the global registry.
    When the message is received by the sending peer it is handled by the loop function
    of the peer module.
  """
  # TODO: This function is never use!
  @spec send_confirmation_line_insertion(
          receiving_peer_id :: Syncordian.Basic_Types.peer_id(),
          sending_peer_id :: Syncordian.Basic_Types.peer_id(),
          inserted_line_id :: Syncordian.Basic_Types.line_id()
        ) :: any
  def send_confirmation_line_insertion(
        receiving_peer_id,
        sending_peer_id,
        inserted_line_id
      ) do
    sending_peer_pid = :global.whereis_name(sending_peer_id)

    send(
      sending_peer_pid,
      {:receive_confirmation_line_insertion, {inserted_line_id, receiving_peer_id}}
    )
  end

  @spec add_valid_line_to_document_and_loop(
          peer(),
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.peer_id()
        ) :: any
  defp add_valid_line_to_document_and_loop(peer, line, incoming_peer_id) do
    document = get_peer_document(peer)
    peer_id = get_peer_id(peer)
    # TODO: THIS NEED TO BE UNCOMMENTED WHEN THE TEST IS DONE
    # send_confirmation_line_insertion(
    #   peer_id,
    #   incoming_peer_id,
    #   get_line_id(line)
    # )

    peer =
      add_line_to_document(line, document)
      |> update_peer_document(peer)
      |> tick_projection_peer_clock(incoming_peer_id)
      |> tick_edit_count()

    peer_ud = if peer_id == @peer_metadata_id, do:
              save_peer_metadata_edit(peer),
              else: peer

    loop(peer_ud)

  end

  @spec delete_valid_line_to_document_and_loop(
          peer :: peer(),
          document :: Syncordian.Basic_Types.document(),
          line_deleted_id :: Syncordian.Basic_Types.line_id()
        ) :: any
  defp delete_valid_line_to_document_and_loop(peer, document, line_deleted_id) do
    peer_id = get_peer_id(peer)
    index_position = get_document_index_by_line_id(document, line_deleted_id)

    peer =
      document
      |> update_document_line_status(index_position, :tombstone)
      |> update_document_line_peer_id(index_position, peer_id)
      |> update_peer_document(peer)
      |> tick_edit_count()

    peer_up = if peer_id == @peer_metadata_id, do:
           save_peer_metadata_edit(peer),
           else: peer

    tick_peer_deleted_count(peer_up)
  end

  ########################################################################################

  # TODO: I think that all the functions defined above could be moved into a different
  # modules, the peer module should only contain the loop function and the functions that
  # are used to interact with the loop function. But I am not sure about this.

  @doc """
    This function is the main loop of the peer, it receives messages and calls the
    appropriate functions to handle them.
  """
  @spec loop(peer()) :: any
  def loop(peer) do
    receive do
      # ✅
      {:delete_line, [index_position, test_index, _global_position, _current_delete_ops]} ->
        document = get_peer_document(peer)
        document_len = get_document_length(document)

        case document_len - 1 <= index_position or document_len < 0 do
          true ->
            IO.puts("The to delete line does not exist! ")
            IO.puts("Index position: #{index_position} ")
            IO.puts("Document length: #{document_len}")
            loop(peer)

          _ ->
            peer_id = get_peer_id(peer)

            git_index_translated =
              translate_git_index_to_syncordian_index(document, test_index, 0, 0)

            if git_index_translated == -1 do
              # Due byzantine peers or network issues the line was not inserted in the
              # document of the peer, need to requeue the local delete operation.
              # IO.puts("Line delete line was not found in the document with index: #{test_index}")
              get_peer_pid(peer) |> send({:delete_line, [index_position, test_index, 0, 0]})
              loop(peer)
            else
              peer =
                document
                |> update_document_line_status(git_index_translated, :tombstone)
                |> update_document_line_peer_id(git_index_translated, peer_id)
                |> update_peer_document(peer)
                |> tick_edit_count()

              peer = if peer_id == @peer_metadata_id, do:
                        save_peer_metadata_edit(peer),
                        else: peer

              line_deleted =
                get_document_line_by_index(document, git_index_translated)

              line_deleted_id = line_deleted |> get_line_id

              [left_parent, right_parent] =
                get_document_line_fathers(document, line_deleted)

              line_delete_signature = create_signature_delete(left_parent, right_parent)
              peer_vector_clock = get_peer_vector_clock(peer)

              send(
                get_peer_pid(peer),
                {:send_delete_broadcast,
                 {line_deleted_id, line_delete_signature, 0, peer_vector_clock}}
              )

              tick_peer_deleted_count(peer)
            end
        end

      # TODO: Delete the test_index, the global_position and current_delete_ops
      # ✅
      {:insert, [content, _index_position, test_index, _global_position, _current_delete_ops]} ->
        document = get_peer_document(peer)
        peer_id = get_peer_id(peer)

        git_index_translated = translate_git_index_to_syncordian_index(document, test_index, 0, 0)

        if git_index_translated == -1 do
          # Due byzantine peers or network issues the line was not inserted in the
          # document of the peer, need to requeue the local delete operation.
          IO.puts(
            "Un insert llego al peer #{peer_id} con el indice: #{test_index} pero el indice trad es #{git_index_translated}"
          )

          get_peer_pid(peer) |> send({:insert, [content, 0, test_index, 0, 0]})

          loop(peer)
        else
          [left_parent, right_parent] =
            get_parents_by_index(
              document,
              git_index_translated
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
            |> tick_edit_count()

          current_vector_clock = get_peer_vector_clock(peer)

          send(
            get_peer_pid(peer),
            {:send_insert_broadcast, {new_line, current_vector_clock}}
          )

          peer = if peer_id == @peer_metadata_id, do:
                    save_peer_metadata_edit(peer),
                    else: peer

          loop(peer)
        end

      # ✅
      {:send_insert_broadcast, {new_line, insertion_state_vector_clock}} ->
        perform_broadcast_peer(
          peer,
          {:receive_insert_broadcast, new_line, insertion_state_vector_clock}
        )

        loop(peer)

      # ✅
      {:send_delete_broadcast, delete_line_info} ->
        perform_broadcast_peer(peer, {:receive_delete_broadcast, delete_line_info})
        loop(peer)

      # ✅
      {:receive_delete_broadcast,
       {line_deleted_id, line_delete_signature, attempt_count, incoming_vc}} ->
        document = get_peer_document(peer)
        current_document_line = get_document_line_by_line_id(document, line_deleted_id)
        current_document_line? = current_document_line != nil

        [left_parent, right_parent] =
          get_document_line_fathers(document, current_document_line)

        valid_signature? =
          check_signature_delete(
            line_delete_signature,
            left_parent,
            right_parent
          )

        max_attempts_reach? = compare_max_insertion_attempts(attempt_count)

        requeue = fn x ->
          # IO.puts("requeue delete request")

          send(
            get_peer_pid(peer),
            {:receive_delete_broadcast,
             {line_deleted_id, line_delete_signature, attempt_count + x, incoming_vc}}
          )

          # send(peer_pid, {:delete_request_requeue})
          get_metadata(peer)
          |> inc_requeue_counter
          |> update_metadata(peer)
          |> loop
        end

        case {current_document_line?, valid_signature?, max_attempts_reach?} do
          {false, _, _} ->
            # IO.puts("The line to delete does not exist")
            requeue.(1)

          {_, true, false} ->
            # IO.puts("The delete signature is valid")
            # send(peer_pid, {:deleted_valid_line})

            get_metadata(peer)
            |> inc_delete_valid_counter
            |> update_metadata(peer)
            |> delete_valid_line_to_document_and_loop(document, line_deleted_id)

          {_, false, false} ->
            local_vector_clock = get_peer_vector_clock(peer)

            valid_line? =
              if String.length(line_delete_signature) == 10 do
                false
              else
                {v?, _} =
                  stash_document_lines_delete(
                    document,
                    line_deleted_id,
                    line_delete_signature,
                    local_vector_clock,
                    incoming_vc
                  )

                v?
              end

            case valid_line? do
              true ->
                # IO.puts("The delete signature is valid when stashed")
                # send(peer_pid, {:delete_stash_succeeded})

                u_peer = get_metadata(peer)
                |> inc_delete_stash_counter
                |> update_metadata(peer)

                u_peer
                |> get_metadata
                |> inc_delete_valid_counter
                |> update_metadata(u_peer)
                |> delete_valid_line_to_document_and_loop(document, line_deleted_id)

              false ->
                # IO.puts(
                #   "The delete signature is invalid when stashed in the peer #{get_peer_id(peer)} with attempt count: #{attempt_count} and line id: #{line_deleted_id}"
                # )

                requeue.(10)
            end

          {_, _, true} ->
            # send(peer_pid, {:delete_request_limit})

            get_metadata(peer)
            |> inc_delete_requeue_limit_counter
            |> update_metadata(peer)
            |> loop
        end

      # ✅
      {:receive_insert_broadcast, line, incoming_vc} ->
        incoming_peer_id = get_line_peer_id(line)
        local_vector_clock = get_peer_vector_clock(peer)

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

        insertion_attempts_reach? = check_insertions_attempts(line)

        case {clock_distance > 1, clock_distance == 1} do
          {true, _} ->
            # TODO: Refactor this code, doing the same as bellow. This was done because
            # the byzantine peers generating cpu overload. GO BACK HERE AND FIX THIS
            # AND CHECK IF THIS MAKES SENSE.
            if insertion_attempts_reach? do
              # send(peer_pid, {:insertion_request_requeue_limit})
              get_metadata(peer)
              |> inc_insert_request_limit_counter
              |> update_metadata(peer)
              |> loop
            else
              new_line = tick_line_insertion_attempts(line, 1)

              # send(peer_pid, {:insertion_clock_distance_greater_than_one})

              send(
                get_peer_pid(peer),
                {:receive_insert_broadcast, new_line, incoming_vc}
              )

              get_metadata(peer)
              |> inc_insert_distance_greater_than_one
              |> update_metadata(peer)
              |> loop
            end

          {_, true} ->
            order_vc =
              order_vector_clocks_definition(
                local_vector_clock,
                incoming_vc
              )

            document = get_peer_document(peer)
            line_index = get_document_new_index_by_incoming_line_id(line, document)
            [left_parent, right_parent] = get_parents_by_index(document, line_index)

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

                case {valid_line?, insertion_attempts_reach?} do
                  {true, false} ->
                    # send(peer_pid, {:insertion_valid_line})

                    get_metadata(peer)
                    |> inc_insert_valid_counter
                    |> update_metadata(peer)
                    |> add_valid_line_to_document_and_loop(line, incoming_peer_id)

                  {false, false} ->
                    # new_line = tick_line_insertion_attempts(line)

                    # IO.puts(
                    #   "The line signature is invalid #{get_line_insertion_attempts(new_line)}"
                    # )

                    # send(peer_pid, {:insertion_request_requeue})

                    get_metadata(peer)
                    |> inc_insert_request_counter
                    |> update_metadata(peer)
                    |> loop

                  # TODO: uncomment this code when the test is done
                  # send(get_peer_pid(peer), {:receive_insert_broadcast, new_line, incoming_vc})
                  # loop(peer)

                  {false, true} ->
                    # The line has reach the maximum number of attempts and it was not
                    # possible to check if the line is valid or not.
                    # send(peer_pid, {:insertion_request_requeue_limit})

                    get_metadata(peer)
                    |> inc_insert_request_limit_counter
                    |> update_metadata(peer)
                    |> loop
                end

              # local_vc > incoming_vc
              false ->
                {valid_line?, _} =
                  stash_document_lines_insert(
                    document,
                    line,
                    local_vector_clock,
                    incoming_vc
                  )

                case valid_line? do
                  true ->
                    # send(peer_pid, {:insertion_stash_succeeded})

                    get_metadata(peer)
                    |> inc_insert_stash_counter
                    |> update_metadata(peer)
                    |> add_valid_line_to_document_and_loop(line, incoming_peer_id)

                  false ->
                    # send(peer_pid, {:insertion_stash_fail})

                    get_metadata(peer)
                    |> inc_insert_stash_fail_counter
                    |> update_metadata(peer)
                    |> loop
                end
            end

          {_, _} ->
            IO.puts("Something happen")
            loop(peer)
        end

      # ✅ Not needed in Fugue
      {:receive_confirmation_line_insertion, {inserted_line_id, received_peer_id}} ->
        get_peer_document(peer)
        |> update_document_line_commit_at(inserted_line_id, received_peer_id)
        |> update_peer_document(peer)
        |> loop

      # ✅
      {:print_content, :document} ->
        print_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      # ✅
      {:save_content, :document} ->
        save_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      # ✅
      {:request_live_view_document, live_view_pid} ->
        handler_function = fn
          line ->
            Syncordian.Utilities.create_map_live_view_node_document(
              Syncordian.Line_Object.get_content(line),
              Syncordian.Line_Object.get_line_peer_id(line),
              Syncordian.Line_Object.get_line_id(line),
              Syncordian.Line_Object.get_line_status(line),
              Syncordian.Line_Object.get_signature(line),
              Syncordian.Line_Object.get_line_insertion_attempts(line),
              Syncordian.Line_Object.get_commit_at(line)
            )
        end

        send(
          live_view_pid,
          {:receive_live_view_document, get_peer_document(peer), handler_function}
        )

        loop(peer)

      # ✅
      {:save_pid, info} ->
        info
        |> update_peer_pid(peer)
        |> loop

      # ✅
      {:print, _} ->
        IO.inspect(peer)
        loop(peer)

      # ✅
      {:register_supervisor_pid} ->
        supervisor_pid = :global.whereis_name(:supervisor)

        set_peer_supervisor_pid(peer, supervisor_pid)
        |> loop

      # ✅
      {:supervisor_request_metadata} ->
        # THIS IS EXACTLY THE SAME AS IN FUGUE, function?
        peer_pid = get_peer_pid(peer)
        document_size = get_document_byte_size(peer)

        updated_memory_metadata =
          peer
          |> get_metadata()
          |> update_memory_info(peer_pid, document_size)

        send(
          get_peer_supervisor_pid(peer),
          {:receive_metadata_from_peer, updated_memory_metadata, peer_pid}
        )

        update_metadata(updated_memory_metadata, peer)
        |> loop()

      {:write_raw_document} ->
        document = get_peer_document(peer)
        document_str = inspect(document, limit: :infinity, printable_limit: :infinity)
          # |> Enum.map(fn line -> "#{inspect(line)}" end)
          # |> Enum.join("\n")

        file_path = "debug/documents/syncordian/raw/"
        File.write(file_path <> "document", document_str)
        loop(peer)

      test ->
        IO.puts("Wrong message")
        IO.inspect(test)
        loop(peer)
    end
  end
end
