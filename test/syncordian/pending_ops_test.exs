defmodule Syncordian.PendingOpsTest do
  use ExUnit.Case, async: true

  alias Syncordian.PendingOps, as: P

  doctest Syncordian.PendingOps

  describe "suspend/4 and size/1" do
    test "a fresh buffer is empty" do
      assert P.size(P.new()) == 0
    end

    test "each suspend grows the buffer" do
      buf =
        P.new()
        |> P.suspend(:a, {:clock, 1, 1}, 0)
        |> P.suspend(:b, {:line, :l1}, 0)

      assert P.size(buf) == 2
    end
  end

  describe "release/2 — clock dependency" do
    test "releases only when the advanced value reaches the needed threshold" do
      buf = P.suspend(P.new(), :a, {:clock, 2, 3}, 0)

      # Advancing below the threshold releases nothing.
      assert {[], buf} = P.release(buf, {:clock_advanced, 2, 2})
      assert P.size(buf) == 1

      # Reaching (or exceeding) the threshold releases the op.
      assert {[:a], buf} = P.release(buf, {:clock_advanced, 2, 3})
      assert P.size(buf) == 0
    end

    test "a clock event for a different sender does not release" do
      buf = P.suspend(P.new(), :a, {:clock, 2, 1}, 0)
      assert {[], buf} = P.release(buf, {:clock_advanced, 5, 9})
      assert P.size(buf) == 1
    end
  end

  describe "release/2 — line dependency" do
    test "releases when the awaited line is added, keyed by a line_id" do
      buf = P.suspend(P.new(), :del, {:line, :l7}, 0)
      assert {[:del], buf} = P.release(buf, {:line_added, :l7})
      assert P.size(buf) == 0
    end

    test "releases when the awaited parent is added, keyed by an op_id" do
      # An insert waits on one of its authored parents by that parent's op_id; a delete
      # waits on its target the same way. Both are woken by {:line_added, op_id}.
      buf = P.suspend(P.new(), :ins, {:line, {3, 7}}, 0)
      assert {[:ins], buf} = P.release(buf, {:line_added, {3, 7}})
      assert P.size(buf) == 0
    end

    test "a different line/op_id does not release" do
      buf = P.suspend(P.new(), :del, {:line, :l7}, 0)
      assert {[], buf} = P.release(buf, {:line_added, :l8})
      assert P.size(buf) == 1
    end
  end

  describe "release/2 — event isolation" do
    test "an event only matches its own dependency kind" do
      buf =
        P.new()
        |> P.suspend(:clock_waiter, {:clock, 1, 1}, 0)
        |> P.suspend(:line_waiter, {:line, :l1}, 0)

      # A line event leaves the clock waiter untouched.
      assert {[:line_waiter], buf} = P.release(buf, {:line_added, :l1})
      assert P.size(buf) == 1

      # A clock event leaves nothing else to touch.
      assert {[:clock_waiter], buf} = P.release(buf, {:clock_advanced, 1, 1})
      assert P.size(buf) == 0
    end

    test "line waiters ignore clock events and vice versa" do
      buf = P.suspend(P.new(), :ins, {:line, {0, 1}}, 0)
      assert {[], buf} = P.release(buf, {:clock_advanced, 0, 5})
      assert P.size(buf) == 1
    end
  end

  describe "release/2 — ordering" do
    test "ready payloads are returned in FIFO suspension order" do
      # Three ops waiting on the same line are all released together, oldest first.
      buf =
        P.new()
        |> P.suspend(:first, {:line, :same}, 0)
        |> P.suspend(:second, {:line, :same}, 0)
        |> P.suspend(:third, {:line, :same}, 0)

      assert {[:first, :second, :third], _buf} = P.release(buf, {:line_added, :same})
    end
  end

  describe "gc/3 — liveness backstop" do
    test "drops entries older than the horizon, keeps the rest" do
      buf =
        P.new()
        |> P.suspend(:stale, {:line, :l1}, 0)
        |> P.suspend(:fresh, {:line, :l2}, 8)

      # At edit 10 with horizon 5: :stale waited 10 (> 5, dropped), :fresh waited 2 (kept).
      assert {1, buf} = P.gc(buf, 10, 5)
      assert P.size(buf) == 1
      assert {[:fresh], _} = P.release(buf, {:line_added, :l2})
    end

    test "an entry exactly at the horizon is retained" do
      buf = P.suspend(P.new(), :edge, {:line, :l1}, 0)
      assert {0, buf} = P.gc(buf, 5, 5)
      assert P.size(buf) == 1
    end

    test "nothing is dropped when all entries are within the horizon" do
      buf =
        P.new()
        |> P.suspend(:a, {:clock, 1, 2}, 9)
        |> P.suspend(:b, {:clock, 1, 3}, 10)

      assert {0, buf} = P.gc(buf, 10, 5)
      assert P.size(buf) == 2
    end
  end

  describe "end-to-end: an honest op is released exactly when its dependency fires" do
    test "causal-gap insert waits for the sender's preceding edit then is released once" do
      payload = {:receive_insert_broadcast, :line, [0, 0, 3]}
      # Sender is peer 2, op needs local[2] to reach 2 (incoming[2] - 1).
      buf = P.suspend(P.new(), payload, {:clock, 2, 2}, 0)

      # Intermediate applies that do not reach the threshold keep it suspended.
      assert {[], buf} = P.release(buf, {:clock_advanced, 2, 1})
      assert P.size(buf) == 1

      # The apply that brings local[2] to 2 releases it exactly once.
      assert {[^payload], buf} = P.release(buf, {:clock_advanced, 2, 2})
      assert P.size(buf) == 0

      # It is gone: a later event does not re-release it.
      assert {[], _} = P.release(buf, {:clock_advanced, 2, 3})
    end
  end
end
