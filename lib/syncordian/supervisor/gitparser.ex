defmodule Syncordian.GitParser do
  @moduledoc """
  This module contains functions for parsing and manipulating git log data. So far the
  structure of a commit is something like this:

    %{
      author_id: "Olivia (Zoe)",
      commit_hash: "f9993d0c687c0fb50490aa530adee57ea4c70c12",
      position_changes: [
        [
          {{88, 6}, {88, 14}, 14},
          " | **wget**  | `sh -c \"$(wget -O- https://raw.githubusercontent.com/ohy...",
          " | **fetch** | `sh -c \"$(fetch -o - https://raw.githubusercontent.com/o...",
          "",
          "+Alternatively, the installer is also mirrored outside GitHub. Using thi...",
          "+",
          "+| Method    | Command                                                  ...",
          "+| :-------- | :--------------------------------------------------------...",
          "+| **curl**  | `sh -c \"$(curl -fsSL https://install.ohmyz.sh/)\"`      ...",
          "+| **wget**  | `sh -c \"$(wget -O- https://install.ohmyz.sh/)\"`        ...",
          "+| **fetch** | `sh -c \"$(fetch -o - https://install.ohmyz.sh/)\"`      ...",
          "+",
          " _Note that any previous `.zshrc` will be renamed to `.zshrc.pre-oh-my-....",
          "",
          " #### Manual Inspection"
        ]
      ]
    }

  where :
    - author_id :: String -> The id of the author of the commit.
    - commit_hash :: String -> The hash of the commit.
    - position_changes :: list -> A list of changes in the commit. Each change is a list
      with the following structure:
      - The first element is a tuple with the starting and ending position of the change
        corresponding to the structure `@@ -88,6 +88,14 @@` of the original git log
        additionally a number that represents the total context lines in the change
        (max(6,14)).
      - The rest of the elements are the lines of the change.


  """

  @doc """
  Finds the commit hash in a given line.

  ## Examples

      iex> SyncordianTest.find_commit_hash("commit abc123")
      "abc123"

  """
  def find_commit_hash(line_name) do
    find_regex(line_name, commit_hash_pattern())
  end

  def is_commit_hash?(line_name) do
    Regex.match?(commit_hash_pattern(), line_name)
  end

  # A real `git log` commit-header line, anchored at column 0: `commit <hash>`. Anchoring
  # (rather than a bare "commit" substring match) avoids mistaking diff/message content
  # that merely mentions "commit" for a new commit boundary.
  defp commit_hash_pattern, do: ~r/^commit ([0-9a-f]{7,40})\b/

  @doc """
  Finds the author ID in a given line.

  ## Examples

      iex> SyncordianTest.find_author_id("Author: John Doe")
      "John Doe"

  """
  def find_author_id(line_name) do
    pattern_author_id = ~r/Author: ([^<]+)/
    find_regex(line_name, pattern_author_id)
  end

  @doc """
  Finds a regex pattern in a given line.

  ## Examples

      iex> SyncordianTest.find_regex("line with pattern", ~r/pattern/)
      "pattern"

  """
  def find_regex(line_name, pattern) do
    case Regex.run(pattern, line_name) do
      [_, name] -> String.trim(name)
      _ -> line_name
    end
  end

  @doc """
  Finds the position in a line of a git diff.

  ## Examples

      iex> SyncordianTest.find_position_in_line("@@ -1,2 +3,4 @@")
      [[1, 2], [3, 4]]

  """
  def find_position_in_line(line) do
    # The line/count part of a hunk header is optional in unified diffs: git omits `,N`
    # when N == 1 (e.g. `@@ -5 +5,2 @@`). Treat a missing count as 1.
    pattern_line_position = ~r/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    case Regex.run(pattern_line_position, line, capture: :all_but_first) do
      nil ->
        line

      captures ->
        [start_old, count_old, start_new, count_new] =
          captures ++ List.duplicate("", 4 - length(captures))

        old_count = count_or_one(count_old)
        new_count = count_or_one(count_new)

        {
          {String.to_integer(start_old), old_count},
          {String.to_integer(start_new), new_count},
          max(old_count, new_count)
        }
    end
  end

  defp count_or_one(""), do: 1
  defp count_or_one(count), do: String.to_integer(count)

  @doc """
  Drops irrelevant lines from a git log. In particular the ones from the date to the
  beginning of the first diff.

  """
  def drop_junk(log_line) do
    reduce_function = fn line, {flag, acc} ->
      start? = String.contains?(line, "Date: ")
      end? = String.contains?(line, "@@ -")
      # A merge commit's header carries a `Merge: p1 p2` line between the commit hash and
      # the Author line (emitted under --diff-merges=first-parent). It must not survive
      # into the chunk: parse_line_to_map/1 takes the chunk's second element as the
      # author id. Anchored at column 0 — diff body lines always start with
      # ' ', '+', '-', '@' or '\', so no content line can match.
      merge_header? = not flag and String.starts_with?(line, "Merge: ")
      # In theory this should not happen simultaneously, only one at a time! (I think)
      line = find_commit_hash(line)
      line = find_author_id(line)
      line = find_position_in_line(line)

      case {flag, start?, end?} do
        {false, true, _} -> {:cont, {true, acc}}
        {true, _, false} -> {:cont, {true, acc}}
        {true, _, true} -> {:cont, {false, [line | acc]}}
        {false, _, _} -> {:cont, {false, if(merge_header?, do: acc, else: [line | acc])}}
      end
    end

    log_line
    |> Enum.reduce_while({false, []}, reduce_function)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
    A positional change is a list like:
          [
            {{88, 6}, {88, 14}, 14},
            " | **wget**  | `sh -c \"$(wget -O- https://raw.githubusercontent.com/ohy...",
            " | **fetch** | `sh -c \"$(fetch -o - https://raw.githubusercontent.com/o...",
            "",
            "+Alternatively, the installer is also mirrored outside GitHub. Using thi...",
            "+",
            "+| Method    | Command                                                  ...",
            "+| :-------- | :--------------------------------------------------------...",
            "+| **curl**  | `sh -c \"$(curl -fsSL https://install.ohmyz.sh/)\"`      ...",
            "+| **wget**  | `sh -c \"$(wget -O- https://install.ohmyz.sh/)\"`        ...",
            "+| **fetch** | `sh -c \"$(fetch -o - https://install.ohmyz.sh/)\"`      ...",
            "+",
            " _Note that any previous `.zshrc` will be renamed to `.zshrc.pre-oh-my-....",
            "",
            " #### Manual Inspection"
          ]
    The idea of this function is to parse the positional change into insertions, deletions
    that is to define insert(_,insert_value,index_position) or
    delete_line(_,index_position) base on the lines that start with "+" (insert) or "-"
    (delete). The index_position is the index position line in the context lines plus the
    global position, in the case of the example the global position is 88.
  """
  def parse_positional_change([{{global_position, old_count}, _, _} | context_lines]) do
    # A zero-old-count hunk (`@@ -0,0 +1,N`, i.e. file creation — with the default
    # 3-line context every other hunk has old_count >= 1) anchors its indices on the
    # line BEFORE the insertion point (git's "insert after old line k" convention),
    # one earlier than the uniform before-semantics the Syncordian replay uses. Tag
    # the ops so the supervisor can shift them by +1 at dispatch (Syncordian only).
    zero_old = old_count == 0

    # TODO: the structure %{op:....} could be the type of this module, it does?
    context_lines
    |> Enum.reduce({global_position, 0, 0, []}, fn line,
                                                   {index_position, test_index_position,
                                                    current_delete_ops, acc} ->
      new_index_position = index_position + 1
      # new_test_index_position =  test_index_position + 1

      case String.at(line, 0) do
        "-" ->
          {new_index_position, test_index_position, current_delete_ops + 1,
           [
             %{
               op: :delete,
               index: index_position,
               test_index: index_position - current_delete_ops,
               content: "",
               global_position: global_position,
               current_delete_ops: current_delete_ops,
               zero_old: zero_old
             }
             | acc
           ]}

        "+" ->
          case line do
            "+" <> content ->
              {new_index_position, test_index_position + 1, current_delete_ops,
               [
                 %{
                   op: :insert,
                   index: index_position,
                   test_index: index_position - current_delete_ops,
                   content: content,
                   global_position: global_position,
                   current_delete_ops: current_delete_ops,
                   zero_old: zero_old
                 }
                 | acc
               ]}

            "+" ->
              {new_index_position, test_index_position + 1, current_delete_ops,
               [
                 %{
                   op: :insert,
                   index: index_position,
                   test_index: index_position - current_delete_ops,
                   content: "\n",
                   global_position: global_position,
                   current_delete_ops: current_delete_ops,
                   zero_old: zero_old
                 }
                 | acc
               ]}
          end

        _ ->
          {new_index_position, new_index_position, current_delete_ops, acc}
      end
    end)
    |> elem(3)
    |> Enum.reverse()
  end

  # A commit that touched the tracked file without producing a hunk (e.g. a pure mode
  # change) has no positional changes; yield an empty list instead of crashing.
  def parse_changes([]), do: []

  def parse_changes(changes) do
    reduce_function = fn line, acc ->
      case line do
        # This is the case where the line is something like:
        #   {{88, 6}, {88, 14}, 14} that is the same as @@ -88,6 +88,14 @@
        # It means that a new set of changes was found
        {_, _, _} -> {:cont, Enum.reverse(acc), [line]}
        # This is the case of a line that is within the context lines
        _ -> {:cont, [line | acc]}
      end
    end

    after_fun = fn
      [last | acc1] = acc ->
        # The final accumulated line of a commit's last hunk is normally the blank
        # separator git prints before the next commit header (or trailing context) and is
        # safe to drop. But a hunk that ends at EOF can end with a real `+`/`-` change —
        # dropping that would silently lose the edit, so keep op lines.
        op_line? =
          is_binary(last) and (String.starts_with?(last, "+") or String.starts_with?(last, "-"))

        if op_line?,
          do: {:cont, Enum.reverse(acc), []},
          else: {:cont, Enum.reverse(acc1), []}

      _ ->
        {:cont, []}
    end

    [first_positions | new_changes] = changes

    new_changes
    |> Enum.chunk_while([first_positions], reduce_function, after_fun)
    |> Enum.map(&parse_positional_change/1)
  end

  @spec parse_line_to_map([String.t()]) :: map
  def parse_line_to_map([hash | [id | changes]]) do
    %{
      author_id: id,
      commit_hash: hash,
      position_changes: changes |> parse_changes
    }
  end

  @doc """
  Parses a git log from any enumerable of lines (a file stream or the output of a live
  `git log`) and returns a stream of commit maps.
  """
  def parse_lines(lines) do
    # Split into per-commit chunks on real commit-header lines. Leading noise before the
    # first commit (flag still false) is discarded.
    chunk_fun = fn element, {flag, acc1} ->
      case {is_commit_hash?(element), flag} do
        {true, false} -> {:cont, {true, [element | acc1]}}
        {false, true} -> {:cont, {true, [element | acc1]}}
        # New chunk starts
        {true, true} -> {:cont, Enum.reverse(acc1), {true, [element]}}
        {false, false} -> {:cont, {false, acc1}}
      end
    end

    after_fun = fn
      [] -> {:cont, []}
      {_, acc} -> {:cont, Enum.reverse(acc), []}
      acc -> {:cont, Enum.reverse(acc), []}
    end

    lines
    # Strip only the line terminator, never trailing spaces: tracked-file content can
    # legitimately end in whitespace (e.g. Markdown tables), and eating it makes the
    # replayed document diverge from the real file.
    |> Stream.map(fn line -> line |> String.trim_trailing("\n") |> String.trim_trailing("\r") end)
    |> Stream.chunk_while({false, []}, chunk_fun, after_fun)
    |> Stream.map(&drop_junk/1)
    |> Stream.map(&parse_line_to_map/1)
  end

  @doc """
  Returns the commit hashes from an enumerable of git-log lines, oldest first, as a list.
  """
  def commits_from_lines(lines) do
    lines
    |> Stream.filter(&is_commit_hash?/1)
    |> Stream.map(&find_commit_hash/1)
    |> Enum.to_list()
    |> Enum.reverse()
  end

  @doc """
  Groups the parsed log entries into a map keyed by commit hash.
  """
  def group_by_commit(parsed_log) do
    parsed_log
    |> Enum.to_list()
    |> Enum.group_by(&Map.get(&1, :commit_hash))
  end

  @doc """
  Groups the parsed log by author, returning `{author_group_map, authors_list}`.

  The supervisor uses `authors_list` to decide how many author peers to spawn (one
  per distinct author in the log).
  """
  def group_by_author(parsed_log) do
    authors_group_map =
      parsed_log
      |> Enum.to_list()
      |> Enum.group_by(&Map.get(&1, :author_id))

    {authors_group_map, authors_group_map |> Map.keys()}
  end
end
