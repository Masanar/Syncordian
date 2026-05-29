defmodule Syncordian.SeenOpsTest do
  use ExUnit.Case, async: true

  alias Syncordian.SeenOps, as: S

  doctest Syncordian.SeenOps

  describe "new/0, record/2, seen?/2, size/1" do
    test "a fresh set has seen nothing" do
      refute S.seen?(S.new(), {1, 0})
      assert S.size(S.new()) == 0
    end

    test "an op is seen after it is recorded" do
      seen = S.record(S.new(), {3, 5})
      assert S.seen?(seen, {3, 5})
      assert S.size(seen) == 1
    end

    test "distinct op-ids are tracked independently" do
      seen =
        S.new()
        |> S.record({1, 0})
        |> S.record({1, 1})
        |> S.record({2, 0})

      assert S.seen?(seen, {1, 0})
      assert S.seen?(seen, {1, 1})
      assert S.seen?(seen, {2, 0})
      refute S.seen?(seen, {2, 1})
      assert S.size(seen) == 3
    end

    test "recording the same op-id twice is idempotent" do
      seen = S.new() |> S.record({4, 9}) |> S.record({4, 9})
      assert S.size(seen) == 1
    end
  end

  describe "rotate/3 — generational epoch GC" do
    test "no rotation before the epoch boundary" do
      seen = S.new() |> S.record({1, 0})
      seen = S.rotate(seen, 5, 10)
      assert S.seen?(seen, {1, 0})
      assert S.size(seen) == 1
    end

    test "an op survives exactly one rotation (moved to the previous generation)" do
      seen = S.new() |> S.record({1, 0}) |> S.rotate(10, 10)
      assert S.seen?(seen, {1, 0})
    end

    test "an op is evicted after two rotations" do
      seen =
        S.new()
        |> S.record({1, 0})
        |> S.rotate(10, 10)
        |> S.rotate(20, 10)

      refute S.seen?(seen, {1, 0})
    end

    test "ops recorded in the new generation are retained after the next rotation" do
      seen =
        S.new()
        |> S.record({1, 0})
        |> S.rotate(10, 10)
        # {1, 0} now in `previous`; {2, 0} lands in the fresh `current`.
        |> S.record({2, 0})
        |> S.rotate(20, 10)

      # {1, 0} evicted, {2, 0} demoted to `previous` and still seen.
      refute S.seen?(seen, {1, 0})
      assert S.seen?(seen, {2, 0})
    end

    test "memory stays bounded to two epochs of records under repeated rotation" do
      # Record one op per epoch across many epochs; the set never holds more than the two
      # most recent generations' worth of op-ids.
      seen =
        Enum.reduce(1..100, S.new(), fn e, acc ->
          acc
          |> S.record({0, e})
          |> S.rotate(e * 10, 10)
        end)

      assert S.size(seen) <= 2
      # The newest op is still remembered; an ancient one is long gone.
      assert S.seen?(seen, {0, 100})
      refute S.seen?(seen, {0, 1})
    end
  end

  describe "replay semantics modelled on the peer's seen-set" do
    test "a duplicate op-id is recognised as already seen (a replay)" do
      op = {7, 42}
      seen = S.record(S.new(), op)

      # The same op delivered again is a replay: still seen, dropped by the peer.
      assert S.seen?(seen, op)

      # A genuinely new op from the same sender is not a replay.
      refute S.seen?(seen, {7, 43})
    end

    test "a replay is still caught while its original is within the retention window" do
      op = {7, 42}

      seen =
        S.new()
        |> S.record(op)
        # One rotation keeps the original reachable in `previous`.
        |> S.rotate(10, 10)

      assert S.seen?(seen, op)
    end
  end
end
