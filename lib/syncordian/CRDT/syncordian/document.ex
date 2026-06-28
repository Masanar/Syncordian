defmodule Syncordian.Document do
  @moduledoc """
  Operations over a Syncordian document — the ordered list of lines a peer holds.

  A document is a `[Syncordian.Line_Object.line()]` kept sorted by each line's
  totally-ordered `Syncordian.PathId`, bracketed by an Infimum sentinel at the
  head and a Supremum sentinel at the tail so that every real insert has a
  left and right neighbour. This module provides the read/locate side of that
  structure: finding the index at which an incoming broadcast line should be
  spliced (`get_document_new_index_by_incoming_line_id/2`), locating existing
  lines by id, and the related traversal helpers; the sentinels guarantee the
  walks terminate.

  It composes the lower-level pieces — `Syncordian.Line` / `Syncordian.Line_Object`
  for line construction and access, `Syncordian.PathId` for position comparison,
  `Syncordian.Vector_Clock` for causality, and `Syncordian.Byzantine` for
  signatures. `Syncordian.Peer` calls into it while applying local edits and
  incoming operations.
  """
  # use TypeCheck
  import Syncordian.Line_Object
  import Syncordian.Line
  import Syncordian.Vector_Clock
  import Syncordian.Byzantine
  import Syncordian.Utilities
  import Syncordian.Basic_Types
  alias Syncordian.PathId

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

  # Private recursive helper that walks the document and returns the first index where
  # the head line's PathId is strictly greater than the incoming line_id. The supremum
  # sentinel at the document tail guarantees the walk terminates before running off the
  # end; the empty-document clause is therefore a defensive fallback.
  @spec get_document_new_index_by_incoming_line_id_aux(
          Syncordian.Basic_Types.line_id(),
          Syncordian.Basic_Types.document(),
          integer()
        ) :: integer

  defp get_document_new_index_by_incoming_line_id_aux(_, [], _) do
    IO.puts("There is an error: incoming line_id sorted past the document supremum")
    1
  end

  defp get_document_new_index_by_incoming_line_id_aux(line_id, [head | tail], index) do
    head_line_id = get_line_id(head)

    case PathId.less?(line_id, head_line_id) do
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
          [Syncordian.Line_Object.line()]
  def get_document_line_fathers(_, nil), do: [nil, nil]

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
  @spec update_document_line_status(
          Syncordian.Basic_Types.document(),
          integer(),
          any()
        ) :: Syncordian.Basic_Types.document()
  def update_document_line_status([head | tail], index, new_value) do
    update_document_line_status_rec([head | tail], index, new_value, 0)
  end

  defp update_document_line_status_rec([head | tail], index, new_value, current_index) do
    if current_index == index do
      updated_line = set_line_status(head, new_value)
      [updated_line | tail]
    else
      [head | update_document_line_status_rec(tail, index, new_value, current_index + 1)]
    end
  end

  # def update_document_line_status(document, index, new_value) do
  #   line = get_document_line_by_index(document, index)
  #   updated_line = set_line_status(line, new_value)
  #   Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  # end

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
        IO.puts("Line Error")
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

  @doc """
    After an acknowledgement is recorded, settle the given line iff every trusted peer has
    now acknowledged it: when its `commit_at` is all-true and it is still `:aura`, join in
    `:settled` (the acknowledgement case of `def:apply` in the formal model). This is
    lattice-correct — only `:aura` lines are promoted, so a `:tombstone` is never demoted
    (`:tombstone ⊔ :settled = :tombstone`). Returns `{document, settled?}`, the boolean
    reporting whether a promotion happened (used for the `settle_counter` metadata).
  """
  @spec settle_line_if_complete(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.line_id()
        ) :: {Syncordian.Basic_Types.document(), boolean()}
  def settle_line_if_complete(document, line_id) do
    line = get_document_line_by_line_id(document, line_id)

    if line != nil and get_line_status(line) == :aura and Enum.all?(get_commit_at(line)) do
      settled_line = set_line_status(line, :settled)
      {update_document_line_by_line(settled_line, document), true}
    else
      {document, false}
    end
  end

  @spec update_document_line_by_line(
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.document()
        ) ::
          Syncordian.Basic_Types.document()
  def update_document_line_by_line(updated_line, [head | tail]) do
    line_id = get_line_id(updated_line)
    update_document_line_by_line_rec(updated_line, line_id, [head | tail], 0)
  end

  defp update_document_line_by_line_rec(updated_line, line_id, [head | tail], index) do
    if get_line_id(head) == line_id do
      [updated_line | tail]
    else
      [head | update_document_line_by_line_rec(updated_line, line_id, tail, index + 1)]
    end
  end

  # def update_document_line_by_line(updated_line, document) do
  #   line_id = get_line_id(updated_line)
  #   index = get_document_index_by_line_id(document, line_id)
  #   Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  # end

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
  def update_document_line_peer_id([head | tail], 0, new_peer_id) do
    updated_line = set_line_peer_id(head, new_peer_id)
    [updated_line | tail]
  end

  def update_document_line_peer_id([head | tail], index, new_peer_id) when index > 0 do
    [head | update_document_line_peer_id(tail, index - 1, new_peer_id)]
  end

  # def update_document_line_peer_id(document, index, new_peer_id) do
  #   line = get_document_line_by_index(document, index)
  #   updated_line = set_line_peer_id(line, new_peer_id)
  #   Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  # end

  @doc """
    Windowed parent search for an out-of-order (stashed) insert. The receiver knows the
    incoming line's position but its neighbors may have shifted under concurrent edits;
    this function slides a bounded window — sized by the progress-vector projection
    distance — around the insertion point, looking for the candidate parent pair whose
    stored signatures verify the insert wire tag `t_ins`.

    Up to a hash collision exactly one parent pair verifies (the authored one), so every
    replica that accepts the tag — directly or at any window offset — accepts the same
    parents. On success the accepted pair is returned so the caller can seal the line's
    stored signature from it; on failure `{false, {nil, nil}}`.
  """
  @spec stash_document_lines_insert(
          document :: Syncordian.Basic_Types.document(),
          incoming_line :: Syncordian.Line_Object.line(),
          local_peer_vc :: Syncordian.Basic_Types.vector_clock(),
          incoming_peer_vc :: Syncordian.Basic_Types.vector_clock(),
          insert_tag :: Syncordian.Basic_Types.signature()
        ) ::
          {boolean(), {Syncordian.Line_Object.line() | nil, Syncordian.Line_Object.line() | nil}}
  def stash_document_lines_insert(
        document,
        incoming_line,
        local_peer_vc,
        incoming_peer_vc,
        insert_tag
      ) do
    window_size = projection_distance(local_peer_vc, incoming_peer_vc)
    document_length = get_document_length(document) + 1
    window_center = get_document_new_index_by_incoming_line_id(incoming_line, document)

    new_document =
      add_element_list_in_given_index(document, window_center - 1, incoming_line)

    window_search_result =
      window_stash_check_signature(
        {document_length, window_size, window_center, new_document, incoming_line, insert_tag}
      )

    case window_search_result do
      {true, {left_parent_index, right_parent_index}} ->
        {true,
         {get_document_line_by_index(new_document, left_parent_index),
          get_document_line_by_index(new_document, right_parent_index)}}

      {false, _} ->
        {false, {nil, nil}}
    end
  end

  # This function checks if the incoming line is checkable in the window of the document
  # defined by the window_center, window_size, and the document_length. It needs to check
  # any window size until the window_size attribute in the available part of the document,
  # based on the document_length, window_size and window center. If the incoming line is
  # checkable — i.e. some candidate parent pair verifies the insert wire tag — it returns
  # true together with the (document-index) positions of the accepted parents; otherwise
  # false.
  #
  # Deletes no longer use this search: their authorization tag binds the target line's
  # stored signature directly (an intrinsic check), so locating shifted neighbors is
  # unnecessary for them.
  @spec window_stash_check_signature(
          fix_parameter :: {
            integer(),
            integer(),
            integer(),
            Syncordian.Basic_Types.document(),
            Syncordian.Line_Object.line(),
            Syncordian.Basic_Types.signature()
          },
          left_shift :: integer(),
          right_shift :: integer()
        ) :: {boolean(), {integer(), integer()}}
  defp window_stash_check_signature(
         fix_parameter =
           {document_length, window_size, window_center, document, incoming_line, insert_tag},
         left_shift \\ -1,
         right_shift \\ 1
       ) do
    left_parent = get_document_line_by_index(document, window_center + left_shift)
    right_parent = get_document_line_by_index(document, window_center + right_shift)

    not_found_value = {false, {0, 0}}

    check_value = check_tag_insert(left_parent, incoming_line, right_parent, insert_tag)

    if right_parent != nil do
      if check_value do
        {true, {left_shift + window_center, right_shift + window_center}}
      else
        new_left_shift = left_shift - 1
        new_right_shift = right_shift + 1

        within_left_bounds? =
          window_center + new_left_shift >= 0 and
            new_left_shift * -1 + right_shift <= window_size + 2

        within_right_bounds? =
          window_center + new_right_shift < document_length and
            left_shift * -1 + new_right_shift <= window_size + 2

        # Only compute left and right if within bounds
        result_left =
          if within_left_bounds?,
            do: window_stash_check_signature(fix_parameter, new_left_shift, right_shift),
            else: not_found_value

        result_right =
          if within_right_bounds? and not elem(result_left, 0),
            do: window_stash_check_signature(fix_parameter, left_shift, new_right_shift),
            else: not_found_value

        case {elem(result_left, 0), elem(result_right, 0)} do
          {false, false} ->
            not_found_value

          {true, false} ->
            result_left

          {false, true} ->
            result_right

          _ ->
            IO.puts("Error in window_stash_check_signature")
            result_right
        end
      end
    else
      not_found_value
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
        IO.puts("Distance: #{distance}, pos_index: #{pos_index}, len: #{len}")
        # [Enum.at(document, len - 2), Enum.at(document, len - 1)]
        [
          get_document_line_by_index(document, len - 2),
          get_document_line_by_index(document, len - 1)
        ]
    end
  end

  @doc """
  Translates a Git index into the corresponding Syncordian document index,
  accounting for tombstone (i.e. logically deleted) lines.

  Parameters:
    - document: A list representing the document lines.
    - target: The number of non-tombstone lines to skip (the Git index position).
    - tombstones: The count of tombstones encountered so far (used for adjustment).
    - index: The current traversal index.

  Returns:
    The corresponding Syncordian document index, or -1 if the traversal does not find a valid position.
    The -1 is because the last line is the supremum.
  """
  # The -1 is because the last line is the supremum
  def translate_git_index_to_syncordian_index([], 0, 0, index), do: index - 1

  def translate_git_index_to_syncordian_index([], _, _, _), do: -1

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
