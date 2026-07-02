defmodule Syncordian.GitParserTest do
  use ExUnit.Case, async: true

  alias Syncordian.GitParser, as: GP

  # These tests feed the parser *raw* `git log -p` output — the exact shape the live
  # experiment now produces via `Syncordian.GitLog` — rather than the hand-modified
  # fixture that used to live under `test/git_log/`. The synthetic log below is expressed
  # as an explicit list of lines (not a heredoc) so leading spaces on diff context lines
  # are preserved verbatim, matching what git emits.
  #
  # It deliberately exercises the cases that broke the old, fixture-tuned parser and that
  # the hardening added for live reading must handle:
  #   * a diff/message line that merely mentions "commit" (e.g. commitgoods.com) must NOT
  #     be mistaken for a commit boundary;
  #   * a single-line hunk header with an omitted `,count` (`@@ -5 +5,2 @@`);
  #   * a delete-then-insert hunk (index / test_index accounting);
  #   * a commit that touched the file without producing a hunk (empty position_changes).

  @hash_a String.duplicate("a", 40)
  @hash_b String.duplicate("b", 40)
  @hash_c String.duplicate("c", 40)
  @hash_d String.duplicate("d", 40)

  # Newest commit first, exactly like `git log`.
  @raw_lines [
    # --- Commit A: a plain insert; both the message and an inserted line say "commit" ---
    "commit #{@hash_a}",
    "Author: Alice Example <alice@example.com>",
    "Date:   Mon Dec 4 16:06:50 2023 +0100",
    "",
    "    docs: mention how to commit changes (#1)",
    "",
    "diff --git a/README.md b/README.md",
    "index 49998687..98743432 100644",
    "--- a/README.md",
    "+++ b/README.md",
    "@@ -10,3 +10,4 @@ Install section",
    " context one",
    " context two",
    "+visit https://commitgoods.com for stickers",
    " context three",
    # --- Commit B: single-line hunk header (git omits `,1` for the old side). The added
    # line is followed by a trailing context line, as git emits: `parse_changes/1` treats
    # the final line of a commit's last hunk as a separator and drops it, so meaningful
    # ops must never be the very last line (they never are in real `git log` output). ---
    "commit #{@hash_b}",
    "Author: Bob Builder <bob@example.com>",
    "Date:   Sun Dec 3 10:00:00 2023 +0100",
    "",
    "    single line change",
    "",
    "diff --git a/README.md b/README.md",
    "index aaaaaaaa..bbbbbbbb 100644",
    "--- a/README.md",
    "+++ b/README.md",
    "@@ -5 +5,2 @@",
    "+added line",
    " keep",
    # --- Commit C: delete two lines, insert one (index / test_index accounting) ---
    "commit #{@hash_c}",
    "Author: Carol Coder <carol@example.com>",
    "Date:   Sat Dec 2 09:00:00 2023 +0100",
    "",
    "    replace lines",
    "",
    "diff --git a/README.md b/README.md",
    "index cccccccc..dddddddd 100644",
    "--- a/README.md",
    "+++ b/README.md",
    "@@ -20,4 +20,3 @@ Section",
    " keep 1",
    "-removed A",
    "-removed B",
    "+added X",
    " keep 2",
    # --- Commit D: mode change only, no hunk => empty position_changes ---
    "commit #{@hash_d}",
    "Author: Dana Dev <dana@example.com>",
    "Date:   Fri Dec 1 08:00:00 2023 +0100",
    "",
    "    chmod readme",
    "",
    "diff --git a/README.md b/README.md",
    "old mode 100644",
    "new mode 100755"
  ]

  defp parsed, do: GP.parse_lines(@raw_lines) |> Enum.to_list()
  defp by_hash(hash), do: Enum.find(parsed(), &(&1.commit_hash == hash))

  describe "commit header detection (is_commit_hash?/find_commit_hash)" do
    test "matches a real header line and extracts the hash" do
      assert GP.is_commit_hash?("commit #{@hash_a}")
      assert GP.find_commit_hash("commit #{@hash_a}") == @hash_a
    end

    test "a diff line that merely contains 'commit' is NOT a header (commitgoods regression)" do
      line = "+visit https://commitgoods.com for stickers"
      refute GP.is_commit_hash?(line)
      # find_commit_hash leaves a non-header line untouched.
      assert GP.find_commit_hash(line) == line
    end

    test "an indented message mentioning a commit is NOT a header" do
      refute GP.is_commit_hash?("    Reverts commit deadbeef1234")
    end

    test "a non-hex word after 'commit' at column 0 is not a valid hash" do
      refute GP.is_commit_hash?("commit not-a-hash")
    end
  end

  describe "find_position_in_line/1 (optional hunk counts)" do
    test "both counts present" do
      assert GP.find_position_in_line("@@ -88,6 +88,14 @@") == {{88, 6}, {88, 14}, 14}
    end

    test "trailing section heading is ignored" do
      assert GP.find_position_in_line("@@ -46,7 +46,7 @@ Twitter section") ==
               {{46, 7}, {46, 7}, 7}
    end

    test "omitted old count defaults to 1" do
      assert GP.find_position_in_line("@@ -5 +5,2 @@") == {{5, 1}, {5, 2}, 2}
    end

    test "omitted new count defaults to 1" do
      assert GP.find_position_in_line("@@ -5,3 +5 @@") == {{5, 3}, {5, 1}, 3}
    end

    test "both counts omitted default to 1" do
      assert GP.find_position_in_line("@@ -5 +5 @@") == {{5, 1}, {5, 1}, 1}
    end

    test "a non-hunk line is returned unchanged" do
      assert GP.find_position_in_line(" just some context") == " just some context"
    end
  end

  describe "parse_changes/1 empty-diff guard" do
    test "a commit with no positional changes yields an empty list (no crash)" do
      assert GP.parse_changes([]) == []
    end
  end

  describe "parse_lines/1 end-to-end on raw git output" do
    test "produces one map per real commit — content mentioning 'commit' does not split" do
      # Four real commits; the commitgoods.com line must not create a phantom fifth.
      assert length(parsed()) == 4

      assert Enum.map(parsed(), & &1.commit_hash) == [@hash_a, @hash_b, @hash_c, @hash_d]
    end

    test "extracts author ids (trimmed, email stripped)" do
      assert by_hash(@hash_a).author_id == "Alice Example"
      assert by_hash(@hash_c).author_id == "Carol Coder"
    end

    test "a plain insert becomes a single :insert op anchored at the hunk position" do
      [[op]] = by_hash(@hash_a).position_changes

      assert op.op == :insert
      assert op.content == "visit https://commitgoods.com for stickers"
      assert op.global_position == 10
      assert op.index == 12
      assert op.test_index == 12
      assert op.current_delete_ops == 0
    end

    test "a single-line hunk (omitted count) parses into an insert op" do
      [[op]] = by_hash(@hash_b).position_changes

      assert op.op == :insert
      assert op.content == "added line"
      assert op.global_position == 5
    end

    test "delete-then-insert keeps the tombstone-aware index accounting" do
      [[del_a, del_b, ins]] = by_hash(@hash_c).position_changes

      assert del_a.op == :delete
      assert del_a.index == 21
      assert del_a.test_index == 21
      assert del_a.current_delete_ops == 0

      assert del_b.op == :delete
      assert del_b.index == 22
      # test_index is offset by the one earlier delete in this hunk.
      assert del_b.test_index == 21
      assert del_b.current_delete_ops == 1

      assert ins.op == :insert
      assert ins.content == "added X"
      assert ins.index == 23
      # offset by the two earlier deletes.
      assert ins.test_index == 21
      assert ins.current_delete_ops == 2
    end

    test "a commit with no hunk yields empty position_changes instead of crashing" do
      assert by_hash(@hash_d).position_changes == []
    end
  end

  describe "commits_from_lines/1" do
    test "returns the hashes oldest-first (reverse of git log order)" do
      assert GP.commits_from_lines(@raw_lines) == [@hash_d, @hash_c, @hash_b, @hash_a]
    end

    test "counts real commits only — ignores 'commit' in diff/message content" do
      assert length(GP.commits_from_lines(@raw_lines)) == 4
    end
  end

  describe "replay-fidelity regressions" do
    test "an op line ending the last hunk at EOF is kept, not dropped as a separator" do
      # A commit whose final hunk ends with a real change and no trailing context (an
      # edit at end-of-file, last commit of the log). The old after_fun dropped it.
      raw = [
        "commit #{@hash_a}",
        "Author: Alice Example <alice@example.com>",
        "Date:   Mon Dec 4 16:06:50 2023 +0100",
        "",
        "    append at EOF",
        "",
        "diff --git a/README.md b/README.md",
        "index 49998687..98743432 100644",
        "--- a/README.md",
        "+++ b/README.md",
        "@@ -10,2 +10,3 @@",
        " context one",
        " context two",
        "+added at EOF"
      ]

      [commit] = GP.parse_lines(raw) |> Enum.to_list()
      [[op]] = commit.position_changes
      assert op.op == :insert
      assert op.content == "added at EOF"
    end

    test "a merge commit's 'Merge:' header line does not displace the author id" do
      raw = [
        "commit #{@hash_b}",
        "Merge: 1234abcd 5678efab",
        "Author: Bob Builder <bob@example.com>",
        "Date:   Sun Dec 3 10:00:00 2023 +0100",
        "",
        "    Merge branch 'feature' (#42)",
        "",
        "diff --git a/README.md b/README.md",
        "index aaaaaaaa..bbbbbbbb 100644",
        "--- a/README.md",
        "+++ b/README.md",
        "@@ -5,2 +5,3 @@",
        " keep",
        "+from the merged branch",
        " keep 2"
      ]

      [commit] = GP.parse_lines(raw) |> Enum.to_list()
      assert commit.author_id == "Bob Builder"
      [[op]] = commit.position_changes
      assert op.content == "from the merged branch"
    end

    test "meaningful trailing whitespace in file content survives parsing" do
      # e.g. Markdown table rows ending in a space: trimming it made the replayed
      # document diverge from the real file.
      raw = [
        "commit #{@hash_c}",
        "Author: Carol Coder <carol@example.com>",
        "Date:   Sat Dec 2 09:00:00 2023 +0100",
        "",
        "    add table row",
        "",
        "diff --git a/README.md b/README.md",
        "index cccccccc..dddddddd 100644",
        "--- a/README.md",
        "+++ b/README.md",
        "@@ -5,2 +5,3 @@",
        " keep",
        "+| LCARS | ok | ",
        " keep 2"
      ]

      [commit] = GP.parse_lines(raw) |> Enum.to_list()
      [[op]] = commit.position_changes
      assert op.content == "| LCARS | ok | "
    end
  end

  describe "supervisor invariant" do
    test "every hash from commits_from_lines is a key in the grouped parse map" do
      # `Syncordian.Supervisor.edit/5` does `Map.get(commit_group_map, commit_hash)`; if a
      # listed hash were missing (e.g. from a false split) that lookup would crash.
      grouped = GP.group_by_commit(parsed())

      for hash <- GP.commits_from_lines(@raw_lines) do
        assert Map.has_key?(grouped, hash), "commit #{hash} missing from grouped map"
      end
    end

    test "one distinct author per commit yields four author peers" do
      {_by_author, authors} = GP.group_by_author(parsed())
      assert length(authors) == 4
    end
  end
end
