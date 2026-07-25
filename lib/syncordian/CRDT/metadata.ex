defmodule Syncordian.Metadata do
  @moduledoc """
  Per-peer experiment instrumentation.

  Every peer carries a `metadata` record (defined here with `Record.defrecord/2`)
  that accumulates counters describing what happened to it during a run: how many
  inserts/deletes were valid, stashed, requeued or rejected; how many forged
  Byzantine operations were observed; how many lines settled or were re-placed to
  resolve an interleaving; plus live VM stats (heap size, message-queue length).

  The counters are bumped from `Syncordian.Peer` / `Syncordian.ByzantinePeer` as
  operations flow through, then collected by `Syncordian.Supervisor` after every
  commit. `merge_metadata/2` field-wise sums two records (used to aggregate all
  peers into one network-wide snapshot), and the `save_metadata*` functions write
  the snapshots as JSON under `debug/metadata/` for the Python plotting scripts in
  `scripts/` to consume.

  Access fields with `metadata(rec, :field)` and update with
  `metadata(rec, field: value)`; the `inc_*` helpers each return a new record with
  one counter incremented.
  """
  require Record
  import Syncordian.Utilities

  # The field list is a module attribute rather than an inline literal because three things
  # are derived from it: the record itself, the field-wise merge, and the JSON encoding.
  # Deriving them removes the failure mode that a new counter is added to the record and
  # silently dropped from one of the other two, which is a measurement that reads as a real
  # zero.
  @metadata_fields [
    delete_valid_counter: 0,
    delete_stash_counter: 0,
    requeue_counter: 0,
    delete_requeue_limit: 0,
    insert_distance_greater_than_one: 0,
    insert_request_counter: 0,
    insert_request_limit_counter: 0,
    insert_stash_counter: 0,
    insert_valid_counter: 0,
    insert_stash_fail_counter: 0,
    byzantine_insert_counter: 0,
    byzantine_delete_counter: 0,
    # Genuine messages the adversary captured and re-broadcast unchanged. Counted apart from
    # the two above because they are a different experiment: a forged message is answered by
    # the admission check, while a verbatim replay passes admission and is answered by
    # idempotence. A single "attack volume" would hide which of the two a run exercised.
    byzantine_replay_counter: 0,
    replay_rejected_counter: 0,
    ack_rejected_counter: 0,
    admission_rejected_counter: 0,
    delete_rejected_counter: 0,
    heap_size: 0,
    message_queue_length: 0,
    settle_counter: 0,
    conflict_detected_counter: 0,
    replacement_issued_counter: 0,
    # Anti-entropy (Syncordian.OpLog): retransmission requests this peer sent because a
    # dependency was overdue; operations this peer re-sent as an origin; and the byte size
    # of this peer's origin log.
    fetch_request_sent: 0,
    fetch_served: 0,
    origin_log_bytes: 0,
    # Interleaving repair, alias side (the A component of the replica state). A re-issued
    # insert supersedes the line it moves, so:
    #   * alias_entries is how many lines this replica has seen moved;
    #   * delete_followed_alias counts the deletes that had to follow a link to reach the
    #     copy that currently carries the content, which is exactly the delete-and-move race
    #     occurring in the wild;
    #   * reissue_superseded_deleted counts the moves that landed on already-deleted content
    #     and were therefore born as tombstones, the same race in the other arrival order;
    #   * live_duplicates_max is a witness gauge: the number of alias pairs whose two lines
    #     are live at the same time. Retraction is part of the re-issue, so this is 0 by
    #     construction and any other value is a bug.
    alias_entries: 0,
    delete_followed_alias: 0,
    reissue_superseded_deleted: 0,
    live_duplicates_max: 0,
    # Transient interleaving (R7). conflict_detected_counter above counts the conflicts this
    # peer *repaired*, so it is silent at every replica that is not the lower-priority
    # writer. These three observe instead: every replica sees every conflict its document
    # exhibits, whoever repairs it.
    #   * conflicts_observed counts distinct interleavings this replica ever saw;
    #   * concurrent_conflicts is how many are unresolved right now;
    #   * max_concurrent_conflicts is the high-water mark over the run.
    # A run whose conflicts_observed is 0 exhibited no interleaving to repair, which is a
    # statement about the workload and not about the repair protocol.
    #
    # Note on reading conflicts_observed across a network: the same interleaving is visible
    # at every replica that holds both blocks, so the merged value counts observations, not
    # distinct interleavings. The two gauges below merge as maxima instead, and answer "the
    # most any single replica was holding" now and over the run.
    conflicts_observed: 0,
    concurrent_conflicts: 0,
    max_concurrent_conflicts: 0,
    # Repair latency: for each conflict that appeared and later disappeared at this replica,
    # how long it stood. Measured twice, because neither alone is interpretable: in applied
    # edits, which is the logical duration and is independent of machine speed, and in
    # milliseconds, which is what a user would wait. Samples rather than an average, so the
    # distribution survives to the analysis.
    repair_latency_edits: [],
    repair_latency_ms: [],
    # Re-placement amplification: how many lines each repair had to re-issue. One conflict
    # costs a whole block, not one operation, and this is the multiplier.
    reissued_lines_per_conflict: [],
    # Network load by operation kind (R9). Acknowledgement traffic grows with the square of
    # the peer count while operation traffic grows linearly, so a single total would misstate
    # the comparison against the other CRDTs. Bytes are external term sizes, i.e. what the
    # message would occupy on a link.
    bytes_insert: 0,
    bytes_delete: 0,
    bytes_ack: 0,
    bytes_fetch: 0,
    bytes_other: 0,
    msgs_insert: 0,
    msgs_delete: 0,
    msgs_ack: 0,
    msgs_fetch: 0,
    msgs_other: 0,
    # Authenticator cost. One count per key domain, plus sampled timings: mac_sampled_calls
    # is the support of mac_sampled_ns, so a mean is always reported with the number of
    # observations behind it rather than on its own.
    mac_calls_doc: 0,
    mac_calls_ins: 0,
    mac_calls_del: 0,
    mac_calls_ack: 0,
    mac_calls_adm: 0,
    mac_calls_fetch: 0,
    mac_sampled_calls: 0,
    mac_sampled_ns: 0,
    # The sampled timings themselves. A timing is a wall-clock delta around one call, so it
    # includes any time the process spent descheduled during it, and under load those
    # outliers dominate a mean. The median over the samples is what says what the
    # computation costs; the mean is kept beside it so the gap between them is visible.
    mac_sample_ns: [],
    # Position-identifier depth over the document at each snapshot. The maximum is the worst
    # case and the sum with the line count gives the mean, kept as two fields so that the
    # network-wide mean is the mean over all lines rather than an average of per-peer means,
    # which would weight a small replica the same as a large one.
    pid_depth_max: 0,
    pid_depth_sum: 0,
    pid_depth_lines: 0
  ]

  Record.defrecord(:metadata, @metadata_fields)

  @field_names Keyword.keys(@metadata_fields)

  # Records are tuples tagged with the record name, so field i of the field list lives at
  # element i + 1.
  @field_index @field_names |> Enum.with_index(1) |> Map.new()

  # Fields whose network-wide value is the largest any peer reported, not the total. A
  # high-water mark is a property of some single replica; summing them would report a
  # network that never existed.
  @max_merged [
    :live_duplicates_max,
    :concurrent_conflicts,
    :max_concurrent_conflicts,
    :pid_depth_max
  ]

  # Fields holding samples. The network-wide value is every peer's samples together.
  @list_merged [
    :repair_latency_edits,
    :repair_latency_ms,
    :reissued_lines_per_conflict,
    :mac_sample_ns
  ]

  @type metadata ::
          record(:metadata,
            delete_valid_counter: integer(),
            delete_stash_counter: integer(),
            requeue_counter: integer(),
            delete_requeue_limit: integer(),
            insert_distance_greater_than_one: integer(),
            insert_request_counter: integer(),
            insert_request_limit_counter: integer(),
            insert_stash_counter: integer(),
            insert_valid_counter: integer(),
            insert_stash_fail_counter: integer(),
            byzantine_insert_counter: integer(),
            byzantine_delete_counter: integer(),
            byzantine_replay_counter: integer(),
            replay_rejected_counter: integer(),
            ack_rejected_counter: integer(),
            admission_rejected_counter: integer(),
            delete_rejected_counter: integer(),
            heap_size: integer(),
            message_queue_length: integer(),
            settle_counter: integer(),
            conflict_detected_counter: integer(),
            replacement_issued_counter: integer(),
            fetch_request_sent: integer(),
            fetch_served: integer(),
            origin_log_bytes: integer(),
            alias_entries: integer(),
            delete_followed_alias: integer(),
            reissue_superseded_deleted: integer(),
            live_duplicates_max: integer(),
            conflicts_observed: integer(),
            concurrent_conflicts: integer(),
            max_concurrent_conflicts: integer(),
            repair_latency_edits: [integer()],
            repair_latency_ms: [integer()],
            reissued_lines_per_conflict: [integer()],
            bytes_insert: integer(),
            bytes_delete: integer(),
            bytes_ack: integer(),
            bytes_fetch: integer(),
            bytes_other: integer(),
            msgs_insert: integer(),
            msgs_delete: integer(),
            msgs_ack: integer(),
            msgs_fetch: integer(),
            msgs_other: integer(),
            mac_calls_doc: integer(),
            mac_calls_ins: integer(),
            mac_calls_del: integer(),
            mac_calls_ack: integer(),
            mac_calls_adm: integer(),
            mac_calls_fetch: integer(),
            mac_sampled_calls: integer(),
            mac_sampled_ns: integer(),
            mac_sample_ns: [integer()],
            pid_depth_max: integer(),
            pid_depth_sum: integer(),
            pid_depth_lines: integer()
          )

  @doc """
  The record as a plain map keyed by field name, for encoding and for tests.

  Every field of the record appears, so a counter added to `@metadata_fields` reaches the
  saved artifact without a second edit here.
  """
  @spec to_map(metadata()) :: %{String.t() => integer() | [integer()]}
  def to_map(metadata) do
    Map.new(@field_names, fn name ->
      {Atom.to_string(name), elem(metadata, Map.fetch!(@field_index, name))}
    end)
  end

  # Quantities that are ratios of two recorded fields. They are written into the artifact
  # rather than left to the analysis because the pair they are derived from is easy to
  # combine wrongly: the mean position depth over a network is the mean over all its lines,
  # not the mean of the per-peer means, and the mean authenticator time is over the sampled
  # calls, not over all of them. A denominator of zero means the quantity was never
  # observed, which is reported as null rather than as zero.
  @spec derived(metadata()) :: %{String.t() => float() | nil}
  defp derived(metadata) do
    %{
      "pid_depth_mean" =>
        ratio(metadata(metadata, :pid_depth_sum), metadata(metadata, :pid_depth_lines)),
      "mac_mean_us" =>
        ratio(metadata(metadata, :mac_sampled_ns), metadata(metadata, :mac_sampled_calls) * 1_000),
      "mac_median_us" => median_us(metadata(metadata, :mac_sample_ns)),
      "bytes_per_insert" =>
        ratio(metadata(metadata, :bytes_insert), metadata(metadata, :msgs_insert)),
      "bytes_per_delete" =>
        ratio(metadata(metadata, :bytes_delete), metadata(metadata, :msgs_delete)),
      "bytes_per_ack" => ratio(metadata(metadata, :bytes_ack), metadata(metadata, :msgs_ack)),
      "bytes_total" =>
        metadata(metadata, :bytes_insert) + metadata(metadata, :bytes_delete) +
          metadata(metadata, :bytes_ack) + metadata(metadata, :bytes_fetch) +
          metadata(metadata, :bytes_other)
    }
  end

  @spec ratio(number(), number()) :: float() | nil
  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  # The median of the sampled authenticator timings, in microseconds. Reported alongside the
  # mean because the two disagree by a large factor under load, and the median is the one
  # that describes the computation rather than the scheduling around it.
  @spec median_us([non_neg_integer()]) :: float() | nil
  defp median_us([]), do: nil

  defp median_us(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    middle = div(count, 2)

    nanoseconds =
      if rem(count, 2) == 1 do
        Enum.at(sorted, middle)
      else
        (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
      end

    nanoseconds / 1_000
  end

  # Every snapshot carries the description of the run that produced it. A measurement is
  # only readable next to the configuration it was taken under, and a file that has to be
  # matched to a configuration by its position in a directory tree will eventually be
  # matched to the wrong one.
  defp get_metadata_json(metadata, current_commit, current_date_unix, byzantine_nodes) do
    metadata_map =
      metadata
      |> to_map()
      |> Map.merge(derived(metadata))
      |> Map.merge(%{
        "byzantine_nodes" => byzantine_nodes,
        "current_commit" => current_commit,
        "timestamp" => current_date_unix,
        "run" => Syncordian.Run.to_map()
      })

    Jason.encode!(metadata_map, pretty: true)
  end

  # Saves metadata to a file with a path based on the given parameters.
  defp save_metadata_to_file(
         metadata,
         current_commit,
         byzantine_nodes,
         directory,
         name \\ "commit"
       ) do
    current_date_unix = System.os_time(:second) |> to_string()

    metadata_json =
      get_metadata_json(metadata, current_commit, current_date_unix, byzantine_nodes)

    basename =
      if byzantine_nodes == 0,
        do: "#{name}_#{current_commit}.json",
        else: "byzantine_nodes_#{byzantine_nodes}_#{name}_#{current_commit}.json"

    File.mkdir_p!(directory)
    File.write(Path.join(directory, basename), metadata_json)
  end

  @doc """
    Saves metadata for an individual peer. This function is used for keep track of just
    one peer's metadata.
  """
  def save_metadata_one_peer(metadata, current_commit, module_name, name \\ "commit") do
    save_metadata_to_file(
      metadata,
      current_commit,
      0,
      Syncordian.Run.path("metadata/individual_peer/#{module_name}"),
      name
    )
  end

  @doc """
    Saves metadata with specified number of byzantine nodes. This function is ment to
    be use by the supervisor for saving the agregated info of all the peers.
  """
  @spec save_metadata(metadata(), integer(), integer(), String.t()) :: :ok
  def save_metadata(metadata, byzantine_nodes, current_commit, module_name) do
    save_metadata_to_file(
      metadata,
      current_commit,
      byzantine_nodes,
      Syncordian.Run.path("metadata/supervisor/#{module_name}")
    )
  end

  @doc """
  Combines two metadata records into one, field by field.

  Used by the supervisor to aggregate the per-peer records collected after a commit into a
  single network-wide snapshot. Most fields are totals and are summed. Two kinds are not,
  and combining them wrongly would report a network that never existed:

    * a high-water mark (`#{inspect(@max_merged)}`) is a property of one replica at one
      moment, so the network-wide value is the largest any peer reported; and
    * a sample list (`#{inspect(@list_merged)}`) is a set of observations, so the
      network-wide value is all of them together.

  The rule is applied by walking the field list the record is built from, so a field added
  there is merged by one of these three rules rather than being silently dropped.
  """
  @spec merge_metadata(metadata(), metadata()) :: metadata()
  def merge_metadata(metadata1, metadata2) do
    Enum.reduce(@field_names, metadata(), fn name, acc ->
      index = Map.fetch!(@field_index, name)
      put_elem(acc, index, combine(name, elem(metadata1, index), elem(metadata2, index)))
    end)
  end

  @spec combine(atom(), term(), term()) :: term()
  defp combine(name, value1, value2) do
    cond do
      name in @max_merged -> max(value1, value2)
      name in @list_merged -> value1 ++ value2
      true -> value1 + value2
    end
  end

  @doc """
  Records the peer process's current memory footprint.

  Stores `bytes` as the heap size and reads the live message-queue length of
  `peer_pid` via `Syncordian.Utilities.process_memory_info/1`. Called before each
  metadata snapshot so heap growth and backlog can be plotted over the run.
  """
  @spec update_memory_info(metadata(), Syncordian.Basic_Types.peer_id(), integer()) :: metadata()
  def update_memory_info(metadata, peer_pid, bytes) do
    [_heap_size, message_queue_len] = peer_pid |> process_memory_info()
    metadata(metadata, heap_size: bytes, message_queue_length: message_queue_len)
  end

  @doc """
    Counts forged deletes *injected by the adversary* (incremented by the Byzantine
    simulator at send time). On the honest side these forgeries are dropped at admission
    — the simulator cannot recompute the admission authenticator over its tampered
    payload — and are tallied there in `admission_rejected_counter`.
  """
  @spec inc_byzantine_delete_counter(metadata()) :: metadata()
  def inc_byzantine_delete_counter(metadata),
    do:
      metadata(metadata,
        byzantine_delete_counter: metadata(metadata, :byzantine_delete_counter) + 1
      )

  @doc """
    Counts forged inserts *injected by the adversary* (incremented by the Byzantine
    simulator at send time). See `inc_byzantine_delete_counter/1` for where they land on
    the honest side.
  """
  @spec inc_byzantine_insert_counter(metadata()) :: metadata()
  def inc_byzantine_insert_counter(metadata),
    do:
      metadata(metadata,
        byzantine_insert_counter: metadata(metadata, :byzantine_insert_counter) + 1
      )

  @doc """
    Counts genuine messages the adversary captured and re-broadcast unchanged.

    These carry a valid admission authenticator, because they were written by an admitted
    peer, so they are not answered by the admission check. What answers them is the applied
    operation set and the tombstone, and a replay held long enough to outlive the collection
    of that set is answered by the tombstone alone. That is the execution this counter
    reports on.
  """
  @spec inc_byzantine_replay_counter(metadata()) :: metadata()
  def inc_byzantine_replay_counter(metadata),
    do:
      metadata(metadata,
        byzantine_replay_counter: metadata(metadata, :byzantine_replay_counter) + 1
      )

  @doc """
    Counts retransmission requests this peer sent because a suspended operation's dependency
    was overdue (`Syncordian.OpLog`, the requester side of anti-entropy).
  """
  @spec inc_fetch_request_sent(metadata()) :: metadata()
  def inc_fetch_request_sent(metadata),
    do: metadata(metadata, fetch_request_sent: metadata(metadata, :fetch_request_sent) + 1)

  @doc """
    Adds `n` to the count of operations this peer re-sent as an origin in answer to fetch
    requests (the origin side of anti-entropy). `n` is the number of stored broadcasts one
    request was served.
  """
  @spec inc_fetch_served_times(metadata(), non_neg_integer()) :: metadata()
  def inc_fetch_served_times(metadata, n),
    do: metadata(metadata, fetch_served: metadata(metadata, :fetch_served) + n)

  @doc """
    Records the byte size of this peer's origin log for the run metadata (a gauge, set at
    each snapshot).
  """
  @spec set_origin_log_bytes(metadata(), non_neg_integer()) :: metadata()
  def set_origin_log_bytes(metadata, bytes),
    do: metadata(metadata, origin_log_bytes: bytes)

  @doc """
    Counts operations dropped as replays: an insert/delete broadcast whose `op_id` was
    already applied within the receiver's bounded seen-set (`Syncordian.SeenOps`).
  """
  @spec inc_replay_rejected_counter(metadata()) :: metadata()
  def inc_replay_rejected_counter(metadata),
    do:
      metadata(metadata,
        replay_rejected_counter: metadata(metadata, :replay_rejected_counter) + 1
      )

  @doc """
    Counts insertion responses that passed admission but whose response tag does not
    verify against the acknowledged line's stored signature and the claimed peer (a
    stale or mismatched acknowledgement; defense in depth behind the admission check).
  """
  @spec inc_ack_rejected_counter(metadata()) :: metadata()
  def inc_ack_rejected_counter(metadata),
    do:
      metadata(metadata,
        ack_rejected_counter: metadata(metadata, :ack_rejected_counter) + 1
      )

  @doc """
    Counts messages dropped at admission: the admission authenticator does not verify
    against the boundary secret, so the message is forged or tampered traffic from a
    node that does not hold the secret. Per the formal receipt rule such a message is
    neither applied nor buffered (`Syncordian.Byzantine.check_admission/4`). Forged
    broadcasts from the Byzantine simulator land here.
  """
  @spec inc_admission_rejected_counter(metadata()) :: metadata()
  def inc_admission_rejected_counter(metadata),
    do:
      metadata(metadata,
        admission_rejected_counter: metadata(metadata, :admission_rejected_counter) + 1
      )

  @doc """
    Counts deletes that passed admission but whose authorization tag does not verify
    against the present target line's stored signature. The check is intrinsic to the
    target, so a mismatch is a forgery rather than a reordering — the operation is
    rejected, not suspended. Expected to stay at zero under the modeled outsider, whose
    forgeries already die at admission.
  """
  @spec inc_delete_rejected_counter(metadata()) :: metadata()
  def inc_delete_rejected_counter(metadata),
    do:
      metadata(metadata,
        delete_rejected_counter: metadata(metadata, :delete_rejected_counter) + 1
      )

  @doc "Counts inserts that failed to be stashed for later retry (stash buffer full / invalid)."
  @spec inc_insert_stash_fail_counter(metadata()) :: metadata()
  def inc_insert_stash_fail_counter(metadata),
    do:
      metadata(metadata,
        insert_stash_fail_counter: metadata(metadata, :insert_stash_fail_counter) + 1
      )

  @doc "Counts deletes dropped because they hit the per-operation requeue limit."
  @spec inc_delete_requeue_limit_counter(metadata()) :: metadata()
  def inc_delete_requeue_limit_counter(metadata),
    do:
      metadata(
        metadata,
        delete_requeue_limit: metadata(metadata, :delete_requeue_limit) + 1
      )

  @doc "Counts deletes that verified and were applied to a present target line."
  @spec inc_delete_valid_counter(metadata()) :: metadata()
  def inc_delete_valid_counter(metadata),
    do:
      metadata(metadata,
        delete_valid_counter: metadata(metadata, :delete_valid_counter) + 1
      )

  @doc "Counts deletes stashed for later retry because their target line is not yet present."
  @spec inc_delete_stash_counter(metadata()) :: metadata()
  def inc_delete_stash_counter(metadata),
    do:
      metadata(metadata,
        delete_stash_counter: metadata(metadata, :delete_stash_counter) + 1
      )

  @doc "Counts operations put back on the queue to be retried after their dependency arrives."
  @spec inc_requeue_counter(metadata()) :: metadata()
  def inc_requeue_counter(metadata),
    do:
      metadata(metadata,
        requeue_counter: metadata(metadata, :requeue_counter) + 1
      )

  @doc "Counts inserts whose target gap spanned more than one position (non-adjacent insertion)."
  @spec inc_insert_distance_greater_than_one(metadata()) :: metadata()
  def inc_insert_distance_greater_than_one(metadata),
    do:
      metadata(metadata,
        insert_distance_greater_than_one:
          metadata(metadata, :insert_distance_greater_than_one) + 1
      )

  @doc "Counts insert requests this peer issued (a line broadcast awaiting acknowledgement)."
  @spec inc_insert_request_counter(metadata()) :: metadata()
  def inc_insert_request_counter(metadata),
    do:
      metadata(metadata,
        insert_request_counter: metadata(metadata, :insert_request_counter) + 1
      )

  @doc "Counts insert requests dropped because they exceeded the retry/request limit."
  @spec inc_insert_request_limit_counter(metadata()) :: metadata()
  def inc_insert_request_limit_counter(metadata),
    do:
      metadata(metadata,
        insert_request_limit_counter:
          metadata(
            metadata,
            :insert_request_limit_counter
          ) + 1
      )

  @doc "Counts inserts stashed for later retry because a preceding line is not yet present."
  @spec inc_insert_stash_counter(metadata()) :: metadata()
  def inc_insert_stash_counter(metadata),
    do:
      metadata(metadata,
        insert_stash_counter: metadata(metadata, :insert_stash_counter) + 1
      )

  @doc "Counts inserts that verified and were applied to the document."
  @spec inc_insert_valid_counter(metadata()) :: metadata()
  def inc_insert_valid_counter(metadata),
    do:
      metadata(metadata,
        insert_valid_counter: metadata(metadata, :insert_valid_counter) + 1
      )

  @doc """
    Counts lines this peer transitioned :aura -> :settled once their response checklist
    filled (every trusted peer acknowledged the line). See the ack case of `def:apply` in
    the formal model.
  """
  @spec inc_settle_counter(metadata()) :: metadata()
  def inc_settle_counter(metadata),
    do: metadata(metadata, settle_counter: metadata(metadata, :settle_counter) + 1)

  @doc """
    Counts interleaving conflicts detected: a live line of one authored block found
    lord-strictly between two live lines of another distinct-writer block
    (`Syncordian.Interleaving`, `def:intention`).
  """
  @spec inc_conflict_detected_counter(metadata()) :: metadata()
  def inc_conflict_detected_counter(metadata),
    do:
      metadata(metadata,
        conflict_detected_counter: metadata(metadata, :conflict_detected_counter) + 1
      )

  @doc """
    Counts re-placement inserts this peer issued as the lower-priority block's writer to
    resolve an interleaving (the suffix re-issued at fresh, disjoint positions; see
    `sec:formal-intention`).
  """
  @spec inc_replacement_issued_counter(metadata()) :: metadata()
  def inc_replacement_issued_counter(metadata),
    do:
      metadata(metadata,
        replacement_issued_counter: metadata(metadata, :replacement_issued_counter) + 1
      )

  @doc """
    Counts deletes that reached the current copy of moved content by following the alias
    chain of a re-issued line, rather than by naming it directly. Each count is one
    occurrence of the delete-after-move race, resolved.
  """
  @spec inc_delete_followed_alias(metadata()) :: metadata()
  def inc_delete_followed_alias(metadata),
    do:
      metadata(metadata,
        delete_followed_alias: metadata(metadata, :delete_followed_alias) + 1
      )

  @doc """
    Counts re-issued lines that were born as tombstones because the line they supersede had
    already been deleted here. Each count is one occurrence of the move-after-delete race,
    resolved.
  """
  @spec inc_reissue_superseded_deleted(metadata()) :: metadata()
  def inc_reissue_superseded_deleted(metadata),
    do:
      metadata(metadata,
        reissue_superseded_deleted: metadata(metadata, :reissue_superseded_deleted) + 1
      )

  @doc """
    Records the alias-map snapshot of a peer: how many of its lines have been superseded by
    a move, and how many superseded/replacement pairs are live at the same time. The second
    value is 0 by construction, since a re-issue retracts the line it replaces in the same
    step, so it is reported as a witness of that invariant.
  """
  @spec set_alias_gauges(metadata(), non_neg_integer(), non_neg_integer()) :: metadata()
  def set_alias_gauges(metadata, entries, live_duplicates),
    do:
      metadata(metadata,
        alias_entries: entries,
        live_duplicates_max: max(metadata(metadata, :live_duplicates_max), live_duplicates)
      )

  @doc """
  Records the interleavings this replica is currently holding.

  `newly_seen` is how many of them were not present at the previous observation, and
  `current` is how many are unresolved now. Called after every applied operation, since that
  is when the set of conflicts can change, and it is the only place a transient interleaving
  is visible at all: an interleaving that appears and is repaired between two snapshots
  leaves no trace in the document.
  """
  @spec observe_conflicts(metadata(), non_neg_integer(), non_neg_integer()) :: metadata()
  def observe_conflicts(metadata, newly_seen, current),
    do:
      metadata(metadata,
        conflicts_observed: metadata(metadata, :conflicts_observed) + newly_seen,
        concurrent_conflicts: current,
        max_concurrent_conflicts: max(metadata(metadata, :max_concurrent_conflicts), current)
      )

  @doc """
  Records one repaired interleaving: how many applied edits it stood for, and how many
  milliseconds.

  One sample per conflict that appeared and later disappeared at this replica. A conflict
  still open when the run ends contributes no sample, so the reported distribution is over
  repairs that completed, which is what the durations mean.
  """
  @spec record_repair(metadata(), non_neg_integer(), non_neg_integer()) :: metadata()
  def record_repair(metadata, edits, milliseconds),
    do:
      metadata(metadata,
        repair_latency_edits: [edits | metadata(metadata, :repair_latency_edits)],
        repair_latency_ms: [milliseconds | metadata(metadata, :repair_latency_ms)]
      )

  @doc """
  Records how many lines one re-placement had to re-issue.

  A repair costs a whole block rather than a single operation, so this is the amplification
  factor between conflicts detected and operations produced.
  """
  @spec record_reissued_lines(metadata(), non_neg_integer()) :: metadata()
  def record_reissued_lines(metadata, lines),
    do:
      metadata(metadata,
        reissued_lines_per_conflict: [
          lines | metadata(metadata, :reissued_lines_per_conflict)
        ]
      )

  @doc """
  Records the position-identifier depth over a replica's document: the deepest identifier,
  the total depth, and the number of lines it was taken over.

  A gauge, set at each snapshot. The sum and the count travel together so the mean over a
  network is the mean over its lines.
  """
  @spec set_pid_depth(metadata(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          metadata()
  def set_pid_depth(metadata, depth_max, depth_sum, lines),
    do:
      metadata(metadata,
        pid_depth_max: max(metadata(metadata, :pid_depth_max), depth_max),
        pid_depth_sum: depth_sum,
        pid_depth_lines: lines
      )

  # Wire kinds and authenticator domains, paired with the fields they accumulate into. The
  # names are the ones `Syncordian.Instrument` reports.
  @wire_fields [
    insert: {:bytes_insert, :msgs_insert},
    delete: {:bytes_delete, :msgs_delete},
    ack: {:bytes_ack, :msgs_ack},
    fetch: {:bytes_fetch, :msgs_fetch},
    other: {:bytes_other, :msgs_other}
  ]

  @mac_fields [
    doc: :mac_calls_doc,
    ins: :mac_calls_ins,
    del: :mac_calls_del,
    ack: :mac_calls_ack,
    adm: :mac_calls_adm,
    fetch: :mac_calls_fetch
  ]

  @doc """
  Folds the process-local cost accumulators of `Syncordian.Instrument` into this record.

  Bytes put on the wire and authenticator computations are paid inside functions that hold
  no peer state, so they accumulate in the peer's process and are folded in here at each
  snapshot.

  The fields are *assigned*, not added to. Both the accumulators and this record are
  cumulative over the life of the same peer, so they hold the same quantity and assignment
  keeps them equal. It also makes the fold idempotent, which matters because a snapshot may
  be taken more than once between two reports and a snapshot whose result is discarded must
  not lose the work it described.
  """
  @spec absorb_instruments(metadata()) :: metadata()
  def absorb_instruments(metadata) do
    %{wire: wire, mac: mac, mac_time: {samples, nanoseconds, values}} =
      Syncordian.Instrument.snapshot()

    metadata =
      Enum.reduce(@wire_fields, metadata, fn {kind, {bytes_field, count_field}}, acc ->
        {messages, bytes} = Map.get(wire, kind, {0, 0})

        acc
        |> assign(bytes_field, bytes)
        |> assign(count_field, messages)
      end)

    Enum.reduce(@mac_fields, metadata, fn {domain, field}, acc ->
      assign(acc, field, Map.get(mac, domain, 0))
    end)
    |> assign(:mac_sampled_calls, samples)
    |> assign(:mac_sampled_ns, nanoseconds)
    |> assign(:mac_sample_ns, values)
  end

  @spec assign(metadata(), atom(), number()) :: metadata()
  defp assign(metadata, field, value),
    do: put_elem(metadata, Map.fetch!(@field_index, field), value)
end
