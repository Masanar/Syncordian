defmodule Syncordian.GitLog do
  @moduledoc """
  Reads commit history live from a cloned git repository, replacing the old static
  fixture under `test/git_log/`.

  The `/supervisor` experiment calls `log_lines/0` at launch to obtain the `git log -p`
  output for a single tracked file (README.md by default). The output has the same line
  shape the parser previously read from the fixture, so it is fed unchanged to
  `Syncordian.GitParser.parse_lines/1` and `Syncordian.GitParser.commits_from_lines/1`.

  Configuration (env override wins over config; defaults live in `config/config.exs`,
  the single source of truth for both settings):

    * repo path    - `SYNCORDIAN_REPO_PATH`    / `config :syncordian, :git_repo_path`
    * tracked file - `SYNCORDIAN_TRACKED_FILE`  / `config :syncordian, :git_tracked_file`
    * commit cap   - `SYNCORDIAN_MAX_COMMITS`   / `config :syncordian, :max_commits`
      (replay only the first N mainline commits, oldest first; unset = full history)

  The repo path may be absolute or relative to the mix working directory (`code/`).
  """

  @doc """
  Returns the `git log -p` output for the tracked file as a list of lines (newest commit
  first), matching the line shape the parser previously read from the fixture file.

  Raises if the repo path is not a git clone, if the tracked file is missing from it, or
  if git exits non-zero.
  """
  @spec log_lines() :: [String.t()]
  def log_lines do
    repo = repo_path()
    file = tracked_file()
    validate!(repo, file)

    # Keep the default `medium` format: `drop_junk/1` keys off the `Author:` / `Date:`
    # lines. Keep the default 3-line context and no rename-following so the textual shape
    # matches what the parser expects.
    #
    # `--first-parent --diff-merges=first-parent` replays the file's exact MAINLINE
    # evolution: one patch per mainline commit that changed the file, with merge commits
    # contributing their diff against the first parent. This is what makes the replayed
    # document byte-identical to the file at HEAD. The previous `--no-merges` form
    # silently lost every change that reached the file through a merge (git's history
    # simplification also drops side-branch commits from a path-filtered log), so the
    # replayed document drifted from the real file with no error.
    case System.cmd(
           "git",
           [
             "-C",
             repo,
             "log",
             "-p",
             "--first-parent",
             "--diff-merges=first-parent",
             "--no-color",
             log_tip(repo, file),
             "--",
             file
           ],
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        String.split(output, "\n")

      {output, status} ->
        raise "git log failed (exit #{status}) for #{file} in #{Path.expand(repo)}:\n#{output}"
    end
  end

  @doc """
  The tracked file's exact content at the given commit (`git show <commit>:<file>`),
  i.e. the state a byte-faithful replay must reproduce right after that commit.
  """
  @spec file_at(String.t()) :: String.t()
  def file_at(commit_hash) do
    repo = repo_path()
    file = tracked_file()

    case System.cmd("git", ["-C", repo, "show", "#{commit_hash}:#{file}"], stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        raise "git show failed (exit #{status}) for #{commit_hash}:#{file}:\n#{output}"
    end
  end

  @doc "Resolved repo path (env override > config/config.exs)."
  @spec repo_path() :: String.t()
  def repo_path do
    System.get_env("SYNCORDIAN_REPO_PATH") ||
      Application.get_env(:syncordian, :git_repo_path)
  end

  @doc "Resolved tracked file, relative to the repo root (env override > config/config.exs)."
  @spec tracked_file() :: String.t()
  def tracked_file do
    System.get_env("SYNCORDIAN_TRACKED_FILE") ||
      Application.get_env(:syncordian, :git_tracked_file)
  end

  @doc "Optional cap on how many mainline commits (oldest first) to replay (env override > config)."
  @spec max_commits() :: pos_integer() | nil
  def max_commits do
    case System.get_env("SYNCORDIAN_MAX_COMMITS") do
      nil -> Application.get_env(:syncordian, :max_commits)
      value -> String.to_integer(value)
    end
  end

  # The tip commit the log runs up to: HEAD for the full history, or — when a commit
  # cap is set — the cap-th oldest mainline commit touching the file, so the replayed
  # history is exactly its first `max_commits` commits and every consumer (parser,
  # supervisor, convergence checks) sees the same truncated history.
  defp log_tip(repo, file) do
    case max_commits() do
      nil ->
        "HEAD"

      cap ->
        {output, 0} =
          System.cmd(
            "git",
            ["-C", repo, "rev-list", "--reverse", "--first-parent", "HEAD", "--", file]
          )

        hashes = String.split(output, "\n", trim: true)
        Enum.at(hashes, min(cap, length(hashes)) - 1)
    end
  end

  defp validate!(repo, file) do
    unless File.exists?(Path.join(repo, ".git")) do
      raise """
      No git repository found at #{Path.expand(repo)} (resolved from "#{repo}").
      Clone the target repo there, or set SYNCORDIAN_REPO_PATH to its location.
      """
    end

    unless File.regular?(Path.join(repo, file)) do
      raise """
      Tracked file "#{file}" not found in #{Path.expand(repo)}.
      Set SYNCORDIAN_TRACKED_FILE to a file that exists in the repo.
      """
    end
  end
end
