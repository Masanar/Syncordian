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
  import Syncordian.Peer
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
    metadata_peer_count: 0,
    metadata: Syncordian.Metadata.metadata()
  )

  @type supervisor ::
          record(:supervisor,
            list_of_commits: list(),
            commit_group_map: map(),
            pid_list_author_peers: list(),
            map_peer_id_authors: map(),
            commit_counter: integer(),
            metadata_peer_count: integer(),
            metadata: Syncordian.Metadata.metadata()
          )

  @spec get_metadata_peer_count(supervisor()) :: integer()
  defp get_metadata_peer_count(supervisor),
    do: supervisor(supervisor, :metadata_peer_count)

  @spec inc_metadata_peer_count(supervisor()) :: supervisor()
  defp inc_metadata_peer_count(supervisor) do
    current_metadata_peer_count = get_metadata_peer_count(supervisor)
    # This is not the best way to know when all the metadata has been collected, but it
    # works for now.
    if current_metadata_peer_count > 28 do
      IO.puts("Supervisor: all metadata from peers collected")
      IO.puts("")
    end

    supervisor(supervisor,
      metadata_peer_count: current_metadata_peer_count + 1
    )
  end

  @spec get_metadata(supervisor()) :: Syncordian.Metadata.metadata()
  defp get_metadata(supervisor), do: supervisor(supervisor, :metadata)

  @spec update_metadata(Syncordian.Metadata.metadata(), supervisor()) :: supervisor()
  defp update_metadata(metadata, supervisor) do
    inc_metadata_peer_count(supervisor)
    |> supervisor(metadata: metadata)
  end

  # Parses a single edit and applies it to the specified peer.
  # ## Parameters
  # - `edit`: A map representing the edit to be parsed. It should contain the following
  #   keys:
  #   - `:op`: The operation to be performed. It can be `:insert` or `:delete`.
  #   - `:content`: The content to be inserted (required for `:insert` operation).
  #   - `:index`: The index of the line to be deleted (required for `:delete` operation).
  # - `peer_pid`: The process identifier (PID) of the peer to apply the edit to.
  defp parse_edit(edit, peer_pid, acc) do
    # If want to know why the acc is reduced by 1 in the case of a delete operation and
    # increase by 1 in the case of an insert operation, please read the comets of
    # the parse_edits function just below.
    case Map.get(edit, :op) do
      :insert ->
        insert(
          peer_pid,
          Map.get(edit, :content),
          Map.get(edit, :index) + acc,
          Map.get(edit, :test_index) + acc,
          Map.get(edit, :global_position),
          Map.get(edit, :current_delete_ops)
        )

        1

      :delete ->
        delete_line(
          peer_pid,
          Map.get(edit, :index) + acc,
          Map.get(edit, :test_index) + acc,
          Map.get(edit, :global_position),
          Map.get(edit, :current_delete_ops)
        )

        -1
    end
  end

  # Parses a list of edits and applies them to the specified peer.
  defp parse_edits(edits, peer_pid) do
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
        parse_edit(atom_edit, peer_pid, acc_outer) + acc_inner
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
  defp edit(commit_hash, commit_group_map, map_peer_id_authors, pid_list_author_peers) do
    [commit_group] = Map.get(commit_group_map, commit_hash)
    author_id = Map.get(commit_group, :author_id)
    position_changes = Map.get(commit_group, :position_changes)
    peer_id = Map.get(map_peer_id_authors, author_id)
    peer_pid = Enum.at(pid_list_author_peers, peer_id)
    parse_edits(position_changes, peer_pid)
    Process.sleep(500)
    author_id
  end

  defp save_current_documents(pid_list_author_peers) do
    Enum.map(1..29, fn x ->
      save_content(Enum.at(pid_list_author_peers, x))
    end)
  end

  defp start_edit(commit_count, supervisor, live_view_pid, list_of_commits) do
    commit_group_map = supervisor(supervisor, :commit_group_map)
    map_peer_id_authors = supervisor(supervisor, :map_peer_id_authors)
    pid_list_author_peers = supervisor(supervisor, :pid_list_author_peers)
    commit_hash = Enum.at(list_of_commits, commit_count)
    author_id = edit(commit_hash, commit_group_map, map_peer_id_authors, pid_list_author_peers)
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
  defp init_peers(authors_list) do
    network_size = authors_list |> length()

    values =
      authors_list
      |> Enum.reduce({0, [], %{}}, fn author_id, {acc, add_pid, map_ids} ->
        {acc + 1, [start(acc, network_size) | add_pid], Map.put(map_ids, author_id, acc)}
      end)

    {elem(values, 1) |> Enum.reverse(), elem(values, 2)}
  end

  @spec byzantine_peer_id(Syncordian.Basic_Types.peer_id()) ::
          Syncordian.Basic_Types.peer_id()
  defp byzantine_peer_id(peer_id) do
    peer_id * 23 + 71
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
  def init(byzantine_nodes) do
    # TODO: Delete the call to "test"
    # Delete the all the files of the debug directory
    delete_contents("debug/documents")

    # Load the git log and the list of commits of the test files
    parsed_git_log = parser_git_log("test")
    list_of_commits = get_list_of_commits("test")
    commit_group_map = group_by_commit(parsed_git_log)

    # Instance all the 30 peers independent  the number of commits in the test file
    temporal_git_log = parser_git_log("ohmyzsh_README_full_git_log")
    {_, authors_list} = group_by_author(temporal_git_log)
    {pid_list_author_peers, map_peer_id_authors} = init_peers(authors_list)

    supervisor =
      supervisor(
        list_of_commits: list_of_commits,
        commit_group_map: commit_group_map,
        pid_list_author_peers: pid_list_author_peers,
        map_peer_id_authors: map_peer_id_authors
      )

    IO.puts("Byzantine nodes to start #{byzantine_nodes}")
    init_byzantine_peers(byzantine_nodes)

    pid = spawn(__MODULE__, :supervisor_loop, [supervisor])
    :global.register_name(:supervisor, pid)
    pid
  end

  defp broadcast_to_all_peers(supervisor, message) do
    pid_list_author_peers = supervisor(supervisor, :pid_list_author_peers)
    Enum.map(pid_list_author_peers, fn pid -> send(pid, message) end)
  end

  def supervisor_loop(supervisor) do
    receive do
      {:write_current_peers_document} ->
        save_current_documents(supervisor(supervisor, :pid_list_author_peers))
        supervisor_loop(supervisor)

      {:send_all_commits, live_view_pid} ->
        supervisor_counter = supervisor(supervisor, :commit_counter)
        list_of_commits = supervisor(supervisor, :list_of_commits)
        length_of_commits = length(list_of_commits)

        if supervisor_counter < length(list_of_commits) do
          IO.inspect(
            "Sending next commit, current counter:  #{supervisor_counter}/#{length_of_commits}"
          )

          start_edit(supervisor_counter, supervisor, live_view_pid, list_of_commits)
          send(self(), {:send_all_commits, live_view_pid})
          supervisor_loop(supervisor(supervisor, commit_counter: supervisor_counter + 1))
        else
          IO.puts("All commits processed")
          send(live_view_pid, {:limit_reached, "All commits processed"})
          supervisor_loop(supervisor)
        end

      {:send_next_commit, live_view_pid} ->
        supervisor_counter = supervisor(supervisor, :commit_counter)
        list_of_commits = supervisor(supervisor, :list_of_commits)
        length_of_commits = length(list_of_commits)

        if supervisor_counter < length(list_of_commits) do
          IO.inspect(
            "Sending next commit, current counter:  #{supervisor_counter}/#{length_of_commits}"
          )

          start_edit(supervisor_counter, supervisor, live_view_pid, list_of_commits)

          supervisor_loop(supervisor(supervisor, commit_counter: supervisor_counter + 1))
        else
          IO.puts("All commits processed")
          send(live_view_pid, {:limit_reached, "All commits processed"})
          supervisor_loop(supervisor)
        end

      {:collect_metadata_from_peers} ->
        broadcast_to_all_peers(supervisor, {:supervisor_request_metadata})
        supervisor_loop(supervisor)

      {:receive_metadata_from_peer, metadata, _peer_id} ->
        supervisor
        |> get_metadata()
        |> merge_metadata(metadata)
        |> update_metadata(supervisor)
        |> supervisor_loop

      {:print_supervisor_metadata} ->
        get_metadata(supervisor) |> print_metadata
        supervisor_loop(supervisor)

      {:kill} ->
        IO.inspect("Receive killing supervisor")
        kill()

      _ ->
        IO.puts("Unknown message")
        supervisor_loop(supervisor)
    end
  end
end
