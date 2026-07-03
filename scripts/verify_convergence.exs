# Dynamic convergence verification for the /supervisor experiment (Syncordian).
#
# Replaces the fixed-document assumption of `identical.sh`: the expected final document is
# derived from the SAME live git source the experiment replays (Syncordian.GitLog config /
# env), so the check follows whatever repo + tracked file the run used.
#
# Checks, in order:
#   1. every peer document dump under debug/documents/syncordian/ is byte-identical;
#   2. the converged document equals the tracked file at the LAST REPLAYED mainline commit
#      of the configured clone (`git show <last-commit>:<file>`) — byte-for-byte;
#   3. if a raw dump exists (debug/documents/syncordian/raw/document), no line is still
#      :aura — at quiescence every live line must have settled (def:apply / responses).
#
# Run from `code/` after "Write current peers document":
#
#     mix run --no-start scripts/verify_convergence.exs

docs_dir = "debug/documents/syncordian"
raw_path = Path.join(docs_dir, "raw/document")

fail = fn msg ->
  IO.puts("FAIL ❌  #{msg}")
  System.halt(1)
end

# ---- 1. all peers byte-identical ------------------------------------------------------
peer_docs = Path.wildcard(Path.join(docs_dir, "document_peer_*")) |> Enum.sort()

if peer_docs == [], do: fail.("no peer documents found under #{docs_dir}")

[reference | rest] = peer_docs
reference_content = File.read!(reference)

Enum.each(rest, fn path ->
  if File.read!(path) != reference_content,
    do: fail.("peer documents diverge: #{path} != #{reference}")
end)

IO.puts("OK  #{length(peer_docs)} peer documents byte-identical")

# ---- 2. converged document == tracked file at the last replayed commit ----------------
repo = Syncordian.GitLog.repo_path()
file = Syncordian.GitLog.tracked_file()

last_commit =
  Syncordian.GitLog.log_lines()
  |> Syncordian.GitParser.commits_from_lines()
  |> List.last()

{expected, 0} = System.cmd("git", ["-C", repo, "show", "#{last_commit}:#{file}"])

# The line-based document cannot represent a missing final newline (each live line is
# materialized with a trailing "\n"), so normalize a no-final-newline git state.
expected =
  if expected != "" and not String.ends_with?(expected, "\n"),
    do: expected <> "\n",
    else: expected

if reference_content == expected do
  IO.puts(
    "OK  converged document == #{file} at #{String.slice(last_commit, 0, 10)} " <>
      "(#{byte_size(expected)} bytes) in #{Path.expand(repo)}"
  )
else
  File.write!("debug/documents/syncordian/expected_from_git", expected)

  fail.(
    "converged document differs from #{file} at #{String.slice(last_commit, 0, 10)}; " <>
      "expected copy written to #{docs_dir}/expected_from_git — diff it against #{reference}"
  )
end

# ---- 3. no :aura left at quiescence ----------------------------------------------------
if File.exists?(raw_path) do
  raw = File.read!(raw_path)
  aura = raw |> String.split(":aura") |> length() |> Kernel.-(1)

  if aura > 0,
    do: fail.("#{aura} line(s) still :aura in the raw dump — network did not settle"),
    else: IO.puts("OK  raw dump has no :aura lines (all settled or tombstoned)")
else
  IO.puts("--  raw dump not found (#{raw_path}); skipped the :aura settlement check")
end

IO.puts("PASS ✅  network converged to the live git state")
