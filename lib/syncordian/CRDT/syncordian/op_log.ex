defmodule Syncordian.OpLog do
  @moduledoc """
  Per-peer origin log of the operations a peer has itself authored and broadcast.

  Syncordian's delivery buffer (`Syncordian.PendingOps`) holds an operation that cannot be
  applied yet until the operation it depends on arrives. Under a fair-lossy network a
  dependency may be delayed far beyond the ordinary reorder window, or lost outright. Rather
  than eventually discard the waiting operation (which would break the eventual-visibility
  guarantee), a replica that has waited too long asks the *origin* of the missing operation
  to retransmit it. This module is the origin's side of that exchange: each peer keeps a log
  of exactly the broadcasts it authored, so it can re-send any of them verbatim on request.

  ## What is stored

  The stored value is the exact broadcast message the peer put on the wire, authenticator
  included, so a retransmission is byte-for-byte the original. A served copy therefore
  travels through the receiver's normal path, where the replay and duplicate checks make a
  redundant copy harmless.

  Two lookups are served:

    * by identity, `get/2`, for a waiter that names the missing operation by its `op_id`
      (an insert waiting for a parent, a delete waiting for its target);
    * by insert progress rank, `range_inserts/3`, for a waiter that is causally behind a
      writer and needs the writer's inserts of rank `lo..hi` (a clock-gap dependency). A
      peer authors its inserts in progress-rank order, so the log assigns each authored
      insert the next rank as it is recorded.

  For this revision the log is not pruned during a run: a peer keeps every operation it
  authored. Pruning a settled prefix is possible in principle but needs care, because
  deletes are never acknowledged, so it is left as future work. The log's size is reported
  in the run metadata.

  This module is pure and side-effect-free; the peer loop owns all message sending.
  """

  alias Syncordian.Basic_Types

  @typedoc "The exact broadcast message a peer authored, re-sent verbatim on a fetch."
  @type message :: term()

  @opaque t :: %__MODULE__{
            entries: %{optional(Basic_Types.op_id()) => message()},
            inserts: %{optional(pos_integer()) => Basic_Types.op_id()},
            insert_count: non_neg_integer()
          }

  defstruct entries: %{}, inserts: %{}, insert_count: 0

  @doc """
  Returns an empty log.

  ## Examples

      iex> Syncordian.OpLog.size(Syncordian.OpLog.new())
      0
  """
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc "Number of authored operations held in the log."
  @spec size(t) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc """
  Records one authored broadcast, keyed by its `op_id`. An insert is additionally indexed
  by its progress rank, assigned in authoring order, so a rank range can be served later.

  ## Examples

      iex> alias Syncordian.OpLog, as: L
      iex> L.new() |> L.put(:ins, {1, 1}, :msg_a) |> L.get({1, 1})
      :msg_a
  """
  @spec put(t, :ins | :del, Basic_Types.op_id(), message()) :: t
  def put(%__MODULE__{} = log, :ins, op_id, message) do
    rank = log.insert_count + 1

    %{
      log
      | entries: Map.put(log.entries, op_id, message),
        inserts: Map.put(log.inserts, rank, op_id),
        insert_count: rank
    }
  end

  def put(%__MODULE__{} = log, :del, op_id, message) do
    %{log | entries: Map.put(log.entries, op_id, message)}
  end

  @doc """
  Returns the stored broadcast for `op_id`, or `nil` when the peer never authored it.

  ## Examples

      iex> Syncordian.OpLog.get(Syncordian.OpLog.new(), {1, 1})
      nil
  """
  @spec get(t, Basic_Types.op_id()) :: message() | nil
  def get(%__MODULE__{entries: entries}, op_id), do: Map.get(entries, op_id)

  @doc """
  Returns the stored broadcasts for the authored inserts of progress rank `lo..hi`, in
  ascending rank order, skipping ranks the peer never authored.

  ## Examples

      iex> alias Syncordian.OpLog, as: L
      iex> log = L.new() |> L.put(:ins, {1, 1}, :a) |> L.put(:ins, {1, 3}, :b)
      iex> L.range_inserts(log, 1, 2)
      [:a, :b]
  """
  @spec range_inserts(t, pos_integer(), pos_integer()) :: [message()]
  def range_inserts(%__MODULE__{} = log, lo, hi) when lo <= hi do
    lo..hi
    |> Enum.flat_map(fn rank ->
      case Map.get(log.inserts, rank) do
        nil -> []
        op_id -> [Map.fetch!(log.entries, op_id)]
      end
    end)
  end

  def range_inserts(%__MODULE__{}, _lo, _hi), do: []

  @doc """
  Size in bytes of the log's stored broadcasts, for the run metadata.
  """
  @spec byte_size(t) :: non_neg_integer()
  def byte_size(%__MODULE__{entries: entries}), do: :erlang.external_size(entries)
end
