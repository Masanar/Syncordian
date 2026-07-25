defmodule Syncordian.InterleavingTest do
  @moduledoc """
  Unit tests for the pure interleaving detector (`Syncordian.Interleaving`): authored-block
  reconstruction (`def:editblock`) and the same-parent-interval conflict / re-placement
  decision (`def:intention`, `sec:formal-intention`).

  A block is identified by its writer and its *authoring session*, the interval the writer
  began the run of inserts in, which every line records. `mk_line/7` therefore takes that pair:
  a line starting a run carries its own authored parents (the default), and a line continuing
  the run carries the session of the line that started it, exactly as
  `Syncordian.Line.session_for/3` computes it at authoring time.
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  alias Syncordian.Interleaving
  alias Syncordian.PathId

  # Build a single-segment line. The digit is the position (segments compare digit-first), so
  # ordering a document by digit orders it by PathId. op_id / parents carry authored identity,
  # and `session` the block identity (defaults to a line that starts its own run).
  defp mk_line(digit, peer, op_id, parent_left, parent_right, status \\ :settled, session \\ nil) do
    line(
      line_id: {:path, [{digit, peer}]},
      content: "c#{digit}",
      signature: "sig#{digit}.#{peer}",
      peer_id: peer,
      status: status,
      commit_at: [],
      op_id: op_id,
      parent_left_op_id: parent_left,
      parent_right_op_id: parent_right,
      session: session || {parent_left, parent_right}
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

  # A line continuing the run its writer started in the (L, R) interval.
  defp mk_lr_line(digit, peer, op_id, parent_left, parent_right, status \\ :settled),
    do: mk_line(digit, peer, op_id, parent_left, parent_right, status, {@l_op, @r_op})

  # The gap invariant the termination argument rests on: `gap_left` and `wall` are adjacent in
  # the document, so the interval the re-issued block is authored into holds no other line at
  # all, and `wall` is at or left of `gap_right`, so the moved block lands left of every block
  # it conflicted with.
  defp assert_clean_gap(document, replacement) do
    %{gap_left: gap_left, gap_right: gap_right, wall: wall} = replacement
    ids = Enum.map(document, &get_line_id/1)
    left_index = Enum.find_index(ids, &(&1 == get_line_id(gap_left)))
    wall_index = Enum.find_index(ids, &(&1 == get_line_id(wall)))

    assert wall_index == left_index + 1,
           "gap_left and wall are not adjacent (#{left_index} vs #{wall_index})"

    assert PathId.compare(get_line_id(wall), get_line_id(gap_right)) in [:lt, :eq],
           "wall sorts after gap_right"
  end

  # Applies a re-placement the way `Syncordian.Peer.reissue_replacement/2` does, without the
  # crypto: a fresh chain of the same contents inside (gap_left, wall), each line naming the
  # previous one as its left parent and `wall` as its right parent, and every superseded line
  # retracted. Identities continue the writer's sequence, and each re-issued line keeps the
  # authoring session of the line it supersedes, which is what keeps the moved block
  # recognisable as the same block.
  defp apply_replacement(document, replacement) do
    %{writer: writer, moving_lines: moving, gap_left: gap_left, wall: wall} = replacement
    next_seq = document |> Enum.map(&get_line_op_id/1) |> max_seq(writer)
    session = moving |> hd() |> get_line_session()

    {reissued, _} =
      Enum.map_reduce(moving, {gap_left, next_seq}, fn old, {left, seq} ->
        new =
          line(
            line_id: PathId.between(get_line_id(left), get_line_id(wall), writer),
            content: get_content(old),
            signature: "sig-reissued-#{writer}-#{seq}",
            peer_id: writer,
            status: :settled,
            commit_at: [],
            op_id: {writer, seq},
            parent_left_op_id: get_line_op_id(left),
            parent_right_op_id: get_line_op_id(wall),
            session: session
          )

        {new, {new, seq + 1}}
      end)

    moved_ids = MapSet.new(moving, &get_line_id/1)

    document
    |> Enum.map(fn l ->
      if MapSet.member?(moved_ids, get_line_id(l)), do: set_line_status(l, :tombstone), else: l
    end)
    |> Enum.concat(reissued)
    |> Enum.sort(fn a, b -> Syncordian.Line.compare_lines(a, b) != 1 end)
  end

  defp max_seq(op_ids, writer) do
    op_ids
    |> Enum.filter(&match?({^writer, _}, &1))
    |> Enum.map(fn {_w, seq} -> seq end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # Applies every detected re-placement, round by round, until none is left.
  defp settle(document, rounds) do
    case Interleaving.detect_replacements(document) do
      [] ->
        {document, rounds}

      _ when rounds > 8 ->
        {document, rounds}

      replacements ->
        document
        |> then(fn doc -> Enum.reduce(replacements, doc, &apply_replacement(&2, &1)) end)
        |> settle(rounds + 1)
    end
  end

  describe "block reconstruction (def:editblock)" do
    test "links a same-writer chain into one block, in position order" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      a3 = mk_lr_line(40, 1, {1, 3}, {1, 2}, @r_op)

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
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op, :tombstone)
      a3 = mk_lr_line(40, 1, {1, 3}, {1, 2}, @r_op)

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
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2]))
    end

    test "two blocks with disjoint position spans are not interleaved" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(15, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(30, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(35, 2, {2, 2}, {2, 1}, @r_op)
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2, b1, b2]))
    end

    test "an insert nested in another block's interval (different anchors) is intentional, not a conflict" do
      # B is authored between a1 and a2 (its parents are a1/a2), so although b1 lies
      # positionally between a1 and a2, the blocks do NOT share a parent interval. This is a
      # deliberate nested edit, not a concurrent same-interval interleaving.
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, {1, 1}, {1, 2})
      refute Interleaving.interleaved?(doc([anchor_l(), anchor_r(), a1, a2, b1]))
    end
  end

  describe "conflict detection and re-placement (def:intention, theo:nonint)" do
    test "lower-priority (greater peer id) block moves, into a clean gap left of the higher block" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(40, 2, {2, 2}, {2, 1}, @r_op)

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
      # No moving-block line lies between gap_left and gap_right, so the wall — the fixed
      # right parent the writer re-issues against — is gap_right itself.
      assert get_line_id(r.wall) == get_line_id(a1)
    end

    test "the wall is the first superseded member when one lies inside the gap" do
      # b1@7 sits between the anchor L@5 (gap_left) and a1@10 (gap_right), so the writer
      # must author the re-issued chain against (L, b1): the interval (L, b1) is empty, so
      # every authored parent pair is adjacent in the writer's document — the invariant the
      # receivers' parent locator relies on. Authoring against (L, a1) instead would put the
      # authored pair beyond the receivers' adjacency/window search (b1 still occupies its
      # position after retraction, tombstones are never removed).
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(7, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(40, 2, {2, 2}, {2, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, a2, b1, b2])
      replacements = Interleaving.detect_replacements(document)

      assert length(replacements) == 1
      [r] = replacements
      assert r.writer == 2
      assert get_line_id(r.gap_left) == get_line_id(anchor_l())
      assert get_line_id(r.gap_right) == get_line_id(a1)
      assert get_line_id(r.wall) == get_line_id(b1)
    end

    test "priority is by writer id regardless of which side is positionally first" do
      # Same geometry, but now block A's writer (3) is the lower priority one, so A moves.
      a1 = mk_line(10, 3, {3, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 3, {3, 2}, {3, 1}, @r_op)
      b1 = mk_line(20, 1, {1, 1}, @l_op, @r_op)
      b2 = mk_lr_line(40, 1, {1, 2}, {1, 1}, @r_op)

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
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(25, 2, {2, 2}, {2, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, b1, b2, a2])
      replacements = Interleaving.detect_replacements(document)

      assert length(replacements) == 1
      [r] = replacements
      assert r.writer == 2
      assert get_line_id(r.gap_right) == get_line_id(a1)
    end

    test "three blocks in one interval: both lower-priority writers move, into clean gaps" do
      # Writers 1, 2 and 3 all author into (L, R) while disconnected, and the three blocks
      # end up interleaved. Writer 1 is fixed; writers 2 and 3 must both re-place.
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(40, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(45, 2, {2, 2}, {2, 1}, @r_op)
      c1 = mk_line(30, 3, {3, 1}, @l_op, @r_op)
      c2 = mk_lr_line(48, 3, {3, 2}, {3, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, a2, b1, b2, c1, c2])
      replacements = Interleaving.detect_replacements(document)

      assert Enum.map(replacements, & &1.writer) |> Enum.sort() == [2, 3]

      Enum.each(replacements, fn r -> assert_clean_gap(document, r) end)
    end

    test "identical content in both blocks does not confuse detection" do
      # Same text, same interval, two writers. Blocks are reconstructed from identities, never
      # from content, so the conflict resolves exactly as with distinct content.
      a1 = line(mk_line(10, 1, {1, 1}, @l_op, @r_op), content: "same")
      a2 = line(mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op), content: "same")
      b1 = line(mk_line(20, 2, {2, 1}, @l_op, @r_op), content: "same")
      b2 = line(mk_lr_line(40, 2, {2, 2}, {2, 1}, @r_op), content: "same")

      document = doc([anchor_l(), anchor_r(), a1, a2, b1, b2])
      replacements = Interleaving.detect_replacements(document)

      assert [%{writer: 2}] = replacements
      [r] = replacements
      assert Enum.map(r.moving_lines, &get_line_op_id/1) == [{2, 1}, {2, 2}]
      assert_clean_gap(document, r)
    end

    test "repeated re-placement reaches a fixpoint with every block contiguous" do
      # The termination argument, exercised: apply every detected re-placement, then detect
      # again, until nothing is left to move. Each round moves only lower-priority blocks, so
      # the loop must stop; the bound below is a failure guard, not an expectation.
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(40, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op)
      b2 = mk_lr_line(45, 2, {2, 2}, {2, 1}, @r_op)
      c1 = mk_line(30, 3, {3, 1}, @l_op, @r_op)
      c2 = mk_lr_line(48, 3, {3, 2}, {3, 1}, @r_op)

      document = doc([anchor_l(), anchor_r(), a1, a2, b1, b2, c1, c2])
      {final, rounds} = settle(document, 0)

      assert rounds <= 4, "re-placement did not settle: #{rounds} rounds"
      refute Interleaving.interleaved?(final)

      # Each writer's live lines form one consecutive run, in authored order.
      Enum.each([1, 2, 3], fn writer ->
        live =
          final
          |> Enum.filter(&Interleaving.live_block_line?/1)
          |> Enum.map(&get_line_peer_id/1)

        runs = live |> Enum.chunk_by(& &1) |> Enum.filter(&(hd(&1) == writer))
        assert length(runs) == 1, "writer #{writer} is not contiguous: #{inspect(live)}"
      end)
    end

    test "retracting the moving block's lines (tombstones) makes detection idempotent" do
      a1 = mk_line(10, 1, {1, 1}, @l_op, @r_op)
      a2 = mk_lr_line(30, 1, {1, 2}, {1, 1}, @r_op)
      b1 = mk_line(20, 2, {2, 1}, @l_op, @r_op, :tombstone)
      b2 = mk_lr_line(40, 2, {2, 2}, {2, 1}, @r_op, :tombstone)

      document = doc([anchor_l(), anchor_r(), a1, b1, a2, b2])
      assert Interleaving.detect_replacements(document) == []
    end
  end
end
