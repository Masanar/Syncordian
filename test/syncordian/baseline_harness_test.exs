defmodule Syncordian.BaselineHarnessTest do
  @moduledoc """
  What a baseline implementation has to provide before the harness can replay a history with it.

  These are not tests of Fugue's convergence, which is the replay's job. They are tests of the
  three things that made a Fugue replay unusable, each of which failed silently rather than
  loudly, and each of which is one line to break again.

    * The dump is named `document_peer_<id>`. Every driver waits for two consecutive identical
      dumps under that glob, so a file written as `tree_peer_<id>` left the wait spinning until it
      was killed, with the documents on disk the whole time.
    * The peer answers `{:request_content_hash, pid, ref}`. The supervisor's per-commit barrier
      polls it to learn the author has caught up. An implementation that cannot answer is paced by
      a four second sleep per commit instead, which was most of what a baseline replay cost.
    * The traversal that materializes the document holds its order. It was rewritten from
      quadratic concatenation to a single pass, and the order it produces is the document.
  """
  use ExUnit.Case, async: false

  alias Syncordian.CRDT.Fugue.Info
  alias Syncordian.CRDT.Fugue.Peer, as: FuguePeer
  alias Syncordian.CRDT.Fugue.Tree
  alias Syncordian.CRDT.Logoot.Peer, as: LogootPeer

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "syncordian-baseline-test-#{System.unique_integer([:positive])}"
      )

    Syncordian.Run.reset!()
    Syncordian.Run.install!(seed: 1, delay: :none, root: root)

    on_exit(fn ->
      File.rm_rf(root)
      Syncordian.Run.reset!()
    end)

    %{root: root}
  end

  describe "the dump the drivers look for" do
    test "is written as document_peer_<id>, which is the name every driver globs", %{root: root} do
      Info.save_tree_content(Tree.new(), 7)

      assert File.exists?(Path.join(root, "documents/fugue/document_peer_7")),
             "the drivers wait on document_peer_*; anything else leaves them waiting forever"

      refute File.exists?(Path.join(root, "documents/fugue/tree_peer_7"))
    end
  end

  describe "Logoot, which needed the same three fixes" do
    test "writes its dump under document_peer_<id> too", %{root: root} do
      pid = LogootPeer.start(3, 2)
      LogootPeer.save_content(pid)

      assert eventually(fn ->
               File.exists?(Path.join(root, "documents/logoot/document_peer_3"))
             end),
             "the drivers glob document_peer_*; Logoot used to write document_<id>"

      refute File.exists?(Path.join(root, "documents/logoot/document_3"))

      Process.exit(pid, :kill)
      :global.unregister_name(3)
    end

    test "answers the barrier probe" do
      pid = LogootPeer.start(4, 2)
      ref = make_ref()
      send(pid, {:request_content_hash, self(), ref})

      assert_receive {:content_hash, ^ref, _hash}, 5_000

      Process.exit(pid, :kill)
      :global.unregister_name(4)
    end
  end

  describe "the materialization barrier" do
    test "a peer answers the probe with a digest of the text it would dump" do
      pid = FuguePeer.start(0, 2)
      ref = make_ref()
      send(pid, {:request_content_hash, self(), ref})

      hash =
        receive do
          {:content_hash, ^ref, hash} -> hash
        after
          5_000 -> flunk("no answer: the supervisor would fall back to a fixed delay per commit")
        end

      # The same bytes the dump holds, so the barrier and the convergence check cannot disagree
      # about what this replica shows.
      assert hash == :erlang.md5(Info.string_tree_content(Tree.new()))

      Process.exit(pid, :kill)
      :global.unregister_name(0)
    end

    test "a peer answers the pending-dump request instead of reporting a wrong message", %{
      root: root
    } do
      pid = FuguePeer.start(1, 2)
      send(pid, {:write_pending_dump})

      path = Path.join(root, "documents/fugue/document_peer_1")
      assert eventually(fn -> File.exists?(path) end), "no dump was written"

      Process.exit(pid, :kill)
      :global.unregister_name(1)
    end
  end

  describe "the traversal that materializes a document" do
    test "keeps the order the previous quadratic version produced" do
      # The rewrite is only safe if the order is untouched, since the order is the document. This
      # is the previous implementation, kept as the oracle it is.
      tree = sample_tree()

      assert Tree.traverse(tree) ==
               reference_traverse(tree, Syncordian.CRDT.Fugue.Node.get_null_id(), false)

      assert Tree.full_traverse(tree) ==
               reference_traverse(tree, Syncordian.CRDT.Fugue.Node.get_null_id(), true)
    end
  end

  # A tree with enough structure for the order to be observable: several inserts, both sides of
  # the root, and a tombstone.
  defp sample_tree do
    # `insert/5` builds the node against the tree as it stands, `insert_local/2` puts it in. Two
    # replica ids and a position that is not always the end, so the walk has both sides to cover.
    Enum.reduce(0..5, Tree.new(), fn index, tree ->
      position = if rem(index, 3) == 0, do: 0, else: div(index, 2)
      node = Tree.insert(tree, rem(index, 2), index, position, "line #{index}")
      Tree.insert_local(tree, node)
    end)
  end

  # The traversal exactly as it was written before the rewrite, concatenations and all.
  defp reference_traverse(tree, id, include_tombstones) do
    recursion = fn ids ->
      Enum.reduce(ids, [], fn child, acc ->
        reference_traverse(tree, child, include_tombstones) ++ acc
      end)
    end

    root_node = Syncordian.CRDT.Fugue.Node.root()

    case Tree.get_full_node(tree, id) do
      {^root_node, [], []} ->
        if include_tombstones, do: [root_node], else: []

      {node, left, right} ->
        left_values = recursion.(left)

        node_value =
          if not Syncordian.CRDT.Fugue.Node.is_tombstone?(node) or include_tombstones,
            do: [node],
            else: []

        left_values ++ node_value ++ recursion.(right)
    end
  end

  # Generous, because these start real peer processes and the suite is often run on a machine that
  # is also replaying a history.
  defp eventually(check, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if check.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end
end
