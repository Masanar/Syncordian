defmodule Syncordian.PathIdTest do
  use ExUnit.Case, async: true

  alias Syncordian.PathId, as: P

  doctest Syncordian.PathId

  describe "compare/2 sentinels" do
    test "infimum is less than everything else" do
      assert P.compare(P.infimum(), P.supremum()) == :lt
      assert P.compare(P.infimum(), {:path, [{0, 0}]}) == :lt
      assert P.compare(P.infimum(), P.infimum()) == :eq
    end

    test "supremum is greater than everything else" do
      assert P.compare(P.supremum(), P.infimum()) == :gt
      assert P.compare(P.supremum(), {:path, [{P.base() - 1, 99}]}) == :gt
      assert P.compare(P.supremum(), P.supremum()) == :eq
    end
  end

  describe "compare/2 paths" do
    test "digit ordering" do
      assert P.compare({:path, [{1, 0}]}, {:path, [{2, 0}]}) == :lt
      assert P.compare({:path, [{2, 0}]}, {:path, [{1, 0}]}) == :gt
    end

    test "peer-id tiebreak when same digit" do
      assert P.compare({:path, [{1, 0}]}, {:path, [{1, 1}]}) == :lt
    end

    test "prefix is less than extension" do
      assert P.compare({:path, [{1, 0}]}, {:path, [{1, 0}, {0, 0}]}) == :lt
      assert P.compare({:path, [{1, 0}, {99, 0}]}, {:path, [{1, 0}]}) == :gt
    end

    test "lexicographic on later segments" do
      assert P.compare({:path, [{1, 0}, {3, 0}]}, {:path, [{1, 0}, {5, 0}]}) == :lt
    end
  end

  describe "between/3 invariants" do
    test "between infimum and supremum yields a valid path" do
      :rand.seed(:exsplus, {1, 2, 3})
      new = P.between(P.infimum(), P.supremum(), 7)
      assert P.less?(P.infimum(), new)
      assert P.less?(new, P.supremum())
    end

    test "between two paths with room picks a midpoint" do
      :rand.seed(:exsplus, {4, 5, 6})
      left = {:path, [{10, 0}]}
      right = {:path, [{20, 0}]}
      new = P.between(left, right, 3)
      assert P.less?(left, new)
      assert P.less?(new, right)
    end

    test "between adjacent digits extends path" do
      :rand.seed(:exsplus, {7, 8, 9})
      left = {:path, [{5, 0}]}
      right = {:path, [{6, 0}]}
      new = P.between(left, right, 1)
      assert P.less?(left, new)
      assert P.less?(new, right)
    end

    test "between prefix and extension extends further" do
      :rand.seed(:exsplus, {10, 11, 12})
      left = {:path, [{5, 0}]}
      right = {:path, [{5, 0}, {3, 0}]}
      new = P.between(left, right, 2)
      assert P.less?(left, new)
      assert P.less?(new, right)
    end

    test "between two paths with the same first segment but different second" do
      :rand.seed(:exsplus, {13, 14, 15})
      left = {:path, [{5, 0}, {10, 0}]}
      right = {:path, [{5, 0}, {20, 0}]}
      new = P.between(left, right, 4)
      assert P.less?(left, new)
      assert P.less?(new, right)
    end

    test "between infimum and a path" do
      :rand.seed(:exsplus, {16, 17, 18})
      right = {:path, [{5, 0}]}
      new = P.between(P.infimum(), right, 2)
      assert P.less?(P.infimum(), new)
      assert P.less?(new, right)
    end

    test "between a path and supremum" do
      :rand.seed(:exsplus, {19, 20, 21})
      left = {:path, [{5, 0}]}
      new = P.between(left, P.supremum(), 2)
      assert P.less?(left, new)
      assert P.less?(new, P.supremum())
    end

    test "between paths differing only by peer id descends to a lower level" do
      :rand.seed(:exsplus, {22, 23, 24})
      left = {:path, [{5, 0}]}
      right = {:path, [{5, 1}]}
      new = P.between(left, right, 9)
      assert P.less?(left, new)
      assert P.less?(new, right)
    end

    test "raises when left >= right" do
      assert_raise ArgumentError, fn ->
        P.between({:path, [{5, 0}]}, {:path, [{5, 0}]}, 1)
      end

      assert_raise ArgumentError, fn ->
        P.between({:path, [{6, 0}]}, {:path, [{5, 0}]}, 1)
      end
    end

    test "allocation is total: random-halving subdivision never fails (def:positions)" do
      # The formal model requires the position order to be dense: between/3 must succeed
      # for EVERY pair left < right. This stress loop randomly halves the interval —
      # always descending toward the boundary the old encoding saturated at — and
      # asserts a strictly-between path on every one of 10_000 calls, with no rescue:
      # a raise is a test failure.
      :rand.seed(:exsplus, {99, 99, 99})

      Enum.reduce(1..10_000, {P.infimum(), P.supremum()}, fn _i, {l, r} ->
        mid = P.between(l, r, :rand.uniform(1_000_000))

        assert P.less?(l, mid),
               "between/3 not strictly greater than left: #{inspect({l, mid})}"

        assert P.less?(mid, r),
               "between/3 not strictly less than right: #{inspect({mid, r})}"

        if rem(:rand.uniform(1000), 2) == 0, do: {l, mid}, else: {mid, r}
      end)
    end

    test "tight corner: right ending in a {0, p} wall the peer id cannot undercut" do
      # Historically the ArgumentError corner: right = prefix ++ [{0, p}] with an
      # allocating peer whose tiebreak id cannot go below p. The reserved-id fallback
      # (see "Totality" in the moduledoc) must still allocate strictly between.
      left = {:path, [{3, 1}]}
      right = {:path, [{3, 1}, {0, 1}]}

      for peer <- [0, 1, 5, 1_000] do
        new = P.between(left, right, peer)
        assert P.less?(left, new), "peer #{peer}: #{inspect(new)} not above left"
        assert P.less?(new, right), "peer #{peer}: #{inspect(new)} not below right"
      end
    end

    test "tight corner from the infimum against a minimal wall" do
      # Even a wall built with the reserved minimum id 0 (never allocator-minted, but
      # constructible) keeps allocation total.
      right = {:path, [{0, 0}]}

      for peer <- [0, 7] do
        new = P.between(P.infimum(), right, peer)
        assert P.less?(P.infimum(), new)
        assert P.less?(new, right), "peer #{peer}: #{inspect(new)} not below #{inspect(right)}"
      end
    end

    test "repeated leftmost inserts by the same peer never exhaust the order" do
      # The adversarial pattern that motivated the fallback: one peer keeps inserting
      # at the very front, so each allocation's right bound is its own previous mint.
      :rand.seed(:exsplus, {42, 42, 42})

      Enum.reduce(1..500, P.supremum(), fn _i, right ->
        new = P.between(P.infimum(), right, 3)
        assert P.less?(P.infimum(), new)
        assert P.less?(new, right)
        new
      end)
    end

    test "minted segments never use the reserved tiebreak id 0" do
      :rand.seed(:exsplus, {5, 5, 5})
      new = P.between(P.infimum(), P.supremum(), 0)
      {:path, [{_digit, sid}]} = new
      assert sid == 1
    end
  end

  describe "to_string/1" do
    test "renders sentinels and paths" do
      assert P.to_string(P.infimum()) == "<inf>"
      assert P.to_string(P.supremum()) == "<sup>"
      assert P.to_string({:path, [{12, 3}, {7, 0}]}) == "12.3/7.0"
    end
  end
end
