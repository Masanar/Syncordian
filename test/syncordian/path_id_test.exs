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

    test "subdivision survives far longer than a float-PID would" do
      # Regression bar: this stress loop randomly halves the interval and asserts
      # that the path-id allocator returns a strictly-between path on each call.
      # The (digit, peer_id) encoding eventually saturates at the leftmost boundary
      # (see "Tiebreaker exhaustion" in the PathId moduledoc) and `between/3`
      # raises `ArgumentError`; we treat the first raise as a graceful stop and
      # assert that the allocator survived a large number of iterations first —
      # comfortably more than the ~50 levels of subdivision a 64-bit float can
      # represent.
      :rand.seed(:exsplus, {99, 99, 99})

      result =
        Enum.reduce_while(1..10_000, {0, P.infimum(), P.supremum()}, fn _i, {count, l, r} ->
          try do
            mid = P.between(l, r, :rand.uniform(1_000_000))

            cond do
              not P.less?(l, mid) ->
                {:halt, {:invariant_violated, count, :left, l, mid}}

              not P.less?(mid, r) ->
                {:halt, {:invariant_violated, count, :right, mid, r}}

              true ->
                next =
                  if rem(:rand.uniform(1000), 2) == 0,
                    do: {count + 1, l, mid},
                    else: {count + 1, mid, r}

                {:cont, next}
            end
          rescue
            ArgumentError -> {:halt, {:saturated, count}}
          end
        end)

      iterations =
        case result do
          {:saturated, n} -> n
          {count, _l, _r} -> count
          {:invariant_violated, _, _, _, _} -> 0
        end

      refute match?({:invariant_violated, _, _, _, _}, result),
             "between/3 returned a non-strictly-between path: #{inspect(result)}"

      # A 64-bit float can subdivide ~52 times before mantissa precision is exhausted.
      # We require the path-id allocator to comfortably exceed that under this
      # adversarial random-halving pattern.
      assert iterations >= 100,
             "expected >=100 successful subdivisions before saturation; got #{iterations} (result=#{inspect(result)})"
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
