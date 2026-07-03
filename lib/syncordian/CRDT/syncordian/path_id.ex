defmodule Syncordian.PathId do
  @moduledoc """
  Dense, totally-ordered position identifiers for Syncordian lines.

  Replaces the previous floating-point line-id scheme. A floating-point identifier
  exhausts precision after a bounded number of midpoint allocations between adjacent
  positions; a path identifier is variable-length and can always represent a fresh
  position strictly between any two existing positions.

  A `t/0` is one of:

    * `:infimum` — the bottom sentinel; sorts strictly less than every other path.
    * `:supremum` — the top sentinel; sorts strictly greater than every other path.
    * `{:path, segments}` where `segments` is a non-empty list of `{digit, peer_id}`
      tuples. `digit` is a non-negative integer drawn from `[0, base())`. `peer_id`
      is the id of the peer that allocated that segment (the global tiebreaker).

  Comparison is lexicographic over segments, with each segment compared as the tuple
  `{digit, peer_id}` (digit first, peer_id second). A path that is a strict prefix of
  another sorts *before* its extension. Two segment lists of equal length and equal
  contents are equal.

  ## Allocation

  `between/3` produces a fresh path strictly between two existing paths. It walks the
  shared prefix, then either picks a digit between the two diverging segments or
  extends the smaller path by one segment. The chosen digit is drawn uniformly at
  random from the available range `[lo, hi]` (see `pick_digit/2`).

  This module is pure and side-effect-free aside from `:rand.uniform/1` inside
  `between/3`. It does not depend on the rest of the codebase.

  ## Totality (dense order, def:positions)

  The formal model requires the position order to be dense: `between/3` must succeed for
  *every* pair `left < right`. The `(digit, peer_id)` lexicographic encoding has one
  structurally tight corner: right = `prefix ++ [{0, p}]` where the allocating peer's
  tiebreak id cannot undercut `p`. Two measures make allocation total anyway:

    * Minted segments store the allocating peer's id **shifted by one** (`peer_id + 1`),
      reserving `0` as a virtual-minimum tiebreak id that no real peer owns. Every
      tiebreak wall `{0, p}` written by the allocator therefore has `p >= 1`, so an id
      strictly below it always exists.
    * In the tight corner the allocator descends with the reserved id: it emits
      `prefix ++ [{0, p - 1}, {digit, own_shifted_id}]`, strictly between the bounds,
      with the final segment still carrying the minting peer's identity.

  Two distinct peers can never mint the same path (the last segment carries their
  distinct shifted ids). The same peer minting twice between the same bounds can, with
  probability `1/base()` per level, collide with itself; document order stays sound
  because `Syncordian.Line.compare_lines/2` breaks equal positions by the lines'
  authored identity (the ⋖ tiebreak of the formal model).
  """

  alias Syncordian.Basic_Types

  @type peer_id :: Basic_Types.peer_id()
  @type segment :: {non_neg_integer(), peer_id()}
  @type t :: :infimum | :supremum | {:path, [segment(), ...]}

  @base 65_536
  @doc "Digit alphabet upper bound (exclusive). Segments use digits in `[0, base())`."
  def base, do: @base

  @doc "Returns the bottom sentinel."
  @spec infimum() :: t
  def infimum, do: :infimum

  @doc "Returns the top sentinel."
  @spec supremum() :: t
  def supremum, do: :supremum

  @doc """
  Returns true iff `t` is one of the two boundary sentinels.
  """
  @spec sentinel?(t) :: boolean
  def sentinel?(:infimum), do: true
  def sentinel?(:supremum), do: true
  def sentinel?({:path, _}), do: false

  @doc """
  Three-way comparison: returns `:lt`, `:eq`, or `:gt`.

  ## Examples

      iex> alias Syncordian.PathId, as: P
      iex> P.compare(P.infimum(), P.supremum())
      :lt
      iex> P.compare({:path, [{1, 0}]}, {:path, [{1, 0}]})
      :eq
      iex> P.compare({:path, [{1, 0}]}, {:path, [{1, 0}, {0, 0}]})
      :lt
      iex> P.compare({:path, [{2, 0}]}, {:path, [{1, 5}]})
      :gt
  """
  @spec compare(t, t) :: :lt | :eq | :gt
  def compare(a, a), do: :eq
  def compare(:infimum, _), do: :lt
  def compare(_, :infimum), do: :gt
  def compare(:supremum, _), do: :gt
  def compare(_, :supremum), do: :lt
  def compare({:path, a}, {:path, b}), do: compare_segments(a, b)

  defp compare_segments([], []), do: :eq
  defp compare_segments([], _), do: :lt
  defp compare_segments(_, []), do: :gt

  defp compare_segments([{da, pa} | ra], [{db, pb} | rb]) do
    cond do
      da < db -> :lt
      da > db -> :gt
      pa < pb -> :lt
      pa > pb -> :gt
      true -> compare_segments(ra, rb)
    end
  end

  @doc """
  Returns true iff `a < b` in the total order.
  """
  @spec less?(t, t) :: boolean
  def less?(a, b), do: compare(a, b) == :lt

  @doc """
  Allocates a fresh path strictly between `left` and `right`, attributing the new
  segment(s) to `peer_id`. Caller must guarantee `compare(left, right) == :lt`.

  When the two paths have room at the divergence point (their digits differ by more
  than one) the new path picks a digit between them and stops. When there is no room,
  the allocator extends the smaller side by one segment so the new path is strictly
  greater than that side and (vacuously) less than the right side at the divergence
  level.

  ## Examples

      iex> alias Syncordian.PathId, as: P
      iex> :rand.seed(:exsplus, {1, 2, 3})
      iex> new = P.between(P.infimum(), P.supremum(), 7)
      iex> P.less?(P.infimum(), new) and P.less?(new, P.supremum())
      true

      iex> alias Syncordian.PathId, as: P
      iex> :rand.seed(:exsplus, {1, 2, 3})
      iex> left = {:path, [{5, 0}]}
      iex> right = {:path, [{5, 0}, {1, 0}]}
      iex> new = P.between(left, right, 9)
      iex> P.less?(left, new) and P.less?(new, right)
      true
  """
  @spec between(t, t, peer_id) :: t
  def between(left, right, peer_id) do
    case compare(left, right) do
      :lt ->
        # Segments store the shifted id (peer_id + 1); 0 is the reserved
        # virtual-minimum tiebreak id that keeps allocation total (see module doc).
        do_between(normalize(left), normalize(right), peer_id + 1, [])

      _ ->
        raise ArgumentError,
              "between/3 requires left < right; got compare/2 = " <>
                inspect(compare(left, right)) <>
                " for left=" <> inspect(left) <> " right=" <> inspect(right)
    end
  end

  # Treat the sentinels as half-bounded segment streams. The infimum acts as the
  # empty segment list with no upper bound on what can be appended; the supremum
  # acts as a stream of `{base, ∞}` segments greater than anything we can append.
  defp normalize(:infimum), do: {:bound, :low}
  defp normalize(:supremum), do: {:bound, :high}
  defp normalize({:path, segs}), do: {:segs, segs}

  defp do_between({:bound, :low}, {:bound, :high}, peer_id, _prefix) do
    digit = pick_digit(0, @base - 1)
    {:path, [{digit, peer_id}]}
  end

  defp do_between({:bound, :low}, {:segs, [{r_digit, r_peer} | r_rest]}, peer_id, prefix) do
    cond do
      r_digit > 0 ->
        digit = pick_digit(0, r_digit - 1)
        finish(prefix, {digit, peer_id})

      # r_digit == 0; we need a tiebreaker below (0, r_peer) at this level.
      peer_id < r_peer ->
        finish(prefix, {0, peer_id})

      r_rest != [] ->
        # No room at this level; descend along right.
        do_between({:bound, :low}, {:segs, r_rest}, peer_id, [{0, r_peer} | prefix])

      true ->
        # Tight corner: our shifted id cannot undercut {0, r_peer} at this level and
        # right has no further segments to descend along. Emit the reserved-id fallback
        # {0, r_peer - 1} (r_peer >= 1 for every allocator-minted wall, so this exists
        # and no real peer owns it) and finish one level deeper with our own id —
        # strictly between the bounds, identity preserved in the last segment.
        fallback_below(prefix, r_peer, peer_id)
    end
  end

  defp do_between({:segs, []}, {:bound, :high}, peer_id, prefix) do
    digit = pick_digit(0, @base - 1)
    finish(prefix, {digit, peer_id})
  end

  defp do_between({:segs, [{l_digit, _} | _]}, {:bound, :high}, peer_id, prefix)
       when l_digit < @base - 1 do
    digit = pick_digit(l_digit + 1, @base - 1)
    finish(prefix, {digit, peer_id})
  end

  defp do_between({:segs, [{l_digit, l_peer} | l_rest]}, {:bound, :high}, peer_id, prefix) do
    # l_digit is the maximum digit; cannot pick anything greater at this level.
    # Descend down the left side and keep choosing > l beyond it.
    do_between({:segs, l_rest}, {:bound, :high}, peer_id, [{l_digit, l_peer} | prefix])
  end

  defp do_between({:segs, []}, {:segs, []}, _peer_id, _prefix),
    do:
      raise(ArgumentError, "do_between/4 reached identical paths — caller violated left < right")

  defp do_between({:segs, []}, {:segs, [{r_digit, r_peer} | r_rest]}, peer_id, prefix) do
    cond do
      r_digit > 0 ->
        digit = pick_digit(0, r_digit - 1)
        finish(prefix, {digit, peer_id})

      # r_digit == 0; same shape as the `{:bound, :low}` symmetric case.
      peer_id < r_peer ->
        finish(prefix, {0, peer_id})

      r_rest != [] ->
        do_between({:segs, []}, {:segs, r_rest}, peer_id, [{0, r_peer} | prefix])

      true ->
        # Same tight corner as the {:bound, :low} case above.
        fallback_below(prefix, r_peer, peer_id)
    end
  end

  defp do_between({:segs, [{l_digit, _} | _]}, {:segs, []}, _peer_id, _prefix)
       when l_digit >= 0,
       do:
         raise(
           ArgumentError,
           "do_between/4: right path is a prefix of left; caller violated left < right"
         )

  defp do_between(
         {:segs, [{l_digit, l_peer} | l_rest]},
         {:segs, [{r_digit, r_peer} | r_rest]},
         peer_id,
         prefix
       ) do
    cond do
      l_digit + 1 < r_digit ->
        digit = pick_digit(l_digit + 1, r_digit - 1)
        finish(prefix, {digit, peer_id})

      l_digit == r_digit and l_peer == r_peer ->
        do_between(
          {:segs, l_rest},
          {:segs, r_rest},
          peer_id,
          [{l_digit, l_peer} | prefix]
        )

      l_digit == r_digit ->
        # Same digit, different peer. Tuple ordering gives l_peer < r_peer (precondition).
        # We need to descend on the left side, since the next segment is what makes the
        # left smaller, and any extension of that segment stays below right at this depth.
        do_between(
          {:segs, l_rest},
          {:bound, :high},
          peer_id,
          [{l_digit, l_peer} | prefix]
        )

      true ->
        # l_digit + 1 == r_digit: adjacent digits, no room at this level. Descend on the
        # left side — anything appended to it stays above (l, l_peer) and below
        # (r, r_peer).
        do_between(
          {:segs, l_rest},
          {:bound, :high},
          peer_id,
          [{l_digit, l_peer} | prefix]
        )
    end
  end

  defp finish(prefix, segment), do: {:path, Enum.reverse([segment | prefix])}

  # Total-allocation fallback for the tight corner (see "Totality" in the module doc):
  # right = reverse(prefix) ++ [{0, r_peer}] and our shifted id cannot undercut r_peer.
  # reverse(prefix) ++ [{0, r_peer - 1}, {d, sid}] is strictly greater than every left
  # bound compatible with this corner (any proper prefix of right) and strictly less
  # than right at the {0, r_peer - 1} segment.
  defp fallback_below(prefix, r_peer, shifted_id) do
    digit = pick_digit(0, @base - 1)
    {:path, Enum.reverse([{digit, shifted_id}, {0, r_peer - 1} | prefix])}
  end

  # Pick a digit uniformly in `[lo, hi]`. Used only inside the allocator.
  defp pick_digit(lo, hi) when lo == hi, do: lo

  defp pick_digit(lo, hi) when lo < hi do
    span = hi - lo + 1
    lo + :rand.uniform(span) - 1
  end

  @doc """
  Human-readable rendering for debug output and serialization.

  ## Examples

      iex> alias Syncordian.PathId, as: P
      iex> P.to_string(P.infimum())
      "<inf>"
      iex> P.to_string(P.supremum())
      "<sup>"
      iex> P.to_string({:path, [{12, 3}, {7, 0}]})
      "12.3/7.0"
  """
  @spec to_string(t) :: String.t()
  def to_string(:infimum), do: "<inf>"
  def to_string(:supremum), do: "<sup>"

  def to_string({:path, segs}) do
    segs
    |> Enum.map(fn {d, p} -> "#{d}.#{p}" end)
    |> Enum.join("/")
  end
end
