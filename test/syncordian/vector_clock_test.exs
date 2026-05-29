defmodule Syncordian.VectorClockTest do
  use ExUnit.Case, async: true

  alias Syncordian.Vector_Clock, as: VC

  doctest Syncordian.Vector_Clock

  describe "happens_before_or_equal?/2" do
    test "reflexive on equal vectors" do
      assert VC.happens_before_or_equal?([1, 2, 3], [1, 2, 3])
    end

    test "true when local is componentwise dominated" do
      assert VC.happens_before_or_equal?([1, 2, 0], [1, 2, 3])
      assert VC.happens_before_or_equal?([0, 0, 0], [1, 1, 1])
    end

    test "false on concurrent pairs that the old sum-based check confused" do
      refute VC.happens_before_or_equal?([2, 0], [0, 2])
      refute VC.happens_before_or_equal?([0, 2], [2, 0])
    end
  end

  describe "happens_before?/2" do
    test "strict: not reflexive" do
      refute VC.happens_before?([1, 2, 3], [1, 2, 3])
    end

    test "strict requires at least one component to advance" do
      assert VC.happens_before?([1, 2, 0], [1, 2, 1])
      refute VC.happens_before?([1, 2, 1], [1, 2, 0])
    end
  end

  describe "concurrent?/2" do
    test "classic concurrent pair that sum-based comparison missed" do
      assert VC.concurrent?([2, 0], [0, 2])
    end

    test "ordered pairs are not concurrent" do
      refute VC.concurrent?([1, 1], [1, 2])
      refute VC.concurrent?([1, 2], [1, 1])
      refute VC.concurrent?([1, 1], [1, 1])
    end
  end

  describe "total_order_with_tiebreak?/3" do
    test "respects causal order when present" do
      assert VC.total_order_with_tiebreak?([1, 0], [1, 1], 1)
      refute VC.total_order_with_tiebreak?([1, 1], [1, 0], 0)
    end

    test "uses incoming peer id when concurrent" do
      # local origin (peer 0 has the max tick) ≤ incoming peer id 1 → true
      assert VC.total_order_with_tiebreak?([2, 0], [0, 2], 1)
      # local origin (peer 1) > incoming peer id 0 → false
      refute VC.total_order_with_tiebreak?([0, 2], [2, 0], 0)
    end
  end
end
