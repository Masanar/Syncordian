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
    pattern_commit_hash = ~r/commit\s+(\w+)/
    find_regex(line_name, pattern_commit_hash)
  end

  def is_commit_hash?(line_name) do
    pattern_commit_hash = ~r/commit\s+(\w+)/
    Regex.match?(pattern_commit_hash, line_name)
  end

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
    pattern_line_position = ~r/@@ -(\d+),(\d+) \+(\d+),(\d+) @@/

    case Regex.scan(pattern_line_position, line) do
      [[_, num1, num2, num3, num4]] ->
        {
          {String.to_integer(num1), String.to_integer(num2)},
          {String.to_integer(num3), String.to_integer(num4)},
          max(String.to_integer(num2), String.to_integer(num4))
        }

      _ ->
        line
    end
  end

  @doc """
  Drops irrelevant lines from a git log. In particular the ones from the date to the
  beginning of the first diff.

  """
  def drop_junk(log_line) do
    reduce_function = fn line, {flag, acc} ->
      start? = String.contains?(line, "Date: ")
      end? = String.contains?(line, "@@ -")
      # In theory this should not happen simultaneously, only one at a time! (I think)
      line = find_commit_hash(line)
      line = find_author_id(line)
      line = find_position_in_line(line)

      case {flag, start?, end?} do
        {false, true, _} -> {:cont, {true, acc}}
        {true, _, false} -> {:cont, {true, acc}}
        {true, _, true} -> {:cont, {false, [line | acc]}}
        {false, _, _} -> {:cont, {false, [line | acc]}}
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
  def parse_positional_change([{{global_position, _}, _, _} | context_lines]) do
    # TODO: the structure %{op:....} could be the type of this module, it does?
    context_lines
    |> Enum.reduce({global_position,0, []}, fn line, {index_position, current_delete_ops, acc} ->
      new_index_position = index_position + 1

      case String.at(line, 0) do
        "-" ->
          {new_index_position,
          current_delete_ops + 1,
           [
             %{
               op: :delete,
               index: index_position,
               content: "",
               global_position: global_position,
               current_delete_ops: current_delete_ops
             }
             | acc
           ]}

        "+" ->
          case line do
            "+" <> content ->
              {new_index_position,
              current_delete_ops,
               [
                 %{
                   op: :insert,
                   index: index_position,
                   content: content,
                   global_position: global_position,
                   current_delete_ops: current_delete_ops
                 }
                 | acc
               ]}

            "+" ->
              {new_index_position,
              current_delete_ops,
               [
                 %{
                   op: :insert,
                   index: index_position,
                   content: "\n",
                   global_position: global_position,
                   current_delete_ops: current_delete_ops
                 }
                 | acc
               ]}
          end

        _ ->
          {new_index_position, current_delete_ops, acc}
      end
    end)
    |> elem(2)
    |> Enum.reverse()
  end

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
      [_ | acc1] ->
        # Is there always a " " (empty line) at the end of each set of changes
        {:cont, Enum.reverse(acc1), []}

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
  Parses a git log file and returns a list of relevant lines.
  """
  def parser_git_log(file_name) do
    chunk_fun = fn element, {flag, acc1} ->
      contains? = String.contains?(element, "commit")

      case {contains?, flag} do
        {true, false} -> {:cont, {true, [element | acc1]}}
        {false, true} -> {:cont, {true, [element | acc1]}}
        # New chunk starts
        {true, true} -> {:cont, Enum.reverse(acc1), {true, [element]}}
      end
    end

    after_fun = fn
      [] -> {:cont, []}
      {_, acc} -> {:cont, Enum.reverse(acc), []}
      acc -> {:cont, Enum.reverse(acc), []}
    end

    Path.join([File.cwd!(), "test/git_log", file_name])
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.chunk_while({false, []}, chunk_fun, after_fun)
    |> Stream.map(&drop_junk/1)
    |> Stream.map(&parse_line_to_map/1)
  end

  def get_list_of_commits(file_name) do
    Path.join([File.cwd!(), "test/git_log", file_name])
    |> File.stream!()
    |> Stream.filter(&is_commit_hash?/1)
    |> Stream.map(&find_commit_hash/1)
    |> Enum.to_list()
    |> Enum.reverse()
  end

  def group_by_commit(parsed_log) do
    parsed_log
    |> Enum.to_list()
    |> Enum.group_by(&Map.get(&1, :commit_hash))
  end

  def group_by_author(parsed_log) do
    authors_group_map =
      parsed_log
      |> Enum.to_list()
      |> Enum.group_by(&Map.get(&1, :author_id))

    {authors_group_map, authors_group_map |> Map.keys()}
  end
end
