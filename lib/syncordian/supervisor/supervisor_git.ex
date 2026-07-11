defmodule Syncordian.Supervisor do
  @moduledoc """
    This module provides functionality for managing test edits in a Git repository.

    ## Usage

    1. Start the supervisor by calling `Syncordian.Test_Git_Supervisor.init/0`.
    2. The supervisor will parse the Git log and retrieve a list of commits.
    3. For each commit, the supervisor will retrieve the author and the position changes.
    4. The position changes will be applied to the corresponding peer using `parse_edits/2`.
    5. Finally, the supervisor will terminate all the processes.

    ## Functions

    - `parse_edit/2` : Parses a single edit and applies it to the specified peer.
    - `parse_edits/2`: Parses a list of edits and applies them to the specified peer.
    - `start_edit/4` : ...
    - `start_edit/3` : ...
    - `init_peers/1` : Initializes the peers based on the list of authors.
    - `init/0`       : Initializes the supervisor and starts the process of applying edits.

  """
  require Record
  # import Syncordian.Peer
  import Syncordian.Metadata
  import Syncordian.GitParser
  import Syncordian.Utilities
  import Syncordian.ByzantinePeer

  Record.defrecord(:supervisor,
    list_of_commits: [],
    commit_group_map: %{},
    pid_list_author_peers: [],
    map_peer_id_authors: %{},
    commit_counter: 0,
    byzantine_nodes: 0,
    peer_metadata_map: %{},
    peer_module: nil
  )

  @type supervisor ::
          record(:supervisor,
            list_of_commits: list(),
            commit_group_map: map(),
            pid_list_author_peers: list(),
            map_peer_id_authors: map(),
            commit_counter: integer(),
            byzantine_nodes: integer(),
            peer_metadata_map: map(),
            peer_module: module()
          )

  @spec get_peer_module(supervisor()) :: module()
  defp get_peer_module(supervisor), do: supervisor(supervisor, :peer_module)

  @spec get_peer_module_string(supervisor()) :: String.t()
  defp get_peer_module_string(supervisor) do
    module = get_peer_module(supervisor)
    module.get_module_name()
  end

  @spec supervisor(supervisor(), atom()) :: integer()
  defp get_commit_counter(supervisor), do: supervisor(supervisor, :commit_counter)

  @spec get_pid_list(supervisor()) :: list()
  defp get_pid_list(supervisor), do: supervisor(supervisor, :pid_list_author_peers)

  # Latest metadata record reported by each peer, keyed by the identifier the peer
  # echoes in {:receive_metadata_from_peer, ...}. Peer counters are cumulative and
  # per-sender message order is preserved, so keeping only the newest report per
  # peer makes the network-wide sum monotone by construction: a snapshot with a
  # lagging peer reuses that peer's previous report instead of dropping it, and a
  # late reply can never be double counted against a fresh one.
  @spec get_peer_metadata_map(supervisor()) :: map()
  defp get_peer_metadata_map(supervisor), do: supervisor(supervisor, :peer_metadata_map)

  @spec put_peer_metadata(supervisor(), term(), Syncordian.Metadata.metadata()) :: supervisor()
  defp put_peer_metadata(supervisor, peer_key, metadata) do
    supervisor(supervisor,
      peer_metadata_map: Map.put(get_peer_metadata_map(supervisor), peer_key, metadata)
    )
  end

  @spec merged_peer_metadata(supervisor()) :: Syncordian.Metadata.metadata()
  defp merged_peer_metadata(supervisor) do
    supervisor
    |> get_peer_metadata_map()
    |> Map.values()
    |> Enum.reduce(Syncordian.Metadata.metadata(), &merge_metadata/2)
  end

  # Parses a single edit and applies it to the specified peer.
  # ## Parameters
  # - `edit`: A map representing the edit to be parsed. It should contain the following
  #   keys:
  #   - `:op`: The operation to be performed. It can be `:insert` or `:delete`.
  #   - `:content`: The content to be inserted (required for `:insert` operation).
  #   - `:index`: The index of the line to be deleted (required for `:delete` operation).
  # - `peer_pid`: The process identifier (PID) of the peer to apply the edit to.
  @spec parse_edit(map(), pid(), integer(), module()) :: integer()
  defp parse_edit(edit, peer_pid, acc, peer_module) do
    # If want to know why the acc is reduced by 1 in the case of a delete operation and
    # increase by 1 in the case of an insert operation, please read the comets of
    # the parse_edits function just below.
    #
    # Zero-old-count hunks (`@@ -0,0`, file creation) anchor their git indices one line
    # early (after-semantics); Syncordian's get_parents_by_index uses uniform
    # before-semantics, so shift those ops by +1 here. Confined to Syncordian so the
    # other CRDTs keep receiving byte-identical op streams.
    shift =
      if peer_module == Syncordian.Peer and Map.get(edit, :zero_old, false),
        do: 1,
        else: 0

    case Map.get(edit, :op) do
      :insert ->
        peer_module.insert(
          peer_pid,
          Map.get(edit, :content),
          Map.get(edit, :index) + acc + shift,
          Map.get(edit, :test_index) + acc + shift,
          Map.get(edit, :global_position),
          Map.get(edit, :current_delete_ops)
        )

        1

      :delete ->
        peer_module.delete_line(
          peer_pid,
          Map.get(edit, :index) + acc + shift,
          Map.get(edit, :test_index) + acc + shift,
          Map.get(edit, :global_position),
          Map.get(edit, :current_delete_ops)
        )

        -1
    end
  end

  # Parses a list of edits and applies them to the specified peer.
  @spec parse_edits(list(), pid(), module()) :: integer()
  defp parse_edits(edits, peer_pid, peer_module) do
    # For you to remember, just in case:
    # The first reduce goes through the list of edits, remember that a commit may have
    # several edits, that is several of the form @@ a,b c,d @. Further, the edits in the
    # edits list come in increasing order by its global position.
    #
    # Les't assume that we have a commit with 2 edits, the first edit must keep the index
    # of the operations  unaffected but the second one must shift the index only by the
    # number of inserts accumulated by previous edits, in this case just the first one.
    # This is the case because the tombstone are calculated based on the global position
    # then we must take into account just the inserts otherwise some tombstones will be
    # counted twice. That is why in parse_edit the acc gets reduced by 1 in the case of
    # a delete operation.
    edits
    |> Enum.reduce(0, fn edit_list, acc_outer ->
      Enum.reduce(edit_list, acc_outer, fn atom_edit, acc_inner ->
        parse_edit(atom_edit, peer_pid, acc_outer, peer_module) + acc_inner
      end)
    end)
  end

  # Starts the process of applying edits for a list of commits.
  # ## Parameters
  # - `commits`: A list of commit hashes representing the commits to be processed.
  # - `commit_group_map`: A map containing commit hashes as keys and commit groups as
  #   values. Each commit group should contain the following keys:
  #   - `:author_id`: The ID of the author who made the commit.
  #   - `:position_changes`: A list of position changes to be applied.
  # - `map_peer_id_authors`: A map that maps author IDs(string) to peer IDs(integer).
  # - `pid_list_author_peers`: A list of peer PIDs corresponding to each author
  #   ID(integer).
  # The function loops through the commits in order, retrieves the corresponding commit
  # group, and applies the position changes to the specified peer. The author ID is used
  # to determine the peer ID, which is then used to retrieve the peer PID from the
  # `pid_list_author_peers`. The position changes are applied using the `parse_edits/2`
  # function.
  defp edit(
         commit_hash,
         parent_hash,
         commit_group_map,
         map_peer_id_authors,
         pid_list_author_peers,
         peer_module
       ) do
    [commit_group] = Map.get(commit_group_map, commit_hash)
    author_id = Map.get(commit_group, :author_id)
    position_changes = Map.get(commit_group, :position_changes)
    peer_id = Map.get(map_peer_id_authors, author_id)
    peer_pid = Enum.at(pid_list_author_peers, peer_id)

    # Replay-fidelity barrier vs. plain pacing. A commit's git indices are only
    # meaningful against the exact file state the commit was authored on, and a
    # length-based readiness check is not enough: the author's replica can reach the
    # required LIVE-LINE COUNT while still missing lines in the middle (remote inserts
    # arrive independently), which silently retargets deletes/anchors inserts one line
    # off — and the author then broadcasts that corruption consistently to everyone.
    # So for Syncordian, BEFORE dispatching a commit, the supervisor holds it until the
    # authoring peer's materialized document byte-matches the parent state
    # (`git show <parent>:<file>`); the replay then paces itself to real network latency
    # instead of a fixed sleep. The other CRDTs have no barrier probe, so they keep the
    # legacy fixed delay (after dispatch, as before).
    if peer_module == Syncordian.Peer and parent_hash != nil do
      await_author_materialization(peer_pid, parent_hash, author_id)
    end

    parse_edits(position_changes, peer_pid, peer_module)

    if peer_module == Syncordian.Peer do
      Process.sleep(commit_dispatch_delay_ms())
    else
      Process.sleep(4000)
    end

    author_id
  end

  # Optional extra pacing on top of the materialization barrier (room for Byzantine
  # traffic and broadcast jitter to interleave between commits); also the delay before
  # the next {:send_all_commits} self-send. Env override > config > default.
  defp commit_dispatch_delay_ms,
    do:
      env_int(
        "SYNCORDIAN_COMMIT_DELAY_MS",
        Application.get_env(:syncordian, :commit_dispatch_delay_ms, 100)
      )

  # Settle window after the last commit, before documents are dumped and the final
  # metadata snapshot is taken. Env override > config > default.
  defp final_settle_ms,
    do:
      env_int(
        "SYNCORDIAN_FINAL_SETTLE_MS",
        Application.get_env(:syncordian, :final_settle_ms, 3_000)
      )

  # Collect/print peer metadata only every N commits (default 1 = every commit, the
  # historical behavior). Long histories with hundreds of peers pay one
  # :erlang.external_size(document) per peer per collection, so replays like the full
  # linux MAINTAINERS log want a sparser cadence. The final post-settle snapshot is
  # taken unconditionally either way.
  defp metadata_every,
    do: max(env_int("SYNCORDIAN_METADATA_EVERY", 1), 1)

  # The every-60s pending dumps during a barrier stall are opt-in: with hundreds of
  # peers a dump wave stalls the whole network (each peer serializes its buffers to
  # disk), turning a slow barrier into a permanent freeze.
  defp pending_dumps_enabled?,
    do: System.get_env("SYNCORDIAN_PENDING_DUMPS") == "1"

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  # Polls the authoring peer until its materialized document hashes equal to the tracked
  # file at `commit_hash`. Deliberately UNBOUNDED: dispatching a commit against the wrong
  # parent state silently corrupts the whole replay (the author broadcasts consistently
  # wrong ops, so peers agree with each other but not with git), which is strictly worse
  # than a visibly stalled run. Every 60s of mismatch it prints a warning; with
  # SYNCORDIAN_PENDING_DUMPS=1 it also snapshots the AWAITED AUTHOR's suspended-op buffer
  # and local-edit FIFO (debug/documents/syncordian/pending/). The dump is scoped to that
  # one peer and opt-in because a dump wave over hundreds of peers freezes the very
  # network the barrier is waiting on.
  @spec await_author_materialization(pid(), String.t(), String.t()) :: :ok
  defp await_author_materialization(peer_pid, commit_hash, author_id) do
    # The line-based document cannot represent a missing final newline (materialization
    # appends "\n" to every live line), so normalize the expected side: a git state that
    # ends without a trailing newline is compared as if it had one.
    content = Syncordian.GitLog.file_at(commit_hash)

    content =
      if content != "" and not String.ends_with?(content, "\n"),
        do: content <> "\n",
        else: content

    expected = :erlang.md5(content)
    warn_at = System.monotonic_time(:millisecond) + 60_000
    poll_author_hash(peer_pid, commit_hash, author_id, expected, warn_at, 0)
    flush_stale_content_hashes()
  end

  defp poll_author_hash(peer_pid, commit_hash, author_id, expected, warn_at, misses) do
    ref = make_ref()
    send(peer_pid, {:request_content_hash, self(), ref})

    got =
      receive do
        {:content_hash, ^ref, hash} -> hash
      after
        1_000 -> :timeout
      end

    cond do
      got == expected ->
        :ok

      System.monotonic_time(:millisecond) > warn_at ->
        IO.puts(
          "WARNING: author #{author_id} has not materialized commit " <>
            "#{String.slice(commit_hash, 0, 10)} after 60s — still waiting" <>
            if(pending_dumps_enabled?(),
              do: "; pending dump written to debug/documents/syncordian/pending/",
              else: " (set SYNCORDIAN_PENDING_DUMPS=1 for a pending dump)"
            )
        )

        if pending_dumps_enabled?(), do: send(peer_pid, {:write_pending_dump})

        poll_author_hash(
          peer_pid,
          commit_hash,
          author_id,
          expected,
          System.monotonic_time(:millisecond) + 60_000,
          misses + 1
        )

      true ->
        # Each probe makes the author build and hash its whole materialized document,
        # so back off once the wait is clearly not sub-second: keeps the author's CPU
        # for actual replication work during long catch-ups.
        Process.sleep(if misses < 20, do: 50, else: 250)
        poll_author_hash(peer_pid, commit_hash, author_id, expected, warn_at, misses + 1)
    end
  end

  # A probe that timed out (mailbox backlog at the author) still gets answered later;
  # those stale {:content_hash, ref, _} replies carry dead refs and would otherwise sit
  # in the supervisor mailbox until the catch-all clause logs them as unknown messages.
  defp flush_stale_content_hashes do
    receive do
      {:content_hash, _, _} -> flush_stale_content_hashes()
    after
      0 -> :ok
    end
  end

  @spec save_current_documents(list(), module()) :: :ok
  defp save_current_documents(pid_list_author_peers, peer_module) do
    Enum.map(0..(length(pid_list_author_peers) - 1), fn x ->
      peer_module.save_content(Enum.at(pid_list_author_peers, x))
    end)

    :ok
  end

  @spec start_edit(integer(), supervisor(), pid(), list(), module()) :: :ok
  defp start_edit(commit_count, supervisor, live_view_pid, list_of_commits, peer_module) do
    commit_group_map = supervisor(supervisor, :commit_group_map)
    map_peer_id_authors = supervisor(supervisor, :map_peer_id_authors)
    pid_list_author_peers = get_pid_list(supervisor)
    commit_hash = Enum.at(list_of_commits, commit_count)
    parent_hash = if commit_count > 0, do: Enum.at(list_of_commits, commit_count - 1)

    author_id =
      edit(
        commit_hash,
        parent_hash,
        commit_group_map,
        map_peer_id_authors,
        pid_list_author_peers,
        peer_module
      )

    response = {:commit_inserted, %{hash: commit_hash, author: author_id}}
    send(live_view_pid, response)
  end

  # Initializes the peers for the Syncordian system based on the list of authors.

  # ## Parameters

  # - `authors_list`: A list of author IDs representing the authors in the system.

  # ## Returns

  # A tuple containing two elements:
  # - The list of peer PIDs in reverse order.
  # - A map that maps author IDs(string) to peer IDs(integer).

  # The function initializes the peers by creating a network of processes. Each author
  # is assigned a unique peer ID, and a corresponding peer process is started. The
  # author IDs are mapped to their respective peer IDs in the resulting map.
  @spec init_peers(list(), module()) :: {list(), map()}
  defp init_peers(authors_list, peer_module) do
    author_count = length(authors_list)
    pool_size = min(author_count, max_peers() || author_count)

    if pool_size < author_count do
      IO.puts("Capping peer pool: #{pool_size} peers for #{author_count} authors (round-robin)")
    end

    pid_list =
      Enum.map(0..(pool_size - 1), fn peer_id -> peer_module.start(peer_id, pool_size) end)

    map_ids =
      authors_list
      |> Enum.with_index()
      |> Map.new(fn {author_id, index} -> {author_id, rem(index, pool_size)} end)

    {pid_list, map_ids}
  end

  # Optional cap on the peer pool (env override > config; unset = one peer per author).
  # The history's author count sets the network size, but acknowledgement traffic is
  # O(peers²) per inserted line, so histories with hundreds of authors (linux
  # MAINTAINERS has 277) are unsimulatable on one machine. Capping assigns authors to
  # peers round-robin: a peer simply authors several contributors' commits, which
  # preserves replay semantics — edits stay serialized per peer and the
  # materialization barrier still gates each commit on its authoring peer.
  @spec max_peers() :: pos_integer() | nil
  defp max_peers do
    case System.get_env("SYNCORDIAN_MAX_PEERS") do
      nil -> Application.get_env(:syncordian, :max_peers)
      value -> String.to_integer(value)
    end
  end

  # Byzantine ids are registry names / metadata keys only (byzantine peers never index
  # a vector clock), so the sole requirement is disjointness from the author peer ids
  # 0..pool_size-1. The previous n*73+73 scheme collided with author ids once the pool
  # reached 147 (relevant since MAINTAINERS-scale histories have 279 authors), which
  # made the byzantine :global.register_name fail silently.
  @spec byzantine_peer_id(Syncordian.Basic_Types.peer_id()) ::
          Syncordian.Basic_Types.peer_id()
  defp byzantine_peer_id(peer_id) do
    1_000_000 + peer_id
  end

  @spec init_byzantine_peers(integer()) :: list()
  defp init_byzantine_peers(0), do: []

  defp init_byzantine_peers(byzantine_nodes) do
    Enum.map(1..byzantine_nodes, fn x -> byzantine_peer_id(x) |> start_byzantine_peer() end)
  end

  @doc """
    Initializes the supervisor and starts the process of applying edits.

    The function initializes the supervisor by parsing the Git log and retrieving the list
    of commits. It then groups the commits by author and starts the process of applying
    edits for each commit. Finally, it terminates all the processes started by the
    supervisor.

  """
  @spec init(integer(), Syncordian.Basic_Types.crdt_id()) :: pid()
  def init(byzantine_nodes, crdt_id \\ :syncordian) do
    # Delete the all the files of the debug directory
    # delete_contents("debug/documents")

    # Read the commit history live from the cloned git repository (see Syncordian.GitLog),
    # instead of a static fixture. Fetch the log once and feed both derivations, so a single
    # `git log` invocation drives the whole run.
    log_lines = Syncordian.GitLog.log_lines()
    parsed_git_log = parse_lines(log_lines)
    list_of_commits = commits_from_lines(log_lines)

    # # Prepare the data to save as JSON
    # commit_info =
    #   Enum.with_index(list_of_commits)
    #   |> Enum.map(fn {commit, index} ->
    #     %{
    #       index: index,
    #       commit: String.slice(commit, 0, 8)
    #     }
    #   end)

    # # Save the data as a JSON file
    # file_path = "debug/README_versions/commit_info.json"
    # File.write!(file_path, Jason.encode!(commit_info))

    commit_group_map = group_by_commit(parsed_git_log)

    # Draw this run's document boundary secret {κ⊥, κ⊤} and distribute it out-of-band
    # (via :persistent_term) BEFORE any trusted peer is spawned: peers bake the secret
    # into their boundary sentinel signatures at start, and it keys every admission
    # authenticator. Byzantine peers never read it — that is the outsider-adversary
    # assumption (def:adversary) their rejection guarantee (theo:outsider) rests on.
    Syncordian.Byzantine.generate_boundary_secret()
    |> Syncordian.Byzantine.install_boundary_secret!()

    # Instance all the 30 peers independent  the number of commits in the test file
    {_, authors_list} = group_by_author(parsed_git_log)

    # Choose the proper peer module based on crdt_id.
    peer_module = identify_peer_module(crdt_id)

    {pid_list_author_peers, map_peer_id_authors} = init_peers(authors_list, peer_module)

    supervisor =
      supervisor(
        list_of_commits: list_of_commits,
        commit_group_map: commit_group_map,
        pid_list_author_peers: pid_list_author_peers,
        map_peer_id_authors: map_peer_id_authors,
        peer_module: peer_module
      )

    IO.puts("Byzantine nodes to start #{byzantine_nodes}")
    init_byzantine_peers(byzantine_nodes)

    pid = spawn(__MODULE__, :supervisor_loop, [supervisor])
    :global.register_name(:supervisor, pid)
    pid
  end

  @doc """
  Main receive loop of the supervisor process (the spawned entry point).

  Holds the experiment state record and reacts to messages from the
  `/supervisor` LiveView and from peers:

    * `{:send_next_commit, ...}` — parse and dispatch the next commit's edits
    * `{:send_all_commits, ...}` — replay every remaining commit in a loop
    * `{:write_current_peers_document}` — tell each peer to dump its document
    * `{:collect_metadata_from_peers}` / `{:receive_metadata_from_peer, ...}` —
      request per-peer metadata and record the latest report of each peer
    * `{:print_supervisor_metadata, commit}` — write the merged reports as the
      snapshot for `commit`
    * `{:kill}` — tear the network down

  Not called directly; run via `spawn/3` from `init/2`.
  """
  def supervisor_loop(supervisor) do
    receive do
      {:write_current_peers_document} ->
        peer_module = get_peer_module(supervisor)

        supervisor
        |> get_pid_list()
        |> save_current_documents(peer_module)

        supervisor_loop(supervisor)

      {:send_all_commits, live_view_pid, byzantine_nodes} ->
        peer_module = get_peer_module(supervisor)
        supervisor_counter = supervisor |> get_commit_counter()
        list_of_commits = supervisor(supervisor, :list_of_commits)
        length_of_commits = length(list_of_commits)

        if supervisor_counter < length(list_of_commits) do
          IO.puts(
            "Sending next commit, current counter:  #{supervisor_counter}/#{length_of_commits}"
          )

          start_edit(
            supervisor_counter,
            supervisor,
            live_view_pid,
            list_of_commits,
            peer_module
          )

          # Request fresh reports right after dispatch, snapshot just before the next
          # commit goes out. The snapshot is tagged with the commit number it belongs
          # to, so a print processed after later dispatches still lands in the right
          # file. Peers that miss the window are covered by their previous report
          # (see get_peer_metadata_map/1). Cadence is gated by SYNCORDIAN_METADATA_EVERY
          # (default: every commit); the fixpoint snapshot at the end always runs.
          if rem(supervisor_counter, metadata_every()) == 0 do
            Process.send_after(self(), {:collect_metadata_from_peers}, 10)

            Process.send_after(
              self(),
              {:print_supervisor_metadata, supervisor_counter + 1},
              commit_dispatch_delay_ms()
            )
          end

          Process.send_after(
            self(),
            {:send_all_commits, live_view_pid, byzantine_nodes},
            commit_dispatch_delay_ms()
          )

          supervisor_loop(
            supervisor(supervisor,
              commit_counter: supervisor_counter + 1,
              byzantine_nodes: byzantine_nodes
            )
          )
        else
          IO.puts("All commits processed")

          # The final commit's broadcasts (and any suspended-op cascades they release)
          # are still propagating when the loop reaches this point — the barrier only
          # gated the NEXT commit's author, and there is no next commit. Snapshot every
          # peer's suspended-op buffer for diagnosis, then give the network a settle
          # window before dumping documents, so the convergence check measures the
          # fixpoint rather than the in-flight backlog.
          supervisor
          |> get_pid_list()
          |> Enum.each(&send(&1, {:write_pending_dump}))

          final_settle_ms = final_settle_ms()

          Process.send_after(
            self(),
            {:write_current_peers_document},
            final_settle_ms
          )

          # One last collection after the settle window, overwriting the final
          # per-commit snapshot with the network's fixpoint values (peers are idle
          # by then, so every report is complete and current).
          Process.send_after(self(), {:collect_metadata_from_peers}, final_settle_ms)

          Process.send_after(
            self(),
            {:print_supervisor_metadata, length_of_commits},
            final_settle_ms + 1_000
          )

          # The raw dump feeds the convergence check's no-:aura assertion, so it must
          # capture the post-settle fixpoint like the document dumps above — written
          # at limit-reached time it races the final commit's in-flight acks and
          # reports still-:aura lines that settle milliseconds later.
          pid_individual = supervisor |> get_pid_list() |> Enum.random()
          Process.send_after(pid_individual, {:write_raw_document}, final_settle_ms)
          send(live_view_pid, {:limit_reached, "All commits processed"})
          supervisor_loop(supervisor)
        end

      {:send_next_commit, live_view_pid, byzantine_nodes} ->
        peer_module = get_peer_module(supervisor)
        supervisor_counter = supervisor |> get_commit_counter()
        list_of_commits = supervisor(supervisor, :list_of_commits)
        length_of_commits = length(list_of_commits)

        if supervisor_counter < length(list_of_commits) do
          IO.puts(
            "Sending next commit, current counter:  #{supervisor_counter}/#{length_of_commits}"
          )

          start_edit(
            supervisor_counter,
            supervisor,
            live_view_pid,
            list_of_commits,
            peer_module
          )

          supervisor_loop(
            supervisor(supervisor,
              commit_counter: supervisor_counter + 1,
              byzantine_nodes: byzantine_nodes
            )
          )
        else
          IO.puts("All commits processed")
          send(live_view_pid, {:limit_reached, "All commits processed"})
          supervisor_loop(supervisor)
        end

      {:collect_metadata_from_peers} ->
        :global.whereis_name(:supervisor)
        |> perform_broadcast({:supervisor_request_metadata}, 0..0)

        supervisor_loop(supervisor)

      {:receive_metadata_from_peer, metadata, peer_id} ->
        supervisor
        |> put_peer_metadata(peer_id, metadata)
        |> supervisor_loop

      # Untagged variant kept for the LiveView button: snapshot under the current
      # commit counter.
      {:print_supervisor_metadata} ->
        send(self(), {:print_supervisor_metadata, get_commit_counter(supervisor)})
        supervisor_loop(supervisor)

      {:print_supervisor_metadata, commit_number} ->
        peer_str = "#{get_peer_module_string(supervisor)}/"

        merged_peer_metadata(supervisor)
        |> save_metadata(
          supervisor(supervisor, :byzantine_nodes),
          commit_number,
          peer_str
        )

        supervisor_loop(supervisor)

      {:kill} ->
        IO.puts("Receive killing supervisor")
        kill()

      Message ->
        IO.puts("Supervisor received unknown message")
        IO.inspect(Message)
        supervisor_loop(supervisor)
    end
  end
end
