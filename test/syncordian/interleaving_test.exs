defmodule Syncordian.InterleavingTest do
  @moduledoc """
  Unit tests for the pure interleaving detector (`Syncordian.Interleaving`): authored-block
  reconstruction (`def:editblock`) and the same-parent-interval conflict / re-placement
  decision (`def:intention`, `sec:formal-intention`).
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  alias Syncordian.Interleaving
  alias Syncordian.PathId

  # Build a single-segment line. The digit is the position (segments compare digit-first), so
  # ordering a document by digit orders it by PathId. op_id / parents carry authored identity.
  defp mk_line(digit, peer, op_id, parent_left, parent_right, status \\ :settled) do
    line(
      line_id: {:path, [{digit, peer}]},
      content: "c#{digit}",
      signature: "sig#{digit}.#{peer}",
      peer_id: peer,
      status: status,
      commit_at: [],
      op_id: op_id,
      parent_left_op_id: parent_left,
      parent_right_op_id: parent_right
    )
  end

  # Sort a list of lines into a valid (position-ordered) document, sentinels included.
  defp doc(lines) do
    infimum = create_infimum_line(0, 3)
    supremum = create_supremum_line(0, 3)

    Enum.sort([infimum, supremum | lines], fn a, b ->
      PathId.compare(get_line_id(a), get_line_id(b)) != :gt
    end)
  end

  # Anchors L and R shared by the concurrently-authored blocks in most scenarios.
  @l_op {0, 1}
  @r_op {0, 2}
  defp anchor_l, do: mk_line(5, 0, @l_op, nil, nil)
  defp anchor_r, do: mk_line(50, 0, @r_op, nil, nil)

  describe "block reconstruction (def:editblock)" do
    test "links a same-writer chain into one block, in position order" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      a3 = mk_line(40, 1, {1, 3}, {1, 2}, @r_op)

      # The anchors L/R are themselves live lines, so they form their own singleton blocks;
      # restrict to writer 1's block.
      blocks = Interleaving.blocks(doc([anchor_l(), anchor_r(), a1, a3, a2]))
      blocks = Enum.filter(blocks, &(&1.writer == 1))

      assert length(blocks) == 1
      [block] = blocks
      assert block.writer == 1
      assert block.left_anchor == @l_op
      assert block.right_anchor == @r_op
      assert Enum.map(block.lines, &get_line_id/1) == [a1, a2, a3] |> Enum.map(&get_line_id/1)
    end

    test "distinct writers in the same interval are distinct blocks" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)

      blocks =
        Interleaving.blocks(doc([anchor_l(), anchor_r(), a1, b1]))
        |> Enum.filter(&(&1.writer in [1, 2]))

      assert length(blocks) == 2
      assert Enum.map(blocks, & &1.writer) |> Enum.sort() == [1, 2]
    end

    test "a tombstone in the middle of a chain does not crash and is excluded from live lines" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op, :tombstone)
      a3 = mk_line(40, 1, {1, 3}, {1, 2}, @r_op)

      blocks = Interleaving.blocks(doc([anchor_l(), anchor_r(), a1, a2, a3]))
      live_ids = blocks |> Enum.flat_map(& &1.lines) |> Enum.map(&get_line_id/1)
      refute get_line_id(a2) in live_ids
      assert get_line_id(a1) in live_ids
      assert get_line_id(a3) in live_ids
    end
  end

  describe "no false positives" do
    test "a single block is not a conflict" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2]))
    end

    test "two blocks with disjoint position spans are not interleaved" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(15, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(30, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_line(35, 2, {2, 2}, {2, 1}, @r_op)
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2, b1, b2]))
    end

    test "an insert nested in another block's interval (different anchors) is intentional, not a conflict" do
      # B is authored between a1 and a2 (its parents are a1/a2), so although b1 lies
      # positionally between a1 and a2, the blocks do NOT share a parent interval. This is a
      # deliberate nested edit, not a concurrent same-interval interleaving.
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, {1, 1}, {1, 2})
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2, b1]))
    end
  end

  describe "conflict detection and re-placement (def:intention, theo:nonint)" do
    test "lower-priority (greater peer id) block moves, into a clean gap left of the higher block" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_line(40, 2, {2, 2}, {2, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, b1, a2, b2])
      replacements = Interleaving.detect_replacements(document)

      assert length(replacements) == 1
      [r] = replacements
      # writer 2 > writer 1, so block B is lower priority and moves.
      assert r.writer == 2
      assert Enum.map(r.moving_lines, &get_line_id/1) == [b1, b2] |> Enum.map(&get_line_id/1)
      # gap_right is the highest-priority block's first line (a1); gap_left is the anchor L,
      # the nearest non-B line to its left — so (L, a1) is a clean, disjoint sub-interval.
      assert get_line_id(r.gap_right) == get_line_id(a1)
      assert get_line_id(r.gap_left) == get_line_id(anchor_l())
    end

    test "priority is by writer id regardless of which side is positionally first" do
      # Same geometry, but now block A's writer (3) is the lower priority one, so A moves.
      a1 = mk_line(10, 3, {3, 1}, @l_op, @r_op)
      a2 = mk_line(30, 3, {3, 2}, {3, 1}, @r_op)
      b1 = mk_line(20, 1, {1, 1}, @l_op, @r_op)
      b2 = mk_line(40, 1, {1, 2}, {1, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, b1, a2, b2])
      replacements = Interleaving.detect_replacements(document)

      assert length(replacements) == 1
      [r] = replacements
      assert r.writer == 3
      assert Enum.map(r.moving_lines, &get_line_id/1) == [a1, a2] |> Enum.map(&get_line_id/1)
      # gap_right is b1 (writer 1's first line); gap_left is L.
      assert get_line_id(r.gap_right) == get_line_id(b1)
      assert get_line_id(r.gap_left) == get_line_id(anchor_l())
    end

    test "a nested lower-priority block (no higher-block line inside its span) still moves" do
      # B = {b1@20, b2@25} is nested inside A = {a1@10, a2@30}, same anchors. A has no line
      # strictly between b1 and b2, but B has lines between a1 and a2, so A is interleaved by
      # B and the conflict is real; the lower-priority B re-packs left of A.
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_line(25, 2, {2, 2}, {2, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, b1, b2, a2])
      replacements = Interleaving.detect_replacements(document)

      assert length(replacements) == 1
      [r] = replacements
      assert r.writer == 2
      assert get_line_id(r.gap_right) == get_line_id(a1)
    end

    test "marking the moving block's lines non-live (e.g. :conflict) makes detection idempotent" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op, :conflict)
      b2 = mk_line(40, 2, {2, 2}, {2, 1}, @r_op, :conflict)

      document = doc([anchor_l(), anchor_r(), a1, b1, a2, b2])
      assert Interleaving.detect_replacements(document) == []
    end
  end
end
