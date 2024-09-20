defmodule Syncordian.Metadata do
  require Record

  Record.defrecord(:metadata,
    delete_valid_counter: 0,
    delete_stash_counter: 0,
    delete_requeue_counter: 0,
    delete_requeue_limit: 0,
    insert_distance_greater_than_one: 0,
    insert_request_counter: 0,
    insert_request_limit_counter: 0,
    insert_stash_counter: 0,
    insert_valid_counter: 0,
    insert_stash_fail_counter: 0,
    byzantine_insert_counter: 0,
    byzantine_delete_counter: 0
  )

  @type metadata ::
          record(:metadata,
            delete_valid_counter: integer(),
            delete_stash_counter: integer(),
            delete_requeue_counter: integer(),
            delete_requeue_limit: integer(),
            insert_distance_greater_than_one: integer(),
            insert_request_counter: integer(),
            insert_request_limit_counter: integer(),
            insert_stash_counter: integer(),
            insert_valid_counter: integer(),
            insert_stash_fail_counter: integer()
          )
  @spec print_metadata(metadata()) :: :ok
  def print_metadata(metadata) do
    IO.puts("")
    IO.puts("---------------------------------------------------------------------------")
    IO.puts("Metadata Record:")
    IO.puts("  delete_valid_counter: #{metadata(metadata, :delete_valid_counter)}")
    IO.puts("  delete_stash_counter: #{metadata(metadata, :delete_stash_counter)}")
    IO.puts("  delete_requeue_counter: #{metadata(metadata, :delete_requeue_counter)}")
    IO.puts("  delete_requeue_limit: #{metadata(metadata, :delete_requeue_limit)}")

    IO.puts(
      "  insert_distance_greater_than_one: #{metadata(metadata,
      :insert_distance_greater_than_one)}"
    )

    IO.puts("  insert_request_counter: #{metadata(metadata, :insert_request_counter)}")

    IO.puts(
      "  insert_request_limit_counter: #{metadata(metadata,
      :insert_request_limit_counter)}"
    )

    IO.puts("  insert_stash_counter: #{metadata(metadata, :insert_stash_counter)}")
    IO.puts("  insert_valid_counter: #{metadata(metadata, :insert_valid_counter)}")

    IO.puts(
      "  insert_stash_fail_counter: #{metadata(metadata,
      :insert_stash_fail_counter)}"
    )

    IO.puts(
      "  byzantine_insert_counter: #{metadata(metadata,
      :byzantine_insert_counter)}"
    )

    IO.puts(
      "  byzantine_delete_counter: #{metadata(metadata,
      :byzantine_delete_counter)}"
    )

    IO.puts("---------------------------------------------------------------------------")
    IO.puts("")
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
      delete_requeue_counter:
        metadata(metadata1, :delete_requeue_counter) +
          metadata(metadata2, :delete_requeue_counter),
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
          metadata(metadata2, :byzantine_delete_counter)
    )
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

  @spec inc_delete_requeue_counter(metadata()) :: metadata()
  def inc_delete_requeue_counter(metadata),
    do:
      metadata(metadata,
        delete_requeue_counter: metadata(metadata, :delete_requeue_counter) + 1
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
