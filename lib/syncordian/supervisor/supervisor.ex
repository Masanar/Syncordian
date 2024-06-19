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
  import Syncordian.GitParser
  import Syncordian.Utilities

  Record.defrecord(:supervisor,
    list_of_commits: [],
    commit_group_map: %{},
    pid_list_author_peers: [],
    map_peer_id_authors: %{},
    commit_counter: 0,
    live_vie_logs: []
  )

  @doc """
    Parses a single edit and applies it to the specified peer.

    ## Parameters

    - `edit`: A map representing the edit to be parsed. It should contain the following
      keys:
      - `:op`: The operation to be performed. It can be `:insert` or `:delete`.
      - `:content`: The content to be inserted (required for `:insert` operation).
      - `:index`: The index of the line to be deleted (required for `:delete` operation).
    - `peer_pid`: The process identifier (PID) of the peer to apply the edit to.
  """
  def parse_edit(edit, peer_pid, acc) do
    case Map.get(edit, :op) do
      :insert ->
        insert(peer_pid, Map.get(edit, :content), Map.get(edit, :index) + acc)
        1

      :delete ->
        delete_line(peer_pid, Map.get(edit, :index) + acc)
        -1
    end
  end

  @doc """
    Parses a list of edits and applies them to the specified peer.
  """
  def parse_edits(edits, peer_pid) do
    edits
    |> Enum.reduce(0, fn edit_list, acc_outer ->
      Enum.reduce(edit_list, acc_outer, fn atom_edit, acc_inner ->
        parse_edit(atom_edit, peer_pid, acc_outer) + acc_inner
      end)
    end)
  end

  @doc """
    Starts the process of applying edits for a list of commits.

    ## Parameters

    - `commits`: A list of commit hashes representing the commits to be processed.
    - `commit_group_map`: A map containing commit hashes as keys and commit groups as
      values. Each commit group should contain the following keys:
      - `:author_id`: The ID of the author who made the commit.
      - `:position_changes`: A list of position changes to be applied.
    - `map_peer_id_authors`: A map that maps author IDs(string) to peer IDs(integer).
    - `pid_list_author_peers`: A list of peer PIDs corresponding to each author
      ID(integer).

    The function loops through the commits in order, retrieves the corresponding commit
    group, and applies the position changes to the specified peer. The author ID is used
    to determine the peer ID, which is then used to retrieve the peer PID from the
    `pid_list_author_peers`. The position changes are applied using the `parse_edits/2`
    function.

  """
  def edit(commit_hash, commit_group_map, map_peer_id_authors, pid_list_author_peers) do
    [commit_group] = Map.get(commit_group_map, commit_hash)
    author_id = Map.get(commit_group, :author_id)
    position_changes = Map.get(commit_group, :position_changes)
    peer_id = Map.get(map_peer_id_authors, author_id)
    peer_pid = Enum.at(pid_list_author_peers, peer_id)
    IO.inspect("This are the positional changes")
    IO.inspect(position_changes)
    parse_edits(position_changes, peer_pid)
    Process.sleep(500)
    # # Process.sleep(2000)
    # Process.sleep(1000)
    # Enum.map(1..29, fn x ->
    #   save_content(Enum.at(pid_list_author_peers, x))
    # end)
    # Process.sleep(1000)
    author_id
  end

  def start_edit(commit_count, supervisor, live_view_pid, list_of_commits) do
    commit_group_map = supervisor(supervisor, :commit_group_map)
    map_peer_id_authors = supervisor(supervisor, :map_peer_id_authors)
    pid_list_author_peers = supervisor(supervisor, :pid_list_author_peers)

    IO.inspect(
      "Starting edit for commit: #{commit_count}, total commits: #{length(list_of_commits)}"
    )

    commit_hash = Enum.at(list_of_commits, commit_count)
    author_id = edit(commit_hash, commit_group_map, map_peer_id_authors, pid_list_author_peers)
    response = {:commit_inserted, %{hash: commit_hash, author: author_id}}
    send(live_view_pid, response)
  end

  @doc """
    Initializes the peers for the Syncordian system based on the list of authors.

    ## Parameters

    - `authors_list`: A    Enum.each(edits, fn edit ->
      Process.sleep(200)
      parse_edit(edit, peer_pid)
    end) list of author IDs representing the authors in the system.

    ## Returns

    A tuple containing two elements:
    - The list of peer PIDs in reverse order.
    - A map that maps author IDs(string) to peer IDs(integer).

    The function initializes the peers by creating a network of processes. Each author
    is assigned a unique peer ID, and a corresponding peer process is started. The
    author IDs are mapped to their respective peer IDs in the resulting map.

  """
  def init_peers(authors_list) do
    network_size = authors_list |> length()

    values =
      authors_list
      |> Enum.reduce({0, [], %{}}, fn author_id, {acc, add_pid, map_ids} ->
        {acc + 1, [start(acc, network_size) | add_pid], Map.put(map_ids, author_id, acc)}
      end)

    {elem(values, 1) |> Enum.reverse(), elem(values, 2)}
  end

  @doc """
    Initializes the supervisor and starts the process of applying edits.

    The function initializes the supervisor by parsing the Git log and retrieving the list
    of commits. It then groups the commits by author and starts the process of applying
    edits for each commit. Finally, it terminates all the processes started by the
    supervisor.

  """
  def init() do
    # Delete the all the files of the debug directory
    delete_contents("debug")

    # Load the git log and the list of commits of the test files
    parsed_git_log = parser_git_log("test")
    list_of_commits = get_list_of_commits("test")
    commit_group_map = group_by_commit(parsed_git_log)

    # Instance all the 30 peers independent  the number of commits in the test file
    temporal_git_log = parser_git_log("ohmyzsh_README_git_log")
    {_, authors_list} = group_by_author(temporal_git_log)
    {pid_list_author_peers, map_peer_id_authors} = init_peers(authors_list)

    IO.inspect(list_of_commits)
    IO.inspect(pid_list_author_peers)

    supervisor =
      supervisor(
        list_of_commits: list_of_commits,
        commit_group_map: commit_group_map,
        pid_list_author_peers: pid_list_author_peers,
        map_peer_id_authors: map_peer_id_authors
      )

    pid = spawn(__MODULE__, :supervisor_loop, [supervisor])
    :global.register_name(:supervisor, pid)
    pid
  end

  def supervisor_loop(supervisor) do
    receive do
      {:send_next_commit, live_view_pid} ->
        supervisor_counter = supervisor(supervisor, :commit_counter)
        list_of_commits = supervisor(supervisor, :list_of_commits)

        if supervisor_counter <= length(list_of_commits) do
          IO.inspect("Sending next commit, current counter:  #{supervisor_counter}")
          start_edit(supervisor_counter, supervisor, live_view_pid, list_of_commits)

          supervisor_loop(
            supervisor(supervisor, commit_counter: supervisor_counter + 1, live_vie_logs: logs)
          )
        else
          IO.puts("All commits processed")
          send(live_view_pid, {:limit_reached, "All commits processed"})
        end

      {:kill} ->
        IO.inspect("Receive killing supervisor")
        kill()

      _ ->
        IO.puts("Unknown message")
        supervisor_loop(supervisor)
    end
  end
end
