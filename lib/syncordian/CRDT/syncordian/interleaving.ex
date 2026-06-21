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
  (position-ordered live lines to retract), and the `gap_left` / `gap_right` lines bounding
  the fresh, disjoint sub-interval the new chain is placed into.
  """
  @type replacement :: %{
          writer: Syncordian.Basic_Types.peer_id(),
          moving_lines: [Syncordian.Line_Object.line()],
          gap_left: Syncordian.Line_Object.line(),
          gap_right: Syncordian.Line_Object.line()
        }

  @doc """
  True iff the line is a block member candidate: a non-sentinel line that is currently
  present in the document (`:aura` or `:settled`). Tombstoned and `:conflict` lines are
  excluded — the former are gone, the latter are mid-re-placement — so neither participates
  in interleaving detection (`def:intention` quantifies over *live* lines).
  """
  @spec live_block_line?(Syncordian.Line_Object.line()) :: boolean()
  def live_block_line?(line) do
    not PathId.sentinel?(get_line_id(line)) and get_line_status(line) in [:aura, :settled]
  end

  @doc """
  Reconstructs the authored blocks (`def:editblock`) present in `document`. Returns one
  `block/0` per maximal same-writer authored chain among the live lines, each with its
  lines in position order. O(n) in the document length.
  """
  @spec blocks(Syncordian.Basic_Types.document()) :: [block()]
  def blocks(document) do
    live = Enum.filter(document, &live_block_line?/1)
    by_opid = Map.new(live, fn l -> {get_line_op_id(l), l} end)

    # Successor index: a line keyed by (writer, right anchor, its left parent) is the unique
    # next link of the chain whose current line has that op_id.
    succ_index =
      Map.new(live, fn l ->
        {{get_line_peer_id(l), get_line_parent_right_op_id(l), get_line_parent_left_op_id(l)}, l}
      end)

    live
    |> Enum.filter(fn l -> block_head?(l, by_opid) end)
    |> Enum.map(fn head -> build_block(head, succ_index) end)
  end

  @doc """
  Detects every interleaving conflict in `document` and returns the re-placement
  instructions that resolve them (`sec:formal-intention`). Replica-independent: the result
  is a pure function of the converged document. The peer applies only those whose `writer`
  is itself.
  """
  @spec detect_replacements(Syncordian.Basic_Types.document()) :: [replacement()]
  def detect_replacements(document) do
    document
    |> blocks()
    |> Enum.group_by(fn b -> {b.left_anchor, b.right_anchor} end)
    |> Enum.flat_map(fn {_anchors, group} -> group_replacements(group, document) end)
  end

  @doc """
  Convenience predicate: true iff `document` contains at least one unresolved interleaving
  conflict. Used by tests and assertions.
  """
  @spec interleaved?(Syncordian.Basic_Types.document()) :: boolean()
  def interleaved?(document), do: detect_replacements(document) != []

  # ----- block reconstruction -------------------------------------------------------------

  # A line heads a block iff its authored left parent is not a present line of the same
  # writer and the same right anchor (i.e. the left parent is a boundary or anchor outside
  # the block, so the chain starts here).
  @spec block_head?(Syncordian.Line_Object.line(), map()) :: boolean()
  defp block_head?(line, by_opid) do
    case Map.get(by_opid, get_line_parent_left_op_id(line)) do
      nil ->
        true

      parent ->
        not (get_line_peer_id(parent) == get_line_peer_id(line) and
               get_line_parent_right_op_id(parent) == get_line_parent_right_op_id(line))
    end
  end

  @spec build_block(Syncordian.Line_Object.line(), map()) :: block()
  defp build_block(head, succ_index) do
    lines = unfold_chain(head, succ_index, [head], MapSet.new([get_line_id(head)]))

    %{
      writer: get_line_peer_id(head),
      left_anchor: get_line_parent_left_op_id(head),
      right_anchor: get_line_parent_right_op_id(head),
      lines: Enum.sort(lines, &line_leq?/2)
    }
  end

  # Follows the authored chain from `current`, accumulating lines. `seen` guards against a
  # pathological cycle (never expected: the authored chain is linear).
  @spec unfold_chain(Syncordian.Line_Object.line(), map(), [Syncordian.Line_Object.line()], MapSet.t()) ::
          [Syncordian.Line_Object.line()]
  defp unfold_chain(current, succ_index, acc, seen) do
    key = {get_line_peer_id(current), get_line_parent_right_op_id(current), get_line_op_id(current)}

    case Map.get(succ_index, key) do
      nil ->
        acc

      next ->
        next_id = get_line_id(next)

        if MapSet.member?(seen, next_id) do
          acc
        else
          unfold_chain(next, succ_index, [next | acc], MapSet.put(seen, next_id))
        end
    end
  end

  # ----- conflict detection ---------------------------------------------------------------

  # Within one parent-interval group (blocks sharing the same authored anchors), emit a
  # re-placement for each block that is interleaved by a higher-priority (smaller peer id)
  # block of a distinct writer. The moved block is re-packed strictly left of every
  # higher-priority block it overlaps.
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
            gap_left = nearest_left_non_member(document, gap_right, block.lines)

            if gap_left == nil do
              []
            else
              [
                %{
                  writer: block.writer,
                  moving_lines: block.lines,
                  gap_left: gap_left,
                  gap_right: gap_right
                }
              ]
            end
        end
      end)
    end
  end

  # Two blocks' live position spans overlap iff neither lies entirely to one side of the
  # other. Both `lines` lists are position-sorted, so the span is (first, last).
  @spec spans_overlap?(block(), block()) :: boolean()
  defp spans_overlap?(a, b) do
    {a_min, a_max} = block_span(a)
    {b_min, b_max} = block_span(b)
    not (PathId.less?(a_max, b_min) or PathId.less?(b_max, a_min))
  end

  @spec block_span(block()) :: {Syncordian.Basic_Types.line_id(), Syncordian.Basic_Types.line_id()}
  defp block_span(block) do
    {get_line_id(List.first(block.lines)), get_line_id(List.last(block.lines))}
  end

  # The minimum-position line over all the given blocks' lines.
  @spec min_position_line([block()]) :: Syncordian.Line_Object.line()
  defp min_position_line(blocks) do
    blocks
    |> Enum.flat_map(& &1.lines)
    |> Enum.reduce(fn line, acc ->
      if PathId.less?(get_line_id(line), get_line_id(acc)), do: line, else: acc
    end)
  end

  # The closest line strictly to the left of `gap_right` in the sorted document that is not
  # one of the `members` (the moving block's own lines). The interval (result, gap_right)
  # therefore contains only the moving block's superseded lines, so the re-issued chain
  # lands in a clean, disjoint gap. Always finds at least the infimum sentinel; nil only if
  # `gap_right` is the leftmost line (not reachable for a real block line).
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

  @spec line_leq?(Syncordian.Line_Object.line(), Syncordian.Line_Object.line()) :: boolean()
  defp line_leq?(a, b), do: PathId.compare(get_line_id(a), get_line_id(b)) != :gt
end
