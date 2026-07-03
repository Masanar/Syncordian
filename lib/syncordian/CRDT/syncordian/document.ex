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
    Syncordian.Utilities.debug_print(
      "get_document_new_index_by_incoming_line_id_aux",
      "incoming line_id sorted past the document supremum"
    )

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
    line in the document, or nil when no line carries that id. Callers must handle nil —
    silently falling back to an arbitrary index would let a bad id target the wrong line.
  """
  @spec get_document_index_by_line_id(
          document :: Syncordian.Basic_Types.document(),
          line_id :: Syncordian.Basic_Types.line_id()
        ) :: integer() | nil
  def get_document_index_by_line_id(document, line_id) do
    Enum.find_index(document, fn line -> get_line_id(line) == line_id end)
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
    # The walk includes the infimum/supremum sentinels; their sentinel PathIds never
    # equal a real line_id, so they can only be found when explicitly asked for.
    Enum.find(document, fn line -> get_line_id(line) == line_id end)
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

  @doc """
    This function returns the length of the document
  """
  @spec get_document_length(Syncordian.Basic_Types.document()) :: integer
  def get_document_length(document), do: length(document)

  @doc """
    Inserts a line into the document at its ⋖-position (PathId order, identity tiebreak —
    `Syncordian.Line.compare_lines/2`). Returns `{:ok, document}` on success, or
    `:duplicate` when the *same* line (same authored identity) is already present — the
    signature of a redelivered/replayed insert that survived past the bounded seen-set.
    Callers must treat `:duplicate` as a no-op and skip every apply side effect (ack
    broadcast, clock tick, seen-set record); see the receipt rule of the formal model.
  """
  @spec add_line_to_document(Syncordian.Line_Object.line(), Syncordian.Basic_Types.document()) ::
          {:ok, Syncordian.Basic_Types.document()} | :duplicate
  def add_line_to_document(line, [head | tail]) do
    case compare_lines(line, head) do
      1 ->
        case add_line_to_document(line, tail) do
          {:ok, new_tail} -> {:ok, [head | new_tail]}
          :duplicate -> :duplicate
        end

      0 ->
        :duplicate

      -1 ->
        {:ok, [line, head | tail]}
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
  # defined by the window_center, window_size, and the document_length. If the incoming
  # line is checkable — i.e. some candidate parent pair verifies the insert wire tag — it
  # returns true together with the (document-index) positions of the accepted parents;
  # otherwise false.
  #
  # The candidate (left, right) pairs are enumerated FLAT, nearest pairs first, so each of
  # the O(window²) distinct pairs is hashed exactly once. The previous implementation
  # explored the same pairs by branching recursion (expand-left OR expand-right at every
  # failure), recomputing overlapping subproblems Θ(2^window) times: once replicas drifted
  # enough for windows to widen, whole peers sank into billions of SHA checks per message
  # and the network CPU-melted. By the unique-verifier property of the wire tag at most
  # one pair can match, so enumeration order cannot change the result.
  #
  # Deletes no longer use this search: their authorization tag binds the target line's
  # stored signature directly (an intrinsic check), so locating shifted neighbors is
  # unnecessary for them.
  @spec window_stash_check_signature({
          integer(),
          integer(),
          integer(),
          Syncordian.Basic_Types.document(),
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.signature()
        }) :: {boolean(), {integer(), integer()}}
  defp window_stash_check_signature(
         {document_length, window_size, window_center, document, incoming_line, insert_tag}
       ) do
    max_spread = window_size + 2

    candidate_pairs =
      for spread <- 2..max_spread,
          left_shift <- 1..(spread - 1),
          right_shift = spread - left_shift,
          window_center - left_shift >= 0,
          window_center + right_shift < document_length do
        {window_center - left_shift, window_center + right_shift}
      end

    Enum.find_value(candidate_pairs, {false, {0, 0}}, fn {left_index, right_index} ->
      left_parent = get_document_line_by_index(document, left_index)
      right_parent = get_document_line_by_index(document, right_index)

      if right_parent != nil and
           check_tag_insert(left_parent, incoming_line, right_parent, insert_tag),
         do: {true, {left_index, right_index}},
         else: nil
    end)
  end

  @doc """
    Parent pair of an incoming broadcast line located by its splice index — the index of
    the line's right neighbor, as returned by `get_document_new_index_by_incoming_line_id/2`.
    The parents of a splice at index `i` are always `{document[i-1], document[i]}`: the
    infimum sentinel guarantees `i >= 1` and the supremum guarantees `i <= len - 1`, so
    both lookups are total.

    This is deliberately distinct from `get_parents_by_index/2`, whose index is a
    *translated git index* (same parent shape today, but subject to the git-replay index
    conventions documented there); keeping the two entry points separate keeps the splice
    path independent of any replay-side index accounting.
  """
  @spec get_splice_parents(
          document :: Syncordian.Basic_Types.document(),
          splice_index :: integer()
        ) :: [Syncordian.Line_Object.line()]
  def get_splice_parents(document, splice_index) when splice_index >= 1 do
    [
      get_document_line_by_index(document, splice_index - 1),
      get_document_line_by_index(document, splice_index)
    ]
  end

  # Given a document and a position index, this function returns the previous and next
  # parents of the given index.
  #
  # NOTE: the index here is a *translated git index* (see attempt_local_edit in
  # Syncordian.Peer) with uniform before-semantics: the new line always lands BETWEEN
  # document[pos_index - 1] and document[pos_index], i.e. immediately before the line the
  # translation resolved to (translate resolves an append past the last live line to the
  # supremum, so the end-of-document case needs no special branch). Zero-old-count hunks
  # (`@@ -0,0`, file creation) carry after-semantics in raw git indices; the supervisor
  # shifts those by +1 at dispatch so this uniform rule holds. For the splice index of an
  # incoming broadcast line use get_splice_parents/2 instead.
  @spec get_parents_by_index(
          document :: Syncordian.Basic_Types.document(),
          index :: Syncordian.Basic_Types.git_document_index()
        ) ::
          [Syncordian.Line_Object.line()]
  def get_parents_by_index(document, 0),
    do: [get_document_line_by_index(document, 0), get_document_line_by_index(document, 1)]

  def get_parents_by_index(document, pos_index) do
    len = get_document_length(document)

    if pos_index < len do
      [
        get_document_line_by_index(document, pos_index - 1),
        get_document_line_by_index(document, pos_index)
      ]
    else
      # This return is just to make the compiler (completeness) happy, if this ever
      # happens the code has a huge error.
      IO.puts("Error in the get_parents_by_index")
      IO.puts("pos_index: #{pos_index}, len: #{len}")

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
