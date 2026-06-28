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

  Record.defrecord(:metadata,
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
    replay_rejected_counter: 0,
    ack_rejected_counter: 0,
    admission_rejected_counter: 0,
    delete_rejected_counter: 0,
    heap_size: 0,
    message_queue_length: 0,
    settle_counter: 0,
    conflict_detected_counter: 0,
    replacement_issued_counter: 0
  )

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
            replay_rejected_counter: integer(),
            ack_rejected_counter: integer(),
            admission_rejected_counter: integer(),
            delete_rejected_counter: integer(),
            heap_size: integer(),
            message_queue_length: integer(),
            settle_counter: integer(),
            conflict_detected_counter: integer(),
            replacement_issued_counter: integer()
          )

  defp get_metadata_json(metadata, current_commit, current_date_unix, byzantine_nodes) do
    metadata_map = %{
      "delete_valid_counter" => metadata(metadata, :delete_valid_counter),
      "delete_stash_counter" => metadata(metadata, :delete_stash_counter),
      "requeue_counter" => metadata(metadata, :requeue_counter),
      "delete_requeue_limit" => metadata(metadata, :delete_requeue_limit),
      "insert_distance_greater_than_one" => metadata(metadata, :insert_distance_greater_than_one),
      "insert_request_counter" => metadata(metadata, :insert_request_counter),
      "insert_request_limit_counter" => metadata(metadata, :insert_request_limit_counter),
      "insert_stash_counter" => metadata(metadata, :insert_stash_counter),
      "insert_valid_counter" => metadata(metadata, :insert_valid_counter),
      "insert_stash_fail_counter" => metadata(metadata, :insert_stash_fail_counter),
      "byzantine_insert_counter" => metadata(metadata, :byzantine_insert_counter),
      "byzantine_delete_counter" => metadata(metadata, :byzantine_delete_counter),
      "replay_rejected_counter" => metadata(metadata, :replay_rejected_counter),
      "ack_rejected_counter" => metadata(metadata, :ack_rejected_counter),
      "admission_rejected_counter" => metadata(metadata, :admission_rejected_counter),
      "delete_rejected_counter" => metadata(metadata, :delete_rejected_counter),
      "heap_size" => metadata(metadata, :heap_size),
      "message_queue_length" => metadata(metadata, :message_queue_length),
      "settle_counter" => metadata(metadata, :settle_counter),
      "conflict_detected_counter" => metadata(metadata, :conflict_detected_counter),
      "replacement_issued_counter" => metadata(metadata, :replacement_issued_counter),
      "byzantine_nodes" => byzantine_nodes,
      "current_commit" => current_commit,
      "timestamp" => current_date_unix
    }

    Jason.encode!(metadata_map, pretty: true)
  end

  # Saves metadata to a file with a path based on the given parameters.
  defp save_metadata_to_file(
         metadata,
         current_commit,
         byzantine_nodes,
         path_prefix,
         name \\ "commit"
       ) do
    current_date_unix = System.os_time(:second) |> to_string()

    metadata_json =
      get_metadata_json(metadata, current_commit, current_date_unix, byzantine_nodes)

    filename =
      if byzantine_nodes == 0,
        do: "#{path_prefix}#{name}_#{current_commit}.json",
        else: "#{path_prefix}byzantine_nodes_#{byzantine_nodes}_#{name}_#{current_commit}.json"

    File.write(filename, metadata_json)
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
      "debug/metadata/individual_peer/#{module_name}/",
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
      "debug/metadata/supervisor/#{module_name}"
    )
  end

  @doc """
  Field-wise sums two metadata records into one.

  Used by the supervisor to aggregate the per-peer records collected after a
  commit into a single network-wide snapshot. Every counter in the result is the
  sum of the corresponding counters in `metadata1` and `metadata2`.
  """
  @spec merge_metadata(metadata(), metadata()) :: metadata()
  def merge_metadata(metadata1, metadata2) do
    metadata(
      delete_valid_counter:
        metadata(metadata1, :delete_valid_counter) +
          metadata(metadata2, :delete_valid_counter),
      delete_stash_counter:
        metadata(metadata1, :delete_stash_counter) +
          metadata(metadata2, :delete_stash_counter),
      requeue_counter:
        metadata(metadata1, :requeue_counter) +
          metadata(metadata2, :requeue_counter),
      delete_requeue_limit:
        metadata(metadata1, :delete_requeue_limit) +
          metadata(metadata2, :delete_requeue_limit),
      insert_distance_greater_than_one:
        metadata(metadata1, :insert_distance_greater_than_one) +
          metadata(metadata2, :insert_distance_greater_than_one),
      insert_request_counter:
        metadata(metadata1, :insert_request_counter) +
          metadata(metadata2, :insert_request_counter),
      insert_request_limit_counter:
        metadata(metadata1, :insert_request_limit_counter) +
          metadata(metadata2, :insert_request_limit_counter),
      insert_stash_counter:
        metadata(metadata1, :insert_stash_counter) +
          metadata(metadata2, :insert_stash_counter),
      insert_valid_counter:
        metadata(metadata1, :insert_valid_counter) +
          metadata(metadata2, :insert_valid_counter),
      insert_stash_fail_counter:
        metadata(metadata1, :insert_stash_fail_counter) +
          metadata(metadata2, :insert_stash_fail_counter),
      byzantine_insert_counter:
        metadata(metadata1, :byzantine_insert_counter) +
          metadata(metadata2, :byzantine_insert_counter),
      byzantine_delete_counter:
        metadata(metadata1, :byzantine_delete_counter) +
          metadata(metadata2, :byzantine_delete_counter),
      replay_rejected_counter:
        metadata(metadata1, :replay_rejected_counter) +
          metadata(metadata2, :replay_rejected_counter),
      ack_rejected_counter:
        metadata(metadata1, :ack_rejected_counter) +
          metadata(metadata2, :ack_rejected_counter),
      admission_rejected_counter:
        metadata(metadata1, :admission_rejected_counter) +
          metadata(metadata2, :admission_rejected_counter),
      delete_rejected_counter:
        metadata(metadata1, :delete_rejected_counter) +
          metadata(metadata2, :delete_rejected_counter),
      heap_size: metadata(metadata1, :heap_size) + metadata(metadata2, :heap_size),
      message_queue_length:
        metadata(metadata1, :message_queue_length) +
          metadata(metadata2, :message_queue_length),
      settle_counter: metadata(metadata1, :settle_counter) + metadata(metadata2, :settle_counter),
      conflict_detected_counter:
        metadata(metadata1, :conflict_detected_counter) +
          metadata(metadata2, :conflict_detected_counter),
      replacement_issued_counter:
        metadata(metadata1, :replacement_issued_counter) +
          metadata(metadata2, :replacement_issued_counter)
    )
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
end
