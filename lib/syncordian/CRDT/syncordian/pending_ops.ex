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
      `needed_value` (\\ie all preceding inserts from that sender have been applied). Released
      by a `{:clock_advanced, sender_id, new_value}` event when `new_value >= needed_value`.
    * `{:line, key}` — the operation needs a line that is not present in the document yet.
      `key` is either an **op_id** (an insert waiting for one of its authored parents, or a
      delete waiting for its target line, both named by authored identity) or a **line_id**
      (an acknowledgement whose target line has not arrived; acknowledgements carry no
      op_id). Released by a `{:line_added, key}` event; the apply path fires the event for
      both the added line's op_id and its line_id, so either kind of waiter is woken.

  ## Indexing (liveness under load)

  Entries are stored *indexed by their dependency* — per-sender lists for `{:clock, ...}`
  and a map keyed by `key` for `{:line, ...}` — rather than one flat list. The apply path
  fires a small number of events per applied edit; with a flat list each event re-scanned
  the whole buffer, so a replica that fell behind under network jitter paid O(backlog) per
  apply and O(backlog²) to drain, which in practice turned a transient lag into a
  minutes-long stall (observed at ~29k suspended ops) while the rest of the network waited
  on the replay barrier. With the index, an event touches only the entries that could match
  it: `{:clock_advanced, s, _}` scans sender `s`'s waiters and `{:line_added, key}` is a
  single map pop. Released payloads preserve FIFO suspension order via a monotonic sequence
  number.

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

  @typedoc "A `{:line, key}` waiter's key: an op_id (parents, delete targets) or a line_id (acks)."
  @type line_key :: Basic_Types.op_id() | Basic_Types.line_id()

  @type dependency ::
          {:clock, Basic_Types.peer_id(), non_neg_integer()}
          | {:line, line_key()}

  @type event ::
          {:clock_advanced, Basic_Types.peer_id(), non_neg_integer()}
          | {:line_added, line_key()}

  # Entries carry {seq, payload, <dependency data>, enqueued_edit}; seq preserves FIFO
  # release order, enqueued_edit drives the gc horizon.
  @opaque t :: %__MODULE__{
            clock: %{optional(Basic_Types.peer_id()) => list()},
            line: %{optional(line_key()) => list()},
            seq: non_neg_integer(),
            size: non_neg_integer(),
            last_gc_edit: integer()
          }

  defstruct clock: %{}, line: %{}, seq: 0, size: 0, last_gc_edit: -1

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
      iex> P.new() |> P.suspend(:msg, {:line, {1, 4}}, 4) |> P.size()
      1
  """
  @spec suspend(t, payload(), dependency(), non_neg_integer()) :: t
  def suspend(%__MODULE__{seq: seq, size: size} = buf, payload, dependency, edit_count) do
    buf = %{buf | seq: seq + 1, size: size + 1}

    case dependency do
      {:clock, sender, needed} ->
        entry = {seq, payload, needed, edit_count}
        %{buf | clock: Map.update(buf.clock, sender, [entry], &[entry | &1])}

      {:line, key} ->
        entry = {seq, payload, edit_count}
        %{buf | line: Map.update(buf.line, key, [entry], &[entry | &1])}
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

  def release(%__MODULE__{} = buf, {:line_added, key}) do
    case Map.pop(buf.line, key) do
      {nil, _} -> {[], buf}
      {ready, line} -> emit(ready, %{buf | line: line})
    end
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
      ...>       |> P.suspend(:old, {:line, {1, 1}}, 0)
      ...>       |> P.suspend(:new, {:line, {1, 2}}, 9)
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

    dropped = dropped_clock + dropped_line

    {dropped,
     %{
       buf
       | clock: clock,
         line: line,
         size: size(buf) - dropped,
         last_gc_edit: current_edit
     }}
  end
end
