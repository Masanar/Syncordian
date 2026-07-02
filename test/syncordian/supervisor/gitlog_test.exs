defmodule Syncordian.GitLogTest do
  # async: false — the config-resolution tests mutate process env vars.
  use ExUnit.Case, async: false

  alias Syncordian.GitLog
  alias Syncordian.GitParser, as: GP

  describe "config resolution" do
    test "repo_path falls back to the configured default when no env override is set" do
      System.delete_env("SYNCORDIAN_REPO_PATH")
      assert GitLog.repo_path() == Application.get_env(:syncordian, :git_repo_path)
    end

    test "SYNCORDIAN_REPO_PATH overrides the configured repo path" do
      System.put_env("SYNCORDIAN_REPO_PATH", "/tmp/some-other-clone")
      assert GitLog.repo_path() == "/tmp/some-other-clone"
    after
      System.delete_env("SYNCORDIAN_REPO_PATH")
    end

    test "SYNCORDIAN_TRACKED_FILE overrides the configured tracked file" do
      System.put_env("SYNCORDIAN_TRACKED_FILE", "docs/OTHER.md")
      assert GitLog.tracked_file() == "docs/OTHER.md"
    after
      System.delete_env("SYNCORDIAN_TRACKED_FILE")
    end
  end

  # Integration tests that actually shell out to the configured clone. Excluded by default
  # (see test/test_helper.exs); run with:  mix test --include live
  describe "live git log (against the configured clone)" do
    @describetag :live

    setup do
      repo = GitLog.repo_path()

      if File.exists?(Path.join(repo, ".git")) do
        :ok
      else
        # Opted in (--include live) but no clone present: skip gracefully.
        {:skip, "no git clone at #{Path.expand(repo)} (set SYNCORDIAN_REPO_PATH)"}
      end
    end

    test "log_lines/0 returns a non-empty log whose first line is a commit header" do
      lines = GitLog.log_lines()

      refute lines == []
      first = Enum.find(lines, &(&1 != ""))
      assert GP.is_commit_hash?(first), "expected a commit header, got: #{inspect(first)}"
    end

    test "parse_lines and commits_from_lines agree on the real log (no false splits)" do
      lines = GitLog.log_lines()
      parsed = GP.parse_lines(lines) |> Enum.to_list()
      commits = GP.commits_from_lines(lines)

      # If any diff/message line were mistaken for a commit boundary, these would diverge.
      assert length(parsed) == length(commits)
      assert length(commits) > 0
    end

    test "every parsed commit is well-formed and reachable from the commit list" do
      lines = GitLog.log_lines()
      parsed = GP.parse_lines(lines) |> Enum.to_list()
      grouped = GP.group_by_commit(parsed)

      for commit <- parsed do
        assert is_binary(commit.author_id) and commit.author_id != ""
        assert is_binary(commit.commit_hash)
        assert is_list(commit.position_changes)
      end

      # The supervisor looks each listed hash up in this map; all must be present.
      for hash <- GP.commits_from_lines(lines) do
        assert Map.has_key?(grouped, hash), "commit #{hash} missing from grouped map"
      end
    end

    test "at least one author is derived (so peers can be spawned)" do
      lines = GitLog.log_lines()
      {_by_author, authors} = GP.group_by_author(GP.parse_lines(lines))
      assert length(authors) > 0
    end
  end
end
