defmodule Syncordian.OpTimes do
  @moduledoc """
  Timing of individual operations, from issue to application and to settlement.

  The per-peer counters of `Syncordian.Metadata` say how much work a run did. They
  cannot say how long an operation took to reach a replica, because that measurement
  spans two processes: the peer that issued the operation and each peer that applied
  it. This module holds the timestamps of both, in one table every peer of the run
  writes to, so the two can be subtracted afterwards.

  Three events are stamped:

    * *issue*, when the author puts an insert on the wire;
    * *apply*, when a replica materializes that insert into its document; and
    * *settle*, when the author's response checklist for the line fills and the line's
      status advances.

  Apply latency is the time from issue to apply, one sample per operation per replica.
  Settle latency is the time from issue to settlement, one sample per operation, and it
  is the longer of the two because a line settles only after every peer has both applied
  it and acknowledged it. Reporting them separately keeps the cost of delivery apart
  from the cost of agreement.

  All timestamps come from the monotonic clock, which is comparable across processes of
  one virtual machine and is unaffected by wall-clock adjustments. The whole experiment
  runs in one virtual machine, so the differences are meaningful. On a real network the
  same subtraction would need clock synchronization, and we do not claim otherwise.

  The table is created by `Syncordian.Supervisor` before any peer starts, and every
  recording function is a no-op when it does not exist. A peer driven directly by a test
  therefore runs unchanged and pays one table lookup per operation.
  """

  @table :syncordian_op_times

  @typedoc "The identity of the insert being timed."
  @type op_id :: Syncordian.Basic_Types.op_id()

  @doc """
  Creates the timing table, discarding any table left by a previous run.

  Public and named, because every peer process writes to it and none of them owns it.
  """
  @spec create() :: :ok
  def create do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    :ok
  end

  @doc "True iff a run is currently being timed."
  @spec active?() :: boolean()
  def active?, do: :ets.whereis(@table) != :undefined

  @doc """
  Stamps the moment `op_id` was put on the wire by its author.

  Recorded once per operation. A re-issued line is a new operation with its own
  identity, so a repair's cost appears as its own sample rather than being folded into
  the operation it replaces.
  """
  @spec record_issue(op_id()) :: :ok
  def record_issue(op_id), do: put({:issue, op_id})

  @doc "Stamps the moment `peer_id` applied `op_id` to its document."
  @spec record_apply(op_id(), Syncordian.Basic_Types.peer_id()) :: :ok
  def record_apply(op_id, peer_id), do: put({:apply, op_id, peer_id})

  @doc "Stamps the moment the line created by `op_id` advanced to settled at its author."
  @spec record_settle(op_id()) :: :ok
  def record_settle(op_id), do: put({:settle, op_id})

  @spec put(tuple()) :: :ok
  defp put(key) do
    if active?() do
      # insert_new: the first stamp is the one that matters. An operation re-delivered
      # to a replica that already applied it is dropped upstream, but a duplicate stamp
      # here would silently shorten the sample.
      :ets.insert_new(@table, {key, :erlang.monotonic_time(:nanosecond)})
    end

    :ok
  end

  @doc """
  Pairs the recorded stamps into latency samples, in microseconds.

  Returns a map with `apply_latency_us` (one entry per operation per replica that
  applied it) and `settle_latency_us` (one entry per operation that settled), together
  with the counts the samples are drawn from. Operations whose issue was never stamped
  are skipped rather than counted as zero, which is what keeps a peer driven outside a
  supervised run from contributing a meaningless sample.

  Percentiles are deliberately not computed here. The samples are written out whole so
  the analysis scripts can choose the summary, and so a reported percentile can be
  recomputed from the artifact.
  """
  @spec samples() :: %{
          apply_latency_us: [float()],
          settle_latency_us: [float()],
          operations: non_neg_integer(),
          applies: non_neg_integer(),
          settles: non_neg_integer()
        }
  def samples do
    if active?() do
      issued =
        :ets.match_object(@table, {{:issue, :_}, :_})
        |> Map.new(fn {{:issue, op_id}, time} -> {op_id, time} end)

      applies =
        for {{:apply, op_id, _peer_id}, time} <-
              :ets.match_object(@table, {{:apply, :_, :_}, :_}),
            issue = Map.get(issued, op_id),
            issue != nil,
            do: microseconds(time - issue)

      settles =
        for {{:settle, op_id}, time} <- :ets.match_object(@table, {{:settle, :_}, :_}),
            issue = Map.get(issued, op_id),
            issue != nil,
            do: microseconds(time - issue)

      %{
        apply_latency_us: applies,
        settle_latency_us: settles,
        operations: map_size(issued),
        applies: length(applies),
        settles: length(settles)
      }
    else
      %{apply_latency_us: [], settle_latency_us: [], operations: 0, applies: 0, settles: 0}
    end
  end

  @doc """
  Writes the latency samples of the current run as JSON under `debug/metadata/`.

  `label` names the run, so a sweep over the number of distrusted nodes or over seeds
  leaves one artifact per run rather than overwriting a single file. Returns the path
  written, or `:inactive` when no run was being timed.
  """
  @spec dump(String.t()) :: {:ok, Path.t()} | :inactive
  def dump(label) do
    if active?() do
      directory = "debug/metadata"
      File.mkdir_p!(directory)
      path = Path.join(directory, "latency_#{label}.json")
      File.write!(path, Jason.encode!(samples(), pretty: true))
      {:ok, path}
    else
      :inactive
    end
  end

  @spec microseconds(integer()) :: float()
  defp microseconds(nanoseconds), do: nanoseconds / 1_000
end
