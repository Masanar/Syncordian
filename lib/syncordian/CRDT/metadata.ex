defmodule Syncordian.Metadata do
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
    heap_size: 0,
    message_queue_length: 0
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
            heap_size: integer(),
            message_queue_length: integer()
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
      "heap_size" => metadata(metadata, :heap_size),
      "message_queue_length" => metadata(metadata, :message_queue_length),
      "byzantine_nodes" => byzantine_nodes,
      "current_commit" => current_commit,
      "timestamp" => current_date_unix
    }

    Jason.encode!(metadata_map, pretty: true)
  end

  # Saves metadata to a file with a path based on the given parameters.
  defp save_metadata_to_file(metadata, current_commit, byzantine_nodes, path_prefix, name \\ "commit") do
    current_date_unix = System.os_time(:second) |> to_string()

    metadata_json =
      get_metadata_json(metadata, current_commit, current_date_unix, byzantine_nodes)

    filename =
      if byzantine_nodes == 0,
        do: "#{path_prefix}#{name}_#{current_commit}_#{current_date_unix}.json",
        else:
          "#{path_prefix}byzantine_nodes_#{byzantine_nodes}_#{name}_#{current_commit}_#{current_date_unix}.json"

    File.write(filename, metadata_json)
  end

  @doc """
    Saves metadata for an individual peer. This function is used for keep track of just
    one peer's metadata.
  """
  def save_metadata_one_peer(metadata, current_commit, module_name, name\\"commit") do
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
      heap_size: metadata(metadata1, :heap_size) + metadata(metadata2, :heap_size),
      message_queue_length:
        metadata(metadata1, :message_queue_length) +
          metadata(metadata2, :message_queue_length)
    )
  end

  @spec update_memory_info(metadata(), Syncordian.Basic_Types.peer_id(), integer()) :: metadata()
  def update_memory_info(metadata, peer_pid, bytes) do
    [_heap_size, message_queue_len] = peer_pid |> process_memory_info()
    metadata(metadata, heap_size: bytes, message_queue_length: message_queue_len)
  end

  @spec inc_byzantine_delete_counter(metadata()) :: metadata()
  def inc_byzantine_delete_counter(metadata),
    do:
      metadata(metadata,
        byzantine_delete_counter: metadata(metadata, :byzantine_delete_counter) + 1
      )

  @spec inc_byzantine_insert_counter(metadata()) :: metadata()
  def inc_byzantine_insert_counter(metadata),
    do:
      metadata(metadata,
        byzantine_insert_counter: metadata(metadata, :byzantine_insert_counter) + 1
      )

  @spec inc_insert_stash_fail_counter(metadata()) :: metadata()
  def inc_insert_stash_fail_counter(metadata),
    do:
      metadata(metadata,
        insert_stash_fail_counter: metadata(metadata, :insert_stash_fail_counter) + 1
      )

  @spec inc_delete_requeue_limit_counter(metadata()) :: metadata()
  def inc_delete_requeue_limit_counter(metadata),
    do:
      metadata(
        metadata,
        delete_requeue_limit: metadata(metadata, :delete_requeue_limit) + 1
      )

  @spec inc_delete_valid_counter(metadata()) :: metadata()
  def inc_delete_valid_counter(metadata),
    do:
      metadata(metadata,
        delete_valid_counter: metadata(metadata, :delete_valid_counter) + 1
      )

  @spec inc_delete_stash_counter(metadata()) :: metadata()
  def inc_delete_stash_counter(metadata),
    do:
      metadata(metadata,
        delete_stash_counter: metadata(metadata, :delete_stash_counter) + 1
      )

  @spec inc_requeue_counter(metadata()) :: metadata()
  def inc_requeue_counter(metadata),
    do:
      metadata(metadata,
        requeue_counter: metadata(metadata, :requeue_counter) + 1
      )

  @spec inc_insert_distance_greater_than_one(metadata()) :: metadata()
  def inc_insert_distance_greater_than_one(metadata),
    do:
      metadata(metadata,
        insert_distance_greater_than_one:
          metadata(metadata, :insert_distance_greater_than_one) + 1
      )

  @spec inc_insert_request_counter(metadata()) :: metadata()
  def inc_insert_request_counter(metadata),
    do:
      metadata(metadata,
        insert_request_counter: metadata(metadata, :insert_request_counter) + 1
      )

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

  @spec inc_insert_stash_counter(metadata()) :: metadata()
  def inc_insert_stash_counter(metadata),
    do:
      metadata(metadata,
        insert_stash_counter: metadata(metadata, :insert_stash_counter) + 1
      )

  @spec inc_insert_valid_counter(metadata()) :: metadata()
  def inc_insert_valid_counter(metadata),
    do:
      metadata(metadata,
        insert_valid_counter: metadata(metadata, :insert_valid_counter) + 1
      )
end
