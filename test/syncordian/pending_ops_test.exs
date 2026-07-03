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
        |> P.suspend(:a, :progress, 0)
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
    test "releases when the awaited line is added" do
      buf = P.suspend(P.new(), :del, {:line, :l7}, 0)
      assert {[:del], buf} = P.release(buf, {:line_added, :l7})
      assert P.size(buf) == 0
    end

    test "a different line does not release" do
      buf = P.suspend(P.new(), :del, {:line, :l7}, 0)
      assert {[], buf} = P.release(buf, {:line_added, :l8})
      assert P.size(buf) == 1
    end
  end

  describe "release/2 — vc_ready dependency (clock-gated inserts)" do
    test "releases only when the local clock dominates the sender's view" do
      # Insert from sender 1 authored at vc [2, 3, 1]: deliverable once the local clock
      # reaches 2 on component 0, 3-1 = 2 on the sender's own component, and 1 on
      # component 2 (the insert itself provides the sender's final tick).
      buf = P.suspend(P.new(), :ins, {:vc_ready, [2, 3, 1], 1}, 0)

      # Missing causal context on component 0: not released.
      assert {[], buf} = P.release(buf, {:clock_now, [1, 2, 1]})
      assert P.size(buf) == 1

      # Sender's own component only needs incoming - 1.
      assert {[:ins], buf} = P.release(buf, {:clock_now, [2, 2, 1]})
      assert P.size(buf) == 0
    end

    test "vc_ready waiters ignore other event kinds" do
      buf = P.suspend(P.new(), :ins, {:vc_ready, [1, 1], 0}, 0)
      assert {[], buf} = P.release(buf, :progress)
      assert {[], buf} = P.release(buf, {:clock_advanced, 0, 5})
      assert P.size(buf) == 1
    end
  end

  describe "release/2 — progress dependency and event isolation" do
    test "progress entries release only on a progress event" do
      buf = P.suspend(P.new(), :p, :progress, 0)

      # Clock and line events do not touch a :progress waiter.
      assert {[], buf} = P.release(buf, {:clock_advanced, 0, 100})
      assert {[], buf} = P.release(buf, {:line_added, :l1})
      assert P.size(buf) == 1

      assert {[:p], buf} = P.release(buf, :progress)
      assert P.size(buf) == 0
    end

    test "an event only matches its own dependency kind" do
      buf =
        P.new()
        |> P.suspend(:clock_waiter, {:clock, 1, 1}, 0)
        |> P.suspend(:line_waiter, {:line, :l1}, 0)
        |> P.suspend(:progress_waiter, :progress, 0)

      assert {[:line_waiter], buf} = P.release(buf, {:line_added, :l1})
      assert P.size(buf) == 2
    end
  end

  describe "release/2 — ordering" do
    test "ready payloads are returned in FIFO suspension order" do
      buf =
        P.new()
        |> P.suspend(:first, :progress, 0)
        |> P.suspend(:second, :progress, 0)
        |> P.suspend(:third, :progress, 0)

      assert {[:first, :second, :third], _buf} = P.release(buf, :progress)
    end
  end

  describe "gc/3 — liveness backstop" do
    test "drops entries older than the horizon, keeps the rest" do
      buf =
        P.new()
        |> P.suspend(:stale, :progress, 0)
        |> P.suspend(:fresh, :progress, 8)

      # At edit 10 with horizon 5: :stale waited 10 (> 5, dropped), :fresh waited 2 (kept).
      assert {1, buf} = P.gc(buf, 10, 5)
      assert P.size(buf) == 1
      assert {[:fresh], _} = P.release(buf, :progress)
    end

    test "an entry exactly at the horizon is retained" do
      buf = P.suspend(P.new(), :edge, :progress, 0)
      assert {0, buf} = P.gc(buf, 5, 5)
      assert P.size(buf) == 1
    end

    test "nothing is dropped when all entries are within the horizon" do
      buf =
        P.new()
        |> P.suspend(:a, :progress, 9)
        |> P.suspend(:b, :progress, 10)

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
