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
  import Syncordian.Byzantine
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
    Single-traversal acknowledgement application, semantically identical to
    `get_document_line_by_line_id/2` + `verify` + `update_document_line_commit_at/3` +
    `settle_line_if_complete/2` but walking the document exactly once — the ack path is
    the hottest in the system (every peer processes every other peer's ack for every
    line, so repeated full scans dominate large replays).

    `verify` receives the found line and must return whether the acknowledgement is
    genuine for it (the response-tag check). Returns `:absent` when no line has
    `line_id` (caller suspends), `:rejected` when `verify` fails (defense in depth
    behind admission), or `{:ok, document, settled?}` with the acking peer unioned into
    the line's checklist and the line settled iff the checklist became all-true while
    still `:aura` — the same lattice rule as `settle_line_if_complete/2`.
  """
  @spec apply_ack_to_document(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.line_id(),
          Syncordian.Basic_Types.peer_id(),
          (Syncordian.Line_Object.line() -> boolean())
        ) :: {:ok, Syncordian.Basic_Types.document(), boolean()} | :absent | :rejected
  def apply_ack_to_document([], _line_id, _acker_peer_id, _verify), do: :absent

  def apply_ack_to_document([head | tail], line_id, acker_peer_id, verify) do
    if get_line_id(head) == line_id do
      cond do
        not verify.(head) ->
          :rejected

        true ->
          line = update_line_commit_at(head, acker_peer_id)

          if get_line_status(line) == :aura and Enum.all?(get_commit_at(line)) do
            {:ok, [set_line_status(line, :settled) | tail], true}
          else
            {:ok, [line | tail], false}
          end
      end
    else
      case apply_ack_to_document(tail, line_id, acker_peer_id, verify) do
        {:ok, new_tail, settled?} -> {:ok, [head | new_tail], settled?}
        other -> other
      end
    end
  end

  @doc """
    Batched variant of `apply_ack_to_document/4`: applies a whole burst of admitted
    acknowledgements in ONE document traversal. `acks_by_line` maps a target line id to
    its acknowledgement entries `{{line_id, acker_peer_id, ack_tag}, alpha}` in arrival
    order (the full admitted wire messages, so absent ones can be re-suspended
    verbatim).

    Per line the rule is identical to the single-acknowledgement path: each entry's
    response tag is verified against the found line's stored signature and claimed
    acker (`Syncordian.Byzantine.check_tag_ack/3`); genuine ackers are unioned into the
    line's checklist; the line settles iff the checklist became all-true while still
    `:aura` (`:tombstone` is never demoted). Union is idempotent and commutative, so
    applying a burst together yields the same document as applying its members one by
    one in any order.

    Returns `{document, %{applied: n, rejected: n, settled: n, absent: remaining}}`
    where `absent` holds the entries whose target line is not present yet, keyed by
    line id — the caller suspends each on `{:line, id}` exactly as the single path
    does.
  """
  @spec apply_acks_to_document(
          Syncordian.Basic_Types.document(),
          %{optional(Syncordian.Basic_Types.line_id()) => list()}
        ) ::
          {Syncordian.Basic_Types.document(),
           %{
             applied: non_neg_integer(),
             rejected: non_neg_integer(),
             settled: non_neg_integer(),
             absent: map()
           }}
  def apply_acks_to_document(document, acks_by_line) when map_size(acks_by_line) == 0,
    do: {document, %{applied: 0, rejected: 0, settled: 0, absent: %{}}}

  def apply_acks_to_document(document, acks_by_line) do
    do_apply_acks(document, acks_by_line, %{applied: 0, rejected: 0, settled: 0})
  end

  # Walks the document until every targeted line has been visited, then keeps the
  # untouched tail by reference — matching the early exit of the single-ack path
  # (small batches would otherwise pay a full-document walk for a line near the head).
  defp do_apply_acks(tail, remaining, stats) when map_size(remaining) == 0,
    do: {tail, Map.put(stats, :absent, %{})}

  defp do_apply_acks([], remaining, stats), do: {[], Map.put(stats, :absent, remaining)}

  defp do_apply_acks([line | tail], remaining, stats) do
    case Map.pop(remaining, get_line_id(line)) do
      {nil, _} ->
        {new_tail, result} = do_apply_acks(tail, remaining, stats)
        {[line | new_tail], result}

      {entries, remaining} ->
        {line, stats} = apply_line_acks(line, entries, stats)
        {new_tail, result} = do_apply_acks(tail, remaining, stats)
        {[line | new_tail], result}
    end
  end

  # Applies one line's acknowledgement entries: verify each tag against the line's
  # stored signature, union the genuine ackers, then apply the settle lattice rule
  # once (equivalent to checking after every union — the checklist only grows).
  defp apply_line_acks(line, entries, stats) do
    {line, applied, rejected} =
      Enum.reduce(entries, {line, 0, 0}, fn
        {{_line_id, acker_peer_id, ack_tag}, _alpha}, {line_acc, applied, rejected} ->
          if check_tag_ack(ack_tag, get_signature(line_acc), acker_peer_id) do
            {update_line_commit_at(line_acc, acker_peer_id), applied + 1, rejected}
          else
            {line_acc, applied, rejected + 1}
          end
      end)

    {line, settled} =
      if get_line_status(line) == :aura and Enum.all?(get_commit_at(line)) do
        {set_line_status(line, :settled), 1}
      else
        {line, 0}
      end

    {line,
     %{
       stats
       | applied: stats.applied + applied,
         rejected: stats.rejected + rejected,
         settled: stats.settled + settled
     }}
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
