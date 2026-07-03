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
    * `:progress` — a delete whose signature could not be validated against any stash
      window yet; re-evaluated on any local apply. Released by a `:progress` event.

  ## Liveness backstop

  An operation whose dependency never materializes (\\eg a forged delete from a Byzantine
  peer that references a line that will never exist) would otherwise occupy the buffer
  forever. `gc/3` reclaims any entry that has waited longer than a caller-supplied
  *edit-count horizon*: the number of edits the peer has applied since the entry was
  suspended. Under reliable eventual delivery with monotone per-sender progress vectors,
  an honest operation's dependency is satisfied within the in-flight reorder window, so a
  horizon at least that large never drops an honest operation, while the live buffer size
  stays bounded by `horizon * peers`. This replaces the previous unjustified constant and
  is the bound proved in the paper (workstream A3).

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

  @typep entry :: {payload(), dependency(), non_neg_integer()}
  @opaque t :: %__MODULE__{entries: [entry()]}

  defstruct entries: []

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
  def size(%__MODULE__{entries: entries}), do: length(entries)

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
  def suspend(%__MODULE__{entries: entries} = buf, payload, dependency, edit_count) do
    %{buf | entries: entries ++ [{payload, dependency, edit_count}]}
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
  def release(%__MODULE__{entries: entries} = buf, event) do
    {ready, kept} = Enum.split_with(entries, fn {_p, dep, _e} -> satisfied?(dep, event) end)
    {Enum.map(ready, fn {payload, _dep, _e} -> payload end), %{buf | entries: kept}}
  end

  @doc """
  Reclaims entries whose wait has exceeded `horizon` edits, \\ie those for which
  `current_edit - enqueued_at_edit > horizon`. Returns `{dropped_count, remaining_buffer}`.

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
  def gc(%__MODULE__{entries: entries} = buf, current_edit, horizon) do
    {kept, dropped} =
      Enum.split_with(entries, fn {_p, _dep, enqueued} ->
        current_edit - enqueued <= horizon
      end)

    {length(dropped), %{buf | entries: kept}}
  end

  # --- dependency / event matching ---------------------------------------------------

  @spec satisfied?(dependency(), event()) :: boolean()
  defp satisfied?({:clock, sender, needed}, {:clock_advanced, sender, new_value}),
    do: new_value >= needed

  defp satisfied?({:line, line_id}, {:line_added, line_id}), do: true
  defp satisfied?(:progress, :progress), do: true

  # An insert suspended for missing causal context is deliverable exactly when the local
  # clock has caught up with the sender's recorded view: every non-sender component
  # dominated, and the sender's own component at its immediate predecessor (the insert
  # itself provides the final tick). Evaluated in-buffer against the current clock, so a
  # not-yet-ready op costs one integer comparison per apply instead of a full re-dispatch
  # through admission checking.
  defp satisfied?({:vc_ready, incoming_vc, sender}, {:clock_now, local_vc}) do
    incoming_vc
    |> Enum.with_index()
    |> Enum.all?(fn {incoming_at, j} ->
      needed = if j == sender, do: incoming_at - 1, else: incoming_at
      Enum.at(local_vc, j, 0) >= needed
    end)
  end

  defp satisfied?(_dependency, _event), do: false
end
