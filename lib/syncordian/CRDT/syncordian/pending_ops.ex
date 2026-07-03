defmodule Syncordian.PendingOps do
  @moduledoc """
  Dependency-indexed buffer of operations that are not yet deliverable.

  Replaces the previous counter-based busy-spin (`@max_insertion_attempts`), where a peer
  re-sent an undeliverable message to itself up to a fixed number of times before dropping
  it. Instead of polling, an operation that cannot be applied yet is *suspended* against the
  concrete event it is waiting for, and re-dispatched exactly when that event is observed.

  ## Dependencies

  Each suspended operation carries one dependency descriptor:

    * `{:clock, sender_id, needed_value}` — the operation is causally ahead of the local
      peer; it becomes deliverable once the local progress vector for `sender_id` reaches
      `needed_value` (\\ie all preceding edits from that sender have been applied). Released
      by a `{:clock_advanced, sender_id, new_value}` event when `new_value >= needed_value`.
    * `{:line, line_id}` — a delete whose target line is not present in the document yet.
      Released by a `{:line_added, line_id}` event.
    * `{:vc_ready, incoming_vc, sender_id}` — an insert suspended for missing causal
      context; deliverable once the local clock dominates the sender's recorded view
      (sender's own component at its immediate predecessor). Released by `{:clock_now, vc}`.
    * `:progress` — a delete whose signature could not be validated against any stash
      window yet; re-evaluated on any local apply. Released by a `:progress` event.

  ## Indexing (liveness under load)

  Entries are stored *indexed by their dependency* — per-sender lists for `{:clock, ...}`,
  a map keyed by line id for `{:line, ...}`, and small dedicated lists for `:vc_ready` /
  `:progress` — rather than one flat list. The apply path fires up to three events per
  applied edit; with a flat list each event re-scanned the whole buffer, so a replica that
  fell behind under network jitter paid O(backlog) per apply and O(backlog²) to drain,
  which in practice turned a transient lag into a minutes-long stall (observed at ~29k
  suspended ops) while the rest of the network waited on the replay barrier. With the
  index, an event touches only the entries that could match it: `{:clock_advanced, s, _}`
  scans sender `s`'s waiters, `{:line_added, id}` is a single map pop, and `{:clock_now, _}`
  scans only the (small) `vc_ready` frontier. Released payloads preserve FIFO suspension
  order via a monotonic sequence number.

  ## Liveness backstop

  An operation whose dependency never materializes (\\eg a forged delete from a Byzantine
  peer that references a line that will never exist) would otherwise occupy the buffer
  forever. `gc/3` reclaims any entry that has waited longer than a caller-supplied
  *edit-count horizon*: the number of edits the peer has applied since the entry was
  suspended. Under reliable eventual delivery with monotone per-sender progress vectors,
  an honest operation's dependency is satisfied within the in-flight reorder window, so a
  horizon at least that large never drops an honest operation, while the live buffer size
  stays bounded by `horizon * peers`. The sweep itself is throttled: it only runs once the
  peer's edit count has advanced since the previous sweep (entries age in applied edits,
  so a sweep between two applies can never reclaim anything new), keeping `gc/3` O(1) on
  the hot suspend path and amortizing the full sweep across applies.

  This module is pure and side-effect-free; the peer loop owns all message sending.
  """

  alias Syncordian.Basic_Types

  @typedoc "The original loop message to be re-dispatched verbatim once deliverable."
  @type payload :: term()

  @type dependency ::
          {:clock, Basic_Types.peer_id(), non_neg_integer()}
          | {:line, Basic_Types.line_id()}
          | {:vc_ready, [non_neg_integer()], Basic_Types.peer_id()}
          | :progress

  @type event ::
          {:clock_advanced, Basic_Types.peer_id(), non_neg_integer()}
          | {:line_added, Basic_Types.line_id()}
          | {:clock_now, [non_neg_integer()]}
          | :progress

  # Entries carry {seq, payload, <dependency data>, enqueued_edit}; seq preserves FIFO
  # release order, enqueued_edit drives the gc horizon.
  @opaque t :: %__MODULE__{
            clock: %{optional(Basic_Types.peer_id()) => list()},
            line: %{optional(Basic_Types.line_id()) => list()},
            vc: list(),
            progress: list(),
            seq: non_neg_integer(),
            size: non_neg_integer(),
            last_gc_edit: integer()
          }

  defstruct clock: %{}, line: %{}, vc: [], progress: [], seq: 0, size: 0, last_gc_edit: -1

  @doc """
  Returns an empty buffer.

  ## Examples

      iex> Syncordian.PendingOps.size(Syncordian.PendingOps.new())
      0
  """
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "Number of operations currently suspended."
  @spec size(t) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Suspends `payload` against `dependency`, stamping it with `edit_count` (the peer's current
  edit counter) for later staleness reclamation. Entries are kept in FIFO order so that
  re-dispatch is deterministic.

  ## Examples

      iex> alias Syncordian.PendingOps, as: P
      iex> P.new() |> P.suspend(:msg, {:line, {:path, [{1, 0}]}}, 4) |> P.size()
      1
  """
  @spec suspend(t, payload(), dependency(), non_neg_integer()) :: t
  def suspend(%__MODULE__{seq: seq, size: size} = buf, payload, dependency, edit_count) do
    buf = %{buf | seq: seq + 1, size: size + 1}

    case dependency do
      {:clock, sender, needed} ->
        entry = {seq, payload, needed, edit_count}
        %{buf | clock: Map.update(buf.clock, sender, [entry], &[entry | &1])}

      {:line, line_id} ->
        entry = {seq, payload, edit_count}
        %{buf | line: Map.update(buf.line, line_id, [entry], &[entry | &1])}

      {:vc_ready, incoming_vc, sender} ->
        entry = {seq, payload, incoming_vc, sender, edit_count}
        %{buf | vc: [entry | buf.vc]}

      :progress ->
        entry = {seq, payload, edit_count}
        %{buf | progress: [entry | buf.progress]}
    end
  end

  @doc """
  Releases every operation whose dependency is satisfied by `event`, in FIFO order.
  Returns `{ready_payloads, remaining_buffer}`. An event only matches its own dependency
  kind; the caller fires the relevant events after each apply.

  ## Examples

      iex> alias Syncordian.PendingOps, as: P
      iex> buf = P.new()
      ...>       |> P.suspend(:a, {:clock, 2, 3}, 0)
      ...>       |> P.suspend(:b, {:clock, 2, 5}, 0)
      iex> {ready, buf} = P.release(buf, {:clock_advanced, 2, 3})
      iex> {ready, P.size(buf)}
      {[:a], 1}

      iex> alias Syncordian.PendingOps, as: P
      iex> buf = P.new() |> P.suspend(:d, {:line, :l1}, 0)
      iex> {ready, buf} = P.release(buf, {:line_added, :l1})
      iex> {ready, P.size(buf)}
      {[:d], 0}
  """
  @spec release(t, event()) :: {[payload()], t}
  def release(%__MODULE__{} = buf, {:clock_advanced, sender, new_value}) do
    case Map.get(buf.clock, sender) do
      nil ->
        {[], buf}

      entries ->
        {ready, kept} =
          Enum.split_with(entries, fn {_seq, _payload, needed, _e} -> new_value >= needed end)

        clock =
          case kept do
            [] -> Map.delete(buf.clock, sender)
            _ -> Map.put(buf.clock, sender, kept)
          end

        emit(ready, %{buf | clock: clock})
    end
  end

  def release(%__MODULE__{} = buf, {:line_added, line_id}) do
    case Map.pop(buf.line, line_id) do
      {nil, _} -> {[], buf}
      {ready, line} -> emit(ready, %{buf | line: line})
    end
  end

  def release(%__MODULE__{} = buf, {:clock_now, local_vc}) do
    {ready, kept} =
      Enum.split_with(buf.vc, fn {_seq, _payload, incoming_vc, sender, _e} ->
        vc_ready?(incoming_vc, sender, local_vc)
      end)

    emit(ready, %{buf | vc: kept})
  end

  def release(%__MODULE__{} = buf, :progress) do
    {ready, buf} = {buf.progress, %{buf | progress: []}}
    emit(ready, buf)
  end

  # Sorts the released entries back into FIFO suspension order (seq is the first tuple
  # element), strips them down to their payloads, and maintains the size counter.
  @spec emit([tuple()], t) :: {[payload()], t}
  defp emit(ready, %__MODULE__{size: size} = buf) do
    payloads =
      ready
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    {payloads, %{buf | size: size - length(payloads)}}
  end

  # An insert suspended for missing causal context is deliverable exactly when the local
  # clock has caught up with the sender's recorded view: every non-sender component
  # dominated, and the sender's own component at its immediate predecessor (the insert
  # itself provides the final tick).
  @spec vc_ready?([non_neg_integer()], Basic_Types.peer_id(), [non_neg_integer()]) ::
          boolean()
  defp vc_ready?(incoming_vc, sender, local_vc) do
    incoming_vc
    |> Enum.with_index()
    |> Enum.all?(fn {incoming_at, j} ->
      needed = if j == sender, do: incoming_at - 1, else: incoming_at
      Enum.at(local_vc, j, 0) >= needed
    end)
  end

  @doc """
  Reclaims entries whose wait has exceeded `horizon` edits, \\ie those for which
  `current_edit - enqueued_at_edit > horizon`. Returns `{dropped_count, remaining_buffer}`.

  The full sweep is throttled to at most one per `horizon / 20` applied edits (entries
  age in applied edits, so a sweep between two applies can never reclaim anything new,
  and a reclamation delayed by a twentieth of the horizon is still comfortably inside
  the backstop's slack). This keeps `gc/3` O(1) on the hot suspend path instead of
  O(buffer) per suspension, which under load re-created the quadratic drain the
  dependency index removes. The first call after `new/0` always sweeps.

  ## Examples

      iex> alias Syncordian.PendingOps, as: P
      iex> buf = P.new()
      ...>       |> P.suspend(:old, :progress, 0)
      ...>       |> P.suspend(:new, :progress, 9)
      iex> {dropped, buf} = P.gc(buf, 10, 5)
      iex> {dropped, P.size(buf)}
      {1, 1}
  """
  @spec gc(t, non_neg_integer(), non_neg_integer()) :: {non_neg_integer(), t}
  def gc(%__MODULE__{last_gc_edit: last} = buf, current_edit, horizon)
      when last >= 0 and current_edit - last < max(div(horizon, 20), 1),
      do: {0, buf}

  def gc(%__MODULE__{} = buf, current_edit, horizon) do
    stale? = fn entry ->
      # enqueued_edit is the last tuple element of every entry shape.
      current_edit - elem(entry, tuple_size(entry) - 1) > horizon
    end

    sweep_map = fn map ->
      map
      |> Enum.reduce({0, %{}}, fn {key, entries}, {dropped, acc} ->
        {stale, kept} = Enum.split_with(entries, stale?)

        acc = if kept == [], do: acc, else: Map.put(acc, key, kept)
        {dropped + length(stale), acc}
      end)
    end

    {dropped_clock, clock} = sweep_map.(buf.clock)
    {dropped_line, line} = sweep_map.(buf.line)
    {stale_vc, vc} = Enum.split_with(buf.vc, stale?)
    {stale_progress, progress} = Enum.split_with(buf.progress, stale?)

    dropped = dropped_clock + dropped_line + length(stale_vc) + length(stale_progress)

    {dropped,
     %{
       buf
       | clock: clock,
         line: line,
         vc: vc,
         progress: progress,
         size: size(buf) - dropped,
         last_gc_edit: current_edit
     }}
  end
end
