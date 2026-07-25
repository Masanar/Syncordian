defmodule Syncordian.Interleaving do
  @moduledoc """
  Pure detection of interleaving anomalies between concurrently authored edit blocks,
  and the re-placement decision that resolves them.

  This module is the operational realisation of the intention-preservation argument in
  the formal model (`sec:formal-intention`): it reconstructs authored blocks
  (`def:editblock`), recognises when two blocks of distinct writers have been allocated
  into the *same parent interval* with overlapping positions (the conflict that breaks
  interleaving-freedom, `def:intention`), and names the fresh, disjoint sub-interval into
  which the lower-priority block must be re-issued.

  It is deliberately **pure and side-effect free**: every replica computes the same blocks
  and the same re-placement decisions from the same converged document (positions, statuses
  and the immutable authored identities `op_id` / `parent_left_op_id` / `parent_right_op_id`
  are all replica-independent by `theo:convergence`). The peer loop
  (`Syncordian.Peer`) is what acts on the decision, and only the *writer* of the
  lower-priority block re-issues — see `theo:nonint`.

  ## Authored blocks (`def:editblock`)

  An authored block of writer `w` is a maximal chain of inserts by `w` with a common
  authored right parent, where each line names the previous line of the chain as its
  authored left parent. We reconstruct it from the line records: line `s` is the successor
  of line `c` iff `s` and `c` share a writer and a `parent_right_op_id`, and
  `s.parent_left_op_id == c.op_id`. A line is a *block head* iff its authored left parent is
  not a present line of the same writer and right anchor (so its left parent is a boundary,
  another writer's line, or an anchor outside the block).

  ## Conflict and re-placement (`def:intention`, `theo:nonint`)

  Two blocks *conflict* iff they have distinct writers, the **same** authored parent
  interval `(left_anchor, right_anchor)`, and their live position spans overlap. When they
  do, the block whose writer has the **greater peer id is the lower priority** one (matching
  the writer-priority tiebreak of the model and the peer-id ordering of
  `sec:interleavings`), and it is the one that moves. It is re-issued as a fresh contiguous
  chain inside `(gap_left, gap_right)` — a sub-interval of the shared parent interval chosen
  strictly to the left of the higher-priority block and containing no other live line — so
  the moved block can no longer lie between two lines of the block it conflicted with.

  ## Why equal anchors is exactly concurrency

  The anchor test is not a heuristic for concurrency, it is a characterization of it. A
  writer's authored parents are the lines immediately surrounding the point it typed at, so
  two blocks carrying the same anchors `(l, r)` were each typed when `l` and `r` were
  *adjacent*, that is, when the interval between them was empty. Neither writer had applied
  the other's block. Equal anchors therefore mean the two blocks were allocated concurrently
  into the same empty gap, which is the anomaly, and the rule reports no other pair. In
  particular a line typed *inside* another writer's block, after applying it, has that block's
  lines among its anchors, so preserving that nesting is intention preservation rather than an
  interleaving to repair.

  Detection is sound in this sense, and incomplete in exactly one shape: when a writer types
  a second concurrent block anchored on its own concurrently authored line, its anchors are
  `(l, own_line)` rather than `(l, r)`, so two writers doing this concurrently carry different
  anchor pairs and their overlap is not reported. Closing that case needs one immutable
  authored field per line, the number of foreign inserts the writer had applied at authoring,
  which tells whether one of its own lines belongs to the same authoring session and may be
  normalized away. It is stated as future work in `sec:interleavings` rather than guessed at
  here: a rule that merely drops the anchor test admits causally ordered pairs and moves
  deliberate edits.

  ## The gap invariant, which the termination argument rests on

  `nearest_left_non_member/3` picks the nearest line left of `gap_right` that is not a member
  of the moving block, and `successor_line/3` picks the line immediately after it *in the
  document list*. So `gap_left` and `wall` are **adjacent**: the position interval they bound
  holds no line at all, live or tombstoned, foreign or own. A re-issued block therefore lands
  where nothing else sits, disjoint from every block currently visible rather than only from
  the one it conflicted with, and its anchors are a fresh pair. That, with the priority rule,
  is what makes re-placement terminate: the writer of a moving block always has a greater peer
  id than the writer whose operation triggered the move, so a chain of triggers strictly
  descends the priority order and cannot cycle, and there are finitely many writers. The
  argument is written out in `sec:interleavings` and `theo:nonint`.
  """

  import Syncordian.Line_Object
  alias Syncordian.PathId

  @typedoc """
  A reconstructed authored block: its writer, its shared authored parent interval
  (`left_anchor` / `right_anchor` as `op_id`s, `nil` at a boundary sentinel), and its live
  lines in position order.
  """
  @type block :: %{
          writer: Syncordian.Basic_Types.peer_id(),
          left_anchor: Syncordian.Basic_Types.op_id() | nil,
          right_anchor: Syncordian.Basic_Types.op_id() | nil,
          lines: [Syncordian.Line_Object.line()]
        }

  @typedoc """
  A re-placement instruction: the `writer` that must re-issue, the superseded `moving_lines`
  (position-ordered live lines to retract), the `gap_left` / `gap_right` lines bounding
  the fresh, disjoint sub-interval the new chain is placed into, and `wall` — the document
  line immediately to the right of `gap_left` (the first superseded member inside the gap,
  or `gap_right` itself when the gap holds none). The writer authors the re-issued chain
  between `gap_left` and `wall`, which fixes the new lines' *positions*: they all sort
  strictly below `wall <= gap_right`, i.e. strictly left of the higher-priority block, so
  the non-interleaving postcondition (`theo:nonint`) is unchanged. Receivers locate each
  re-issued insert's authored parents by identity (op_id) through their op_index, so the
  re-issue is delivered wherever its named parents are present, independently of their
  current adjacency.
  """
  @type replacement :: %{
          writer: Syncordian.Basic_Types.peer_id(),
          moving_lines: [Syncordian.Line_Object.line()],
          gap_left: Syncordian.Line_Object.line(),
          gap_right: Syncordian.Line_Object.line(),
          wall: Syncordian.Line_Object.line()
        }

  @doc """
  True iff the line is a block member candidate: a non-sentinel line that is currently
  present in the document (`:aura` or `:settled`). Tombstoned lines — including the
  superseded originals retracted during a re-placement — are excluded, so they do not
  participate in interleaving detection (`def:intention` quantifies over *live* lines).
  """
  @spec live_block_line?(Syncordian.Line_Object.line()) :: boolean()
  def live_block_line?(line) do
    not PathId.sentinel?(get_line_id(line)) and get_line_status(line) in [:aura, :settled]
  end

  @doc """
  Reconstructs the authored blocks (`def:editblock`) present in `document`. Returns one
  `block/0` per (writer, authoring session) among the live lines, each with its lines in
  position order. O(n) in the document length.

  A line records the session it was authored in, so a block is exactly the set of live lines
  a writer authored into one interval during one run of inserts. Grouping is preferred to
  following the parent chain because the chain does not survive the two events a repair has
  to keep working across: a re-placement gives every moved line a fresh parent pair, and a
  delete inside a block breaks its chain in two. In both cases the session is unchanged, so
  the block is still recognised and its remaining interleavings can still be repaired.
  """
  @spec blocks(Syncordian.Basic_Types.document()) :: [block()]
  def blocks(document) do
    # The document is already ⋖-sorted, so grouping preserves position order within each
    # block, and no PathId comparison is needed here: this function runs on EVERY applied
    # insert and delete, and sorting large blocks with list-structured PathId comparisons
    # dominated whole replays.
    document
    |> Enum.filter(&live_block_line?/1)
    |> Enum.group_by(fn line -> {get_line_peer_id(line), get_line_session(line)} end)
    |> Enum.map(fn {{writer, session}, lines} -> build_block(writer, session, lines) end)
  end

  @typedoc """
  The stable identity of an authored block: its writer and the interval it was authored
  into. This is exactly the key `blocks/1` groups by, and it is immutable for the life of
  the block. A block's lines change as the document evolves, so anything derived from them
  (its head, its span, its parents) is not an identity that can be followed over time.
  """
  @type block_id :: {Syncordian.Basic_Types.peer_id(), Syncordian.Basic_Types.session() | nil}

  @typedoc """
  One unresolved interleaving, named by the two blocks that interleave, ordered by writer
  so the pair does not depend on which block was examined first.
  """
  @type conflict_id :: {block_id(), block_id()}

  @doc """
  Detects every interleaving conflict in `document` and returns both the conflicts and the
  re-placement instructions that resolve them (`sec:formal-intention`).

  Replica-independent: the result is a pure function of the converged document. The peer
  applies only those replacements whose `writer` is itself, and it uses the conflict list to
  observe interleavings it is not the one to repair. The two are computed together because
  every replica runs this after every applied operation, and reconstructing the blocks twice
  was the dominant cost of doing so.
  """
  @spec analyze(Syncordian.Basic_Types.document()) :: %{
          replacements: [replacement()],
          conflicts: [conflict_id()]
        }
  def analyze(document) do
    groups =
      document
      |> blocks()
      |> Enum.group_by(fn b -> {b.left_anchor, b.right_anchor} end)

    %{
      replacements:
        Enum.flat_map(groups, fn {_anchors, g} -> group_replacements(g, document) end),
      conflicts: Enum.flat_map(groups, fn {_anchors, g} -> group_conflicts(g) end)
    }
  end

  @doc """
  Detects every interleaving conflict in `document` and returns the re-placement
  instructions that resolve them (`sec:formal-intention`). Replica-independent: the result
  is a pure function of the converged document. The peer applies only those whose `writer`
  is itself.
  """
  @spec detect_replacements(Syncordian.Basic_Types.document()) :: [replacement()]
  def detect_replacements(document), do: analyze(document).replacements

  @doc """
  The interleavings currently present in `document`, each named by the pair of blocks that
  interleave.

  A conflict is reported at every replica that can see it, whether or not that replica is
  the one that repairs it, so counting them measures how much interleaving a run actually
  exhibits rather than how much repair work one peer did. Following the same conflict across
  successive documents is what makes it possible to say how long a repair took, which is why
  a conflict is named by the two blocks' immutable identities and not by their current lines.
  """
  @spec conflicts(Syncordian.Basic_Types.document()) :: [conflict_id()]
  def conflicts(document), do: analyze(document).conflicts

  @doc """
  Convenience predicate: true iff `document` contains at least one unresolved interleaving
  conflict. Used by tests and assertions.
  """
  @spec interleaved?(Syncordian.Basic_Types.document()) :: boolean()
  def interleaved?(document), do: detect_replacements(document) != []

  # ----- block reconstruction -------------------------------------------------------------

  # One block from a (writer, session) group. `lines` arrives in document order, which is
  # position order, and the session pair is the block's authored interval: the anchors its
  # writer began the run between. A line with no session (only the boundary sentinels, which
  # live_block_line?/1 already excludes) would carry a nil pair.
  @spec build_block(
          Syncordian.Basic_Types.peer_id(),
          Syncordian.Basic_Types.session() | nil,
          [Syncordian.Line_Object.line()]
        ) :: block()
  defp build_block(writer, session, lines) do
    {left_anchor, right_anchor} = session || {nil, nil}

    %{
      writer: writer,
      left_anchor: left_anchor,
      right_anchor: right_anchor,
      lines: lines
    }
  end

  # ----- conflict detection ---------------------------------------------------------------

  # Within one parent-interval group (blocks sharing the same authored anchors, hence
  # concurrently allocated into the same empty gap — see the module doc), emit a re-placement
  # for each block that is interleaved by a higher-priority (smaller peer id) block of a
  # distinct writer. The moved block is re-packed strictly left of every higher-priority block
  # it overlaps.
  #
  # `gap_right` is the LEAST position over the lines of ALL the higher-priority blocks this
  # block overlaps, not just one of them, so a single move settles every conflict the block
  # currently has: afterwards each of those blocks lies entirely to its right. This, and the
  # gap invariant recorded on nearest_left_non_member/3, are the two facts the termination
  # argument of theo:nonint uses; keep them when touching this function.
  #
  # Note a deliberate, conservative deviation from the formal model's wording: the model
  # re-issues only the *conflicting suffix* of the lower-priority block, while we move the
  # whole block. Moving the whole block is a superset of the suffix move that keeps the
  # re-issued chain contiguous inside one disjoint gap, so interleaving-freedom
  # (def:intention: no foreign live line strictly between two block lines, authored order
  # preserved) still holds at quiescence, at the cost of a few extra re-issued lines.
  @spec group_replacements([block()], Syncordian.Basic_Types.document()) :: [replacement()]
  defp group_replacements(group, document) do
    writers = group |> Enum.map(& &1.writer) |> Enum.uniq()

    if length(writers) < 2 do
      []
    else
      Enum.flat_map(group, fn block ->
        higher =
          Enum.filter(group, fn other ->
            other.writer < block.writer and spans_overlap?(other, block)
          end)

        case higher do
          [] ->
            []

          _ ->
            gap_right = min_position_line(higher)
            gap_left = gap_right && nearest_left_non_member(document, gap_right, block.lines)

            if gap_left == nil do
              []
            else
              [
                %{
                  writer: block.writer,
                  moving_lines: block.lines,
                  gap_left: gap_left,
                  gap_right: gap_right,
                  wall: successor_line(document, gap_left, gap_right)
                }
              ]
            end
        end
      end)
    end
  end

  # The conflicting pairs within one parent-interval group. The same overlap test the
  # re-placement rule uses, reported symmetrically: `group_replacements/2` emits one entry per
  # block that has to move, collapsing all the blocks it overlaps into a single instruction,
  # whereas an interleaving count has to name each interleaved pair once. Ordering the pair by
  # writer makes the identity independent of the order the group was examined in, so the same
  # conflict observed at two replicas, or at one replica across two applies, is the same value.
  @spec group_conflicts([block()]) :: [conflict_id()]
  defp group_conflicts(group) do
    for a <- group,
        b <- group,
        a.writer < b.writer,
        spans_overlap?(a, b),
        do: {block_id(a), block_id(b)}
  end

  @spec block_id(block()) :: block_id()
  defp block_id(block), do: {block.writer, {block.left_anchor, block.right_anchor}}

  # Two blocks' live position spans overlap iff neither lies entirely to one side of the
  # other. Both `lines` lists are position-sorted, so the span is (first, last).
  @spec spans_overlap?(block(), block()) :: boolean()
  defp spans_overlap?(a, b) do
    {a_min, a_max} = block_span(a)
    {b_min, b_max} = block_span(b)
    not (PathId.less?(a_max, b_min) or PathId.less?(b_max, a_min))
  end

  @spec block_span(block()) ::
          {Syncordian.Basic_Types.line_id(), Syncordian.Basic_Types.line_id()}
  defp block_span(block) do
    {get_line_id(List.first(block.lines)), get_line_id(List.last(block.lines))}
  end

  # The minimum-position line over all the given blocks' lines; nil when the blocks carry
  # no lines (not expected — every reconstructed block holds at least its head — but a
  # crash inside the peer loop would be worse than skipping the group).
  @spec min_position_line([block()]) :: Syncordian.Line_Object.line() | nil
  defp min_position_line(blocks) do
    blocks
    |> Enum.flat_map(& &1.lines)
    |> Enum.min_by(&get_line_id/1, PathId, fn -> nil end)
  end

  # The document line immediately after `gap_left` in the ⋖-sorted document (taken from
  # the list itself, so position ties resolved by the identity tiebreak stay consistent).
  # By construction of nearest_left_non_member/3 every line strictly between gap_left and
  # gap_right is a moving-block member, so the successor is the first superseded member,
  # or gap_right itself when the gap holds none — never a foreign line. `fallback`
  # (gap_right) is only reached if gap_left were somehow absent or the last line, which
  # cannot happen for a line chosen strictly left of gap_right; it keeps the function
  # total.
  @spec successor_line(
          Syncordian.Basic_Types.document(),
          Syncordian.Line_Object.line(),
          Syncordian.Line_Object.line()
        ) :: Syncordian.Line_Object.line()
  defp successor_line(document, gap_left, fallback) do
    gap_left_id = get_line_id(gap_left)

    case Enum.drop_while(document, fn line -> get_line_id(line) != gap_left_id end) do
      [_gap_left, successor | _] -> successor
      _ -> fallback
    end
  end

  # The closest line strictly to the left of `gap_right` in the sorted document that is not
  # one of the `members` (the moving block's own lines). The interval (result, gap_right)
  # therefore contains only the moving block's superseded lines, so the re-issued chain
  # lands in a clean, disjoint gap. Always finds at least the infimum sentinel; nil only if
  # `gap_right` is the leftmost line (not reachable for a real block line).
  #
  # THE GAP INVARIANT (theo:nonint depends on it). Because every line between the result and
  # `gap_right` is a member of the moving block, and successor_line/3 then takes the document
  # line immediately after the result, the pair (gap_left, wall) the caller hands to the writer
  # is *adjacent in the document*: the interval it bounds holds no line at all, live or
  # tombstoned, of any writer. The re-issued block is therefore disjoint from every block
  # currently visible, not merely from the one it conflicted with, and it carries a fresh
  # anchor pair. The filter is over ALL lines, tombstones included, which is what makes the
  # interval empty rather than merely free of live lines; do not narrow it to live lines.
  @spec nearest_left_non_member(
          Syncordian.Basic_Types.document(),
          Syncordian.Line_Object.line(),
          [Syncordian.Line_Object.line()]
        ) :: Syncordian.Line_Object.line() | nil
  defp nearest_left_non_member(document, gap_right, members) do
    member_ids = MapSet.new(members, &get_line_id/1)
    gap_right_id = get_line_id(gap_right)

    document
    |> Enum.filter(fn line ->
      PathId.less?(get_line_id(line), gap_right_id) and
        not MapSet.member?(member_ids, get_line_id(line))
    end)
    |> Enum.reduce(nil, fn line, acc ->
      cond do
        acc == nil -> line
        PathId.less?(get_line_id(acc), get_line_id(line)) -> line
        true -> acc
      end
    end)
  end
end
