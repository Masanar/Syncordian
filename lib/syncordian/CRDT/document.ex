defmodule Syncordian.Document do
  # use TypeCheck
  import Syncordian.Line_Object
  import Syncordian.Line
  import Syncordian.Vector_Clock
  import Syncordian.Byzantine
  import Syncordian.Utilities
  import Syncordian.Basic_Types

  @doc """
    This is a function used to get the index (position in the document i.e. list)
    of new line by its line_id. It calls an auxiliary function to do the job, passing the
    line_id, the document as arguments ant the initial index 0.

    It is different from the get_document_index_by_line_id/2 because it is used to get in
    the process of inserting a new line broadcasted in the document, so it is important to
    get the index by comparing the line_id with the line_id of the lines in the document.
    And giving the 'middle' index to insert the new line. In the current local peer
    incoming the new insert.
  """
  @spec get_document_new_index_by_incoming_line_id(
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.document()
        ) ::
          integer
  def get_document_new_index_by_incoming_line_id(line, document) do
    line_id = get_line_id(line)
    get_document_new_index_by_incoming_line_id_aux(line_id, document, 0)
  end

  # This is an private recursive auxiliar function over the length of the document to get
  # the index of the line by its line_id.
  # NOTE: It is important to keep the precondition of not having any line ID greater than
  # the @max_float defined at Syncordian.Line module! or else this function will get to an
  # empty document and will return an error. I define a case for this situation, but it is
  # better just to ensure that the line_id is always less than the @max_float.
  @spec get_document_new_index_by_incoming_line_id_aux(
          Syncordian.Basic_Types.line_id(),
          Syncordian.Basic_Types.document(),
          integer()
        ) :: integer

  defp get_document_new_index_by_incoming_line_id_aux(_, [], _) do
    IO.puts("There is an error with the line id it is greater than the maximum float")
    1
  end

  defp get_document_new_index_by_incoming_line_id_aux(line_id, [head | tail], index) do
    head_line_id = get_line_id(head)

    case line_id < head_line_id do
      true -> index
      _ -> get_document_new_index_by_incoming_line_id_aux(line_id, tail, index + 1)
    end
  end

  @doc """
    Given the document and the line_id this function return the index of the corresponding
    line in the document.
  """
  @spec get_document_index_by_line_id(
          document :: Syncordian.Basic_Types.document(),
          line_id :: Syncordian.Basic_Types.line_id()
        ) :: integer()
  def get_document_index_by_line_id(document, line_id) do
    Enum.find_index(document, fn line -> get_line_id(line) == line_id end) || 1
  end

  @doc """
    Given the document and the line_id, this function search through the document to find
    the line with the given line_id. If not found returns nil.
  """
  @spec get_document_line_by_line_id(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.line_id()
        ) ::
          Syncordian.Line_Object.line()
  def get_document_line_by_line_id(document, line_id) do
    # TODO: check if this functions takes into account that the first and last elements of
    # the document are the infimum and supremum lines.
    Enum.find(document, fn line -> get_line_id(line) == line_id end)
  end

  @doc """
    Given a line of the document, this function returns both parents of the line.
  """
  @spec get_document_line_fathers(
          Syncordian.Basic_Types.document(),
          Syncordian.Line_Object.line()
        ) ::
          {Syncordian.Line_Object.line(), Syncordian.Line_Object.line()}
  def get_document_line_fathers(document, line) do
    index = get_document_index_by_line_id(document, get_line_id(line))
    left_parent = get_document_line_by_index(document, index - 1)
    right_parent = get_document_line_by_index(document, index + 1)
    [left_parent, right_parent]
  end

  @doc """
    This function returns the specific line at the given index in the document
  """
  @spec get_document_line_by_index(Syncordian.Basic_Types.document(), integer()) ::
          Syncordian.Line_Object.line()
  def get_document_line_by_index(document, index), do: Enum.at(document, index)

  @doc """
    Given a document and a index, this function change the status of the line at the given
    index, returning the updated document.
  """
  @spec update_document_line_status(
          Syncordian.Basic_Types.document(),
          integer(),
          Syncordian.Basic_Types.status()
        ) ::
          Syncordian.Basic_Types.document()
  def update_document_line_status(document, index, new_value) do
    line = get_document_line_by_index(document, index)
    updated_line = set_line_status(line, new_value)
    Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  end

  @doc """
    This function returns the length of the document
  """
  @spec get_document_length(Syncordian.Basic_Types.document()) :: integer
  def get_document_length(document), do: length(document)

  @doc """
      This function insert a line into the document in the right position
  """
  @spec add_line_to_document(Syncordian.Line_Object.line(), Syncordian.Basic_Types.document()) ::
          Syncordian.Basic_Types.document()
  def add_line_to_document(line, document = [head | tail]) do
    case compare_lines(line, head) do
      1 ->
        [head | add_line_to_document(line, tail)]

      0 ->
        IO.inspect("Line Error")
        document

      -1 ->
        [line | document]
    end
  end

  @doc """
    Given a document, a line_id of the document, and a peer_id, this function updates the
    commit_at field of the line in the projection of the corresponding peer_id, returning
    the updated document.
  """
  @spec update_document_line_commit_at(
          document :: Syncordian.Basic_Types.document(),
          line_id :: Syncordian.Basic_Types.line_id(),
          received_peer_id :: Syncordian.Basic_Types.peer_id()
        ) ::
          Syncordian.Basic_Types.document()
  def update_document_line_commit_at(document, line_id, received_peer_id) do
    get_document_line_by_line_id(document, line_id)
    |> update_line_commit_at(received_peer_id)
    |> update_document_line_by_line(document)
  end

  @spec update_document_line_by_line(
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.document()
        ) ::
          Syncordian.Basic_Types.document()
  def update_document_line_by_line(updated_line, document) do
    line_id = get_line_id(updated_line)
    index = get_document_index_by_line_id(document, line_id)
    Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  end

  @doc """
    Given a document and a index, this function change the status of the line at the given
    index, returning the updated document.
  """
  @spec update_document_line_peer_id(
          Syncordian.Basic_Types.document(),
          integer(),
          Syncordian.Basic_Types.peer_id()
        ) ::
          Syncordian.Basic_Types.document()
  def update_document_line_peer_id(document, index, new_peer_id) do
    line = get_document_line_by_index(document, index)
    updated_line = set_line_peer_id(line, new_peer_id)
    Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  end

  @spec stash_document_lines(
          document :: Syncordian.Basic_Types.document(),
          incoming_line :: Syncordian.Line_Object.line(),
          local_peer_vc :: Syncordian.Basic_Types.vector_clock(),
          incoming_peer_vc :: Syncordian.Basic_Types.vector_clock()
        ) :: {boolean(), {integer(), integer()}}
  def stash_document_lines(document, incoming_line, local_peer_vc, incoming_peer_vc) do
    # TODO: There are things here that are borrables(translate this word)
    # HERE
    # Les't try this:
    # 1. Calculate the number of lines to stash by comparing the incoming_peer_vc with the
    #    local_peer_vc in the projection of the incoming_peer_id in the local_peer_vc.
    # 2. Base on the aforementioned number, stash the lines in the document in a stack.
    #    using a sliding window process that alway contains the incoming_line_id.
    # 3. For each slide, check if the incoming_line is checkable, if so, the incoming_line
    #    is a valid line and continue the insert process. Else continue the stash process.
    #    if the incoming_line is never checkable, then the incoming_line is a invalid line

    window_size = projection_distance(local_peer_vc, incoming_peer_vc)
    document_length = get_document_length(document) + 1
    # HERE this was afected due to the changes marks as HERE
    window_center = get_document_new_index_by_incoming_line_id(incoming_line, document)
    new_document = add_element_list_in_given_index(document, window_center - 1, incoming_line)

    window_stash_check_signature(
      {document_length, window_size, window_center, new_document, incoming_line},
      -1,
      1
    )
  end

  # This function checks if the incoming line is checkable in the window of the document
  # defined by the window_center, window_size, and the document_length. It need to check
  # any window size until the window_size attribute in the available parte of the document,
  # based on the document_length, window_size and window center. If the incoming line
  # is checkable, it returns true, otherwise, it returns false.
  @spec window_stash_check_signature(
          fix_parameter :: {
            integer(),
            integer(),
            integer(),
            Syncordian.Basic_Types.document(),
            Syncordian.Line_Object.line()
          },
          left_shift :: integer(),
          right_shift :: integer()
        ) :: {boolean(), {integer(), integer()}}

  defp window_stash_check_signature(
         fix_parameter = {document_length, window_size, window_center, document, incoming_line},
         left_shift,
         right_shift
       ) do
    left_parent = get_document_line_by_index(document, window_center + left_shift)
    right_parent = get_document_line_by_index(document, window_center + right_shift)

    not_found_value = {false, {0, 0}}

    case check_signature_insert(left_parent, incoming_line, right_parent) do
      true ->
        {true, {left_shift + window_center, right_shift + window_center}}

      false ->
        new_left_shift = left_shift - 1
        new_right_shift = right_shift + 1

        result_left =
          if window_center + new_left_shift >= 0 and
               new_left_shift * -1 + right_shift <= window_size + 2 do
            window_stash_check_signature(fix_parameter, new_left_shift, right_shift)
          else
            not_found_value
          end

        result_right =
          if window_center + new_right_shift < document_length and
               left_shift * -1 + new_right_shift <= window_size + 2 and !elem(result_left, 0) do
            window_stash_check_signature(fix_parameter, left_shift, new_right_shift)
          else
            not_found_value
          end

        case {elem(result_left, 0), elem(result_right, 0)} do
          {false, false} ->
            not_found_value

          {true, false} ->
            result_left

          {false, true} ->
            result_right

          # This match may never happen, if so, it is a bug in the code
          # {true, true} -> ...
          _ ->
            IO.inspect("Error in the window_stash_check_signature")
            result_right
        end
    end
  end

  # Given a document and a position index, this function returns the previous and next
  # parents of the given index. The line_pos_index_status is the status of the line in the
  # original index i.e. the index with out the shift due to the previous tombstones.
  @spec get_parents_by_index(
          document :: Syncordian.Basic_Types.document(),
          index :: Syncordian.Basic_Types.git_document_index()
        ) ::
          [Syncordian.Line_Object.line()]
  def get_parents_by_index(document, 0),
    do: [get_document_line_by_index(document, 0), get_document_line_by_index(document, 1)]

  def get_parents_by_index(document, pos_index) do
    len = get_document_length(document)
    distance = len - pos_index

    case {distance > 0, distance} do
      {true, 1} ->
        # Case where the insert is at the end of the document after a tombstone that
        # was made in the same edit see commit: 2198ff05e3b26532865f91a9ac1bac5fc673c05b
        # [Enum.at(document, len - 2), Enum.at(document, len - 1)]
        [
          get_document_line_by_index(document, len - 2),
          get_document_line_by_index(document, len - 1)
        ]

      {true, 2} ->
        # Case where the insert behaves like an 'append' i.e. insert at the end
        # see any insert of the first commit: 26a07b0ad87162805e69ce18c56627772a663aef
        # [Enum.at(document, pos_index), Enum.at(document, pos_index + 1)]
        [
          get_document_line_by_index(document, pos_index),
          get_document_line_by_index(document, pos_index + 1)
        ]

      {true, _} ->
        # Case where the insert is within any line inside the document
        # [Enum.at(document, pos_index - 1), Enum.at(document, pos_index)]
        [
          get_document_line_by_index(document, pos_index - 1),
          get_document_line_by_index(document, pos_index)
        ]

      {_, _} ->
        # This return is just to make the compiler (completeness) happy, if this ever
        # happens the code has a huge error.
        IO.puts("Error in the get_parents_by_index")
        IO.inspect("Distance: #{distance}, pos_index: #{pos_index}, len: #{len}")
        # [Enum.at(document, len - 2), Enum.at(document, len - 1)]
        [
          get_document_line_by_index(document, len - 2),
          get_document_line_by_index(document, len - 1)
        ]
    end
  end

  # The -1 is because the last line is the supremum
  def translate_git_index_to_syncordian_index([], 0, 0, index), do: index - 1

  def translate_git_index_to_syncordian_index([h | t], 0, 0, index) do
    line_status = get_line_status(h)

    case line_status do
      :tombstone -> translate_git_index_to_syncordian_index(t, 0, 0, index + 1)
      _ -> index
    end
  end

  def translate_git_index_to_syncordian_index([h | t], 0, tombstones, index),
    do: translate_git_index_to_syncordian_index([h | t], tombstones, 0, index)

  def translate_git_index_to_syncordian_index([h | t], target, tombstones, index) do
    line_status = get_line_status(h)

    case line_status do
      :tombstone ->
        translate_git_index_to_syncordian_index(t, target - 1, tombstones + 1, index + 1)

      _ ->
        translate_git_index_to_syncordian_index(t, target - 1, tombstones, index + 1)
    end
  end
end
