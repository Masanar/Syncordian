defmodule Syncordian.Instrument do
  @moduledoc """
  Process-local cost accumulators for the evaluation.

  Two costs are paid inside functions that carry no peer state and therefore cannot
  fold their measurements into the peer's `Syncordian.Metadata` record directly: the
  bytes a message puts on the wire (`Syncordian.Utilities.broadcast_to/3`) and the
  authenticator computations a peer performs (`Syncordian.Byzantine`). Both run in the
  peer's own process, so the accumulators live in that process's dictionary and the
  peer folds them into its metadata at each snapshot (`snapshot/0`).

  Keeping the accumulators here rather than threading them through every call site is
  what makes the instrumentation additive: the measured functions stay pure in their
  arguments and results, and nothing about the protocol changes because a run is being
  measured.

  Two properties matter for reading the numbers the harness reports.

    * The counters are *per process*, so a peer only ever accumulates its own sends and
      its own authenticator work. There is no cross-peer contention and no lock.
    * They are cumulative over the process's life, and `snapshot/0` does not clear them.
      A peer's metadata record is cumulative over the same life, so folding a snapshot in
      is an assignment rather than an addition. That makes it idempotent: a snapshot taken
      twice, or one whose result is discarded, cannot double count or lose work.

  Authenticator timing is *sampled*: one call in `#{64}` is wrapped in a monotonic-clock
  reading. Timing every call would cost more than the call being timed at this
  granularity. Every sample is kept, so the analysis reads a distribution rather than a
  mean whose support it cannot see (`record_mac_time/1` says why the mean alone is not
  enough).

  Keeping the counters cumulative is also what keeps the sampling honest. An earlier
  version cleared them at each snapshot, which restarted the one-in-64 phase every time,
  so any domain that saw fewer than 64 calls between two snapshots was never timed at all
  and the sample count fell far below the call count divided by 64. The timings themselves
  were unbiased, but their support silently depended on how often the harness happened to
  take a snapshot, which is not a property a measurement should have.
  """

  @wire_key :syncordian_wire
  @mac_key :syncordian_mac
  @mac_time_key :syncordian_mac_time

  # One authenticator call in this many is timed. A power of two so the test is a mask.
  @sample_every 64

  @typedoc "Wire message kinds the harness accounts for separately."
  @type wire_kind :: :insert | :delete | :ack | :fetch | :other

  @typedoc "Authenticator domains, matching `Syncordian.Byzantine`'s key domains."
  @type mac_domain :: :doc | :ins | :del | :ack | :adm | :fetch

  @wire_kinds [:insert, :delete, :ack, :fetch, :other]
  @mac_domains [:doc, :ins, :del, :ack, :adm, :fetch]

  @doc """
  Classifies a broadcast message by the operation it carries.

  The harness reports insert, delete, acknowledgement and retransmission traffic
  separately, because they scale differently: one insert is broadcast to every peer and
  draws one acknowledgement back from each, so acknowledgement traffic grows with the
  square of the peer count while insert traffic grows linearly. A single total would
  hide that, and the comparison against the other CRDTs would be read as if the two
  costs were interchangeable.
  """
  @spec wire_kind(term()) :: wire_kind()
  def wire_kind({:receive_insert_broadcast, _payload, _alpha}), do: :insert
  def wire_kind({:receive_delete_broadcast, _payload, _alpha}), do: :delete
  def wire_kind({:receive_confirmation_line_insertion, _payload, _alpha}), do: :ack
  def wire_kind({:fetch_request, _requester, _want, _alpha}), do: :fetch
  def wire_kind(_other), do: :other

  @doc """
  Accounts `messages` deliveries totalling `bytes` bytes leaving this process, under `kind`.

  Bytes are external term sizes, which is what a message would occupy on a real link. The
  harness measures that rather than the payload's logical length, so the accounting includes
  the authenticators and identifiers an operation carries and is comparable across the four
  CRDTs.

  A broadcast is accounted as one delivery per recipient. That is the load a deployment
  would carry, and it is what makes the quadratic growth of acknowledgement traffic visible
  instead of hidden behind a per-call count.
  """
  @spec record_message(wire_kind(), non_neg_integer(), pos_integer()) :: :ok
  def record_message(kind, bytes, messages \\ 1)
      when kind in @wire_kinds and is_integer(bytes) and is_integer(messages) do
    wire = Process.get(@wire_key, %{})
    {previous_messages, previous_bytes} = Map.get(wire, kind, {0, 0})

    Process.put(
      @wire_key,
      Map.put(wire, kind, {previous_messages + messages, previous_bytes + bytes})
    )

    :ok
  end

  @doc """
  Accounts one authenticator computation under `domain`, and says whether this call is
  the one to time.

  Returns `true` on every `#{64}`th call of that domain. The caller times the
  computation itself and reports the elapsed time with `record_mac_time/1`; doing it
  this way keeps the unsampled path free of closures, which matters because the
  authenticator is on the hot path of every applied operation.
  """
  @spec record_mac(mac_domain()) :: boolean()
  def record_mac(domain) when domain in @mac_domains do
    calls = Process.get(@mac_key, %{})
    count = Map.get(calls, domain, 0) + 1
    Process.put(@mac_key, Map.put(calls, domain, count))
    rem(count, @sample_every) == 0
  end

  @doc """
  Records one sampled authenticator timing, in nanoseconds.

  Every sample is kept, not just their sum. A sampled call is timed by reading the
  monotonic clock on either side of it, so the figure includes any time the process spent
  descheduled during the call. Under a loaded run that happens often enough to dominate a
  mean: two replays of the same workload gave means five times apart while their medians
  agreed. The distribution therefore has to survive to the analysis, where a median says
  what the computation costs and the upper tail says what scheduling did to it. There are
  a few tens of samples per peer per run, so keeping them costs nothing.
  """
  @spec record_mac_time(non_neg_integer()) :: :ok
  def record_mac_time(nanoseconds) when is_integer(nanoseconds) do
    {samples, total, values} = Process.get(@mac_time_key, {0, 0, []})
    Process.put(@mac_time_key, {samples + 1, total + nanoseconds, [nanoseconds | values]})
    :ok
  end

  @doc """
  Returns everything this process has accumulated so far, without clearing it.

  The shape is a map with a `:wire` entry (kind to `{messages, bytes}`), a `:mac` entry
  (domain to call count), and a `:mac_time` entry
  (`{sampled_calls, total_nanoseconds, samples}`).
  Absent kinds and domains are simply missing, so a peer that never served a
  retransmission reports no retransmission bytes rather than a zero that looks like a
  measurement.
  """
  @spec snapshot() :: %{
          wire: %{wire_kind() => {non_neg_integer(), non_neg_integer()}},
          mac: %{mac_domain() => non_neg_integer()},
          mac_time: {non_neg_integer(), non_neg_integer(), [non_neg_integer()]}
        }
  def snapshot do
    %{
      wire: Process.get(@wire_key, %{}),
      mac: Process.get(@mac_key, %{}),
      mac_time: Process.get(@mac_time_key, {0, 0, []})
    }
  end

  @doc """
  Clears this process's accumulators. For tests that need a known starting point; a run
  never calls it, because the counters are meant to span the whole life of a peer.
  """
  @spec reset() :: :ok
  def reset do
    Process.delete(@wire_key)
    Process.delete(@mac_key)
    Process.delete(@mac_time_key)
    :ok
  end

  @doc "The wire kinds accounted for, in report order."
  @spec wire_kinds() :: [wire_kind()]
  def wire_kinds, do: @wire_kinds

  @doc "The authenticator domains accounted for, in report order."
  @spec mac_domains() :: [mac_domain()]
  def mac_domains, do: @mac_domains
end
