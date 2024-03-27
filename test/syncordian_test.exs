defmodule SyncordianTest do
  @moduledoc """
  This module contains functions for parsing and manipulating git log data.
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

  # def parse_changes_to_map(changes) do changes
  # end

  def parse_line_to_map([hash, id, changes]) do
    %{
      commit_hash: hash,
      author_id: id,
      change: changes |> parse_changes_to_map
    }
  end

  @doc """
  Parses a git log file and returns a list of relevant lines.
  """
  def parser_git_log() do
    chunk_fun = fn element, {flag, acc1} ->
      contains? = String.contains?(element, "commit")

      case {contains?, flag} do
        {true, false} -> {:cont, {true, [element | acc1]}}
        {false, true} -> {:cont, {true, [element | acc1]}}
        {true, true} -> {:cont, Enum.reverse(acc1), {true, [element]}}
      end
    end

    after_fun = fn
      [] -> {:cont, []}
      {_, acc} -> {:cont, acc, []}
      acc -> {:cont, acc, []}
    end

    File.stream!("ohmyzsh_README_git_log")
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.chunk_while({false, []}, chunk_fun, after_fun)
    |> Stream.map(&drop_junk/1)
    |> Enum.to_list()
    |> Enum.take(2)
    |> IO.inspect()
  end
end

SyncordianTest.parser_git_log()
