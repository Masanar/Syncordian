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

  ## Dependency fetch (anti-entropy)

  A forged operation cannot reach this buffer: it is rejected at admission before delivery
  is ever considered, so every suspended entry is a genuine operation whose dependency will
  arrive. Under a fair-lossy network the dependency may nevertheless be delayed far past the
  ordinary reorder window, or dropped. Rather than discard the waiting operation, which
  would break eventual visibility, the buffer asks the origin to retransmit it. `sweep/3`
  reports which suspended entries have waited long enough to warrant a (re-)fetch: an entry
  is due once it has aged past a caller-supplied *soft threshold* (in applied edits) and has
  not been fetched within that same span. `sweep/3` marks the due entries so they are not
  re-fetched every call, and returns their dependencies for the peer to turn into fetch
  requests. It never removes an entry: only the arrival of the dependency does, through
  `release/2`. The buffer therefore stays bounded by genuinely outstanding work.

  The sweep is throttled: it runs at most once per a small fraction of the soft threshold
  (entries age in applied edits, so a sweep between two applies can see nothing new),
  keeping the hot suspend path cheap and amortizing the full sweep across applies.

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

  # Entries carry {seq, payload, <dependency data>, enqueued_edit, last_fetch_edit}; seq
  # preserves FIFO release order, enqueued_edit is when the entry began waiting, and
  # last_fetch_edit (nil until the first fetch) is when a retransmission was last requested
  # for it. Both edit stamps drive sweep/3.
  @opaque t :: %__MODULE__{
            clock: %{optional(Basic_Types.peer_id()) => list()},
            line: %{optional(line_key()) => list()},
            seq: non_neg_integer(),
            size: non_neg_integer(),
            last_sweep_edit: integer()
          }

  defstruct clock: %{}, line: %{}, seq: 0, size: 0, last_sweep_edit: -1

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
        entry = {seq, payload, needed, edit_count, nil}
        %{buf | clock: Map.update(buf.clock, sender, [entry], &[entry | &1])}

      {:line, key} ->
        entry = {seq, payload, edit_count, nil}
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
          Enum.split_with(entries, fn {_seq, _payload, needed, _e, _f} -> new_value >= needed end)

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
  Reports the dependencies of the suspended entries that are due for a (re-)fetch, and
  marks those entries as fetched at `current_edit`. Returns `{due_dependencies, buffer}`.
  No entry is ever removed here: an entry leaves the buffer only when its dependency
  arrives (`release/2`).

  An entry is *due* when it has waited at least `soft_threshold` applied edits and has not
  been fetched within the last `soft_threshold` edits. For a clock dependency the reported
  descriptor is `{:clock, sender, needed}` with `needed` the largest value any due entry of
  that sender waits on, so one range fetch can cover a whole causal gap; for a line
  dependency it is `{:line, key}`.

  The full sweep is throttled to at most one per `soft_threshold / 20` applied edits
  (entries age in applied edits, so a sweep between two applies can see nothing new). The
  first call after `new/0` always sweeps.

  ## Examples

      iex> alias Syncordian.PendingOps, as: P
      iex> buf = P.new() |> P.suspend(:msg, {:line, {1, 4}}, 0)
      iex> {due, buf} = P.sweep(buf, 10, 5)
      iex> {due, P.size(buf)}
      {[line: {1, 4}], 1}
      iex> {due_again, _} = P.sweep(buf, 12, 5)
      iex> due_again
      []
  """
  @spec sweep(t, non_neg_integer(), pos_integer()) :: {[dependency()], t}
  def sweep(%__MODULE__{last_sweep_edit: last} = buf, current_edit, soft_threshold)
      when last >= 0 and current_edit - last < max(div(soft_threshold, 20), 1),
      do: {[], buf}

  def sweep(%__MODULE__{} = buf, current_edit, soft_threshold) do
    {clock_deps, clock} = sweep_clock(buf.clock, current_edit, soft_threshold)
    {line_deps, line} = sweep_line(buf.line, current_edit, soft_threshold)

    {clock_deps ++ line_deps,
     %{buf | clock: clock, line: line, last_sweep_edit: current_edit}}
  end

  # An entry is due for a fetch once it has aged past the soft threshold and has not been
  # fetched within that same span (nil means never fetched).
  defp due?(enqueued, last_fetch, current, soft) do
    current - enqueued >= soft and (is_nil(last_fetch) or current - last_fetch >= soft)
  end

  # One coalesced clock dependency per sender that has at least one due entry, carrying the
  # largest value waited on so a single range fetch covers the whole gap. Due entries are
  # stamped with the current edit.
  defp sweep_clock(clock_map, current, soft) do
    Enum.reduce(clock_map, {[], %{}}, fn {sender, entries}, {deps, acc} ->
      {new_entries, due_needed} =
        Enum.reduce(entries, {[], []}, fn {seq, payload, needed, enq, last} = e, {es, ns} ->
          if due?(enq, last, current, soft),
            do: {[{seq, payload, needed, enq, current} | es], [needed | ns]},
            else: {[e | es], ns}
        end)

      deps =
        case due_needed do
          [] -> deps
          _ -> [{:clock, sender, Enum.max(due_needed)} | deps]
        end

      {deps, Map.put(acc, sender, Enum.reverse(new_entries))}
    end)
  end

  # One line dependency per key that has at least one due entry. Due entries are stamped.
  defp sweep_line(line_map, current, soft) do
    Enum.reduce(line_map, {[], %{}}, fn {key, entries}, {deps, acc} ->
      {new_entries, any_due} =
        Enum.reduce(entries, {[], false}, fn {seq, payload, enq, last} = e, {es, due} ->
          if due?(enq, last, current, soft),
            do: {[{seq, payload, enq, current} | es], true},
            else: {[e | es], due}
        end)

      deps = if any_due, do: [{:line, key} | deps], else: deps
      {deps, Map.put(acc, key, Enum.reverse(new_entries))}
    end)
  end
end
