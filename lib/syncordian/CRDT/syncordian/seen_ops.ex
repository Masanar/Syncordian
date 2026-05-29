defmodule Syncordian.SeenOps do
  @moduledoc """
  Bounded set of operation identifiers already applied by a peer, used to reject replays.

  Every insert/delete operation is stamped at its origin with an `op_id`
  `{peer_id, op_seq}` — a per-peer monotonic sequence number — that travels unchanged in the
  broadcast message. A receiver records an `op_id` the moment it *applies* the operation; a
  later message carrying an already-recorded `op_id` is a duplicate (a replay) and is dropped
  without effect. Recording on apply — rather than on receipt — is deliberate: an operation
  that is received but only *suspended* (not yet deliverable, see `Syncordian.PendingOps`)
  must still be processable when its dependency arrives, so it is not yet considered seen.
  This also means a Byzantine copy that is rejected (\\eg a forged signature) is never
  recorded, so the genuine operation that follows is not mistaken for a replay.

  ## Bounded memory: generational epoch GC

  An unbounded set would grow without limit. Instead the set keeps two generations,
  `current` and `previous`. An `op_id` is *seen* if it is in either. After the peer applies
  `epoch_size` edits, `rotate/3` discards `previous`, promotes `current` to `previous`, and
  starts a fresh empty `current`. Memory is therefore bounded by the number of distinct
  operations applied within the last two epochs, while any replay whose original was applied
  within the current or previous epoch is still detected. A replay older than that window is
  caught instead by the downstream signature / progress-vector checks — the referenced line
  already exists (insert) or the operation is causally in the past — so evicting it from the
  set is safe.

  This module is pure and side-effect-free; the peer loop owns all state threading.
  """

  alias Syncordian.Basic_Types

  @type op_id :: Basic_Types.op_id()

  @opaque t :: %__MODULE__{
            current: MapSet.t(op_id()),
            previous: MapSet.t(op_id()),
            epoch_start: non_neg_integer()
          }

  defstruct current: MapSet.new(), previous: MapSet.new(), epoch_start: 0

  @doc """
  Returns an empty seen-set.

  ## Examples

      iex> Syncordian.SeenOps.seen?(Syncordian.SeenOps.new(), {1, 0})
      false
  """
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  Whether `op_id` has been applied within the current or previous epoch.

  ## Examples

      iex> alias Syncordian.SeenOps, as: S
      iex> S.new() |> S.record({2, 7}) |> S.seen?({2, 7})
      true
  """
  @spec seen?(t, op_id()) :: boolean()
  def seen?(%__MODULE__{current: c, previous: p}, op_id),
    do: MapSet.member?(c, op_id) or MapSet.member?(p, op_id)

  @doc """
  Records `op_id` in the current epoch.

  ## Examples

      iex> alias Syncordian.SeenOps, as: S
      iex> S.new() |> S.record({2, 7}) |> S.size()
      1
  """
  @spec record(t, op_id()) :: t
  def record(%__MODULE__{current: c} = s, op_id),
    do: %{s | current: MapSet.put(c, op_id)}

  @doc "Number of op-ids currently retained, across both generations."
  @spec size(t) :: non_neg_integer()
  def size(%__MODULE__{current: c, previous: p}),
    do: MapSet.size(c) + MapSet.size(p)

  @doc """
  Rotates the generations once at least `epoch_size` edits have been applied since the last
  rotation, \\ie when `edit_count - epoch_start >= epoch_size`: `previous` is discarded,
  `current` becomes `previous`, and a fresh empty `current` is started at `edit_count`. It is
  a no-op before the boundary is reached.

  ## Examples

      iex> alias Syncordian.SeenOps, as: S
      iex> s = S.new() |> S.record({1, 0})
      iex> s = S.rotate(s, 10, 10)   # boundary reached: {1, 0} moves to the previous epoch
      iex> S.seen?(s, {1, 0})
      true
      iex> s = S.rotate(s, 20, 10)   # boundary again: {1, 0} is now evicted
      iex> S.seen?(s, {1, 0})
      false
  """
  @spec rotate(t, non_neg_integer(), pos_integer()) :: t
  def rotate(%__MODULE__{epoch_start: start, current: c}, edit_count, epoch_size)
      when edit_count - start >= epoch_size,
      do: %__MODULE__{current: MapSet.new(), previous: c, epoch_start: edit_count}

  def rotate(%__MODULE__{} = seen, _edit_count, _epoch_size), do: seen
end
