defmodule Syncordian.Vector_Clock do
  @moduledoc """
    Vector clock predicates and distance heuristics for Syncordian.

    The partial-order predicates (`happens_before?/2`, `happens_before_or_equal?/2`,
    `concurrent?/2`, `equal?/2`) implement the standard component-wise vector-clock
    ordering: `L ≤ I` iff `L[i] ≤ I[i]` for every component `i`. Strict happens-before
    additionally requires `L ≠ I`.

    `total_order_with_tiebreak?/3` lifts the partial order to a total order by breaking
    concurrent pairs deterministically with the incoming peer id.

    The earlier `order_vector_clocks_definition/2`, which compared the sums of the two
    vectors, was unsound because vectors such as `[2,0]` and `[0,2]` are causally
    incomparable yet share the same sum. Call sites that previously called it should now
    use `happens_before_or_equal?/2`.

    `projection_distance/2` and `distance_between_vector_clocks/3` are *heuristics* used
    for stash-window sizing and approximate dependency estimation. They do not encode a
    partial order and must not be used as such. A proper dependency-based requeue
    mechanism is tracked under workstream A3 of the revision roadmap.
  """

  alias Syncordian.Basic_Types

  @typep vc :: Basic_Types.vector_clock()

  @doc """
    Pointwise equality.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.equal?([1, 2, 3], [1, 2, 3])
        true
        iex> VC.equal?([1, 2, 3], [1, 2, 4])
        false
  """
  @spec equal?(vc, vc) :: boolean
  def equal?(local_vc, incoming_vc), do: local_vc == incoming_vc

  @doc """
    Component-wise `≤`. Returns true iff every component of `local_vc` is less than or
    equal to the corresponding component of `incoming_vc`.

    Note that this is the partial-order relation: it is reflexive but not total.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.happens_before_or_equal?([1, 2, 3], [1, 2, 3])
        true
        iex> VC.happens_before_or_equal?([1, 2, 0], [1, 2, 3])
        true
        iex> VC.happens_before_or_equal?([2, 0], [0, 2])
        false
        iex> VC.happens_before_or_equal?([0, 2], [2, 0])
        false
  """
  @spec happens_before_or_equal?(vc, vc) :: boolean
  def happens_before_or_equal?(local_vc, incoming_vc) do
    Enum.zip(local_vc, incoming_vc)
    |> Enum.all?(fn {l, i} -> l <= i end)
  end

  @doc """
    Strict happens-before: `local_vc < incoming_vc` in the vector-clock partial order.

    True iff `local_vc ≤ incoming_vc` componentwise *and* the two vectors differ.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.happens_before?([1, 2, 0], [1, 2, 3])
        true
        iex> VC.happens_before?([1, 2, 3], [1, 2, 3])
        false
        iex> VC.happens_before?([2, 0], [0, 2])
        false
  """
  @spec happens_before?(vc, vc) :: boolean
  def happens_before?(local_vc, incoming_vc) do
    happens_before_or_equal?(local_vc, incoming_vc) and local_vc != incoming_vc
  end

  @doc """
    Concurrent: neither `local_vc ≤ incoming_vc` nor `incoming_vc ≤ local_vc`.

    Captures the case the previous sum-based comparison silently misclassified: e.g.
    `[2,0]` and `[0,2]` have equal sums but represent causally incomparable histories.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.concurrent?([2, 0], [0, 2])
        true
        iex> VC.concurrent?([1, 2, 3], [1, 2, 3])
        false
        iex> VC.concurrent?([1, 2, 0], [1, 2, 3])
        false
  """
  @spec concurrent?(vc, vc) :: boolean
  def concurrent?(local_vc, incoming_vc) do
    not happens_before_or_equal?(local_vc, incoming_vc) and
      not happens_before_or_equal?(incoming_vc, local_vc)
  end

  @doc """
    Total order that extends the partial order with a deterministic tiebreaker on the
    incoming peer id. Returns true iff `local_vc` should sort at or before the incoming
    event.

    Rules:
      * if `local_vc ≤ incoming_vc` → true
      * if `incoming_vc < local_vc` → false
      * if concurrent → fall back to peer-id tiebreak (true iff the local origin id is
        ≤ the incoming peer id; this assumes the caller passes the *incoming* peer id).

    The tiebreaker is only sound for deciding the apply-order of two operations that the
    callee has already determined to be concurrent; it must not be read as causal order.
  """
  @spec total_order_with_tiebreak?(vc, vc, Basic_Types.peer_id()) :: boolean
  def total_order_with_tiebreak?(local_vc, incoming_vc, incoming_peer_id) do
    cond do
      happens_before_or_equal?(local_vc, incoming_vc) -> true
      happens_before?(incoming_vc, local_vc) -> false
      true -> local_origin_id(local_vc) <= incoming_peer_id
    end
  end

  defp local_origin_id(local_vc) do
    local_vc
    |> Enum.with_index()
    |> Enum.max_by(fn {tick, _idx} -> tick end)
    |> elem(1)
  end

  @doc """
    Heuristic stash-window size: the L1 distance between two vector clocks. Used by the
    document module to pick a search window when reconciling a stashed line; not a
    partial-order test.

    The `0 → Enum.sum(local_vc)` fallback preserves legacy behaviour where a zero L1
    distance still triggers stash search; see A3 for the planned dependency-based
    replacement.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.projection_distance([1, 2, 3], [1, 2, 3])
        6
        iex> VC.projection_distance([1, 2, 0], [1, 2, 3])
        3
        iex> VC.projection_distance([1, 2, 0], [10, 3, 0])
        10
  """
  @spec projection_distance(vc, vc) :: integer
  def projection_distance(local_vc, incoming_vc) do
    l1 =
      Enum.zip_reduce(local_vc, incoming_vc, 0, fn l, i, acc ->
        acc + abs(l - i)
      end)

    case l1 do
      0 -> Enum.sum(local_vc)
      _ -> l1
    end
  end

  @doc """
    Absolute difference between the two vector clocks at a single component (the
    incoming peer's position). Used by the insert dispatcher as a coarse
    sender-progress proxy. Not a partial-order test; see A3 for the planned causal
    deliverability check.

    ## Examples
        iex> alias Syncordian.Vector_Clock, as: VC
        iex> VC.distance_between_vector_clocks([1, 2, 3], [1, 2, 3], 0)
        0
        iex> VC.distance_between_vector_clocks([1, 2, 0], [1, 2, 3], 2)
        3
        iex> VC.distance_between_vector_clocks([1, 2, 0], [0, 3, 0], 1)
        1
  """
  @spec distance_between_vector_clocks(vc, vc, integer) :: integer
  def distance_between_vector_clocks(local_vc, incoming_vc, incoming_peer_position) do
    abs(
      Enum.at(local_vc, incoming_peer_position) -
        Enum.at(incoming_vc, incoming_peer_position)
    )
  end
end
