defmodule Syncordian.ReissueAliasTest do
  @moduledoc """
  Pins the delete-and-move semantics of the interleaving repair (WS4, reviewer R6).

  When a block is re-placed, each moved line is re-issued as a fresh insert carrying a
  *supersede link* that names the line it replaces. Applying such an insert adds the new line
  and retracts the named one in the same step, and records the link in the replica's alias
  map. Two properties follow, and this file tests both against a real receiver peer:

    * **single live copy** — at most one line of an alias chain is live at any moment, so
      moved content is never duplicated;
    * **no resurrection** — content deleted concurrently with a move stays deleted, in either
      arrival order, and across a chain of successive moves. A delete of an old identity
      follows the chain forward to the current copy, and a move onto already-deleted content
      is born a tombstone.

  The re-issue's wire tag binds the superseded line's stored signature, exactly as a delete
  tag binds its target, so a sender that does not hold that signature cannot retract the line.

  Like `Syncordian.ProgressSemanticsTest`, these are integration tests: one real receiver peer
  is driven with crafted, admission-authenticated messages, exactly as an author peer would
  broadcast them, and its document is read back. Only the receiver is registered, so its
  acknowledgement broadcasts have no recipients and cannot perturb the assertions.
  """
  use ExUnit.Case, async: false

  import Syncordian.Line_Object
  import Syncordian.Line
  alias Syncordian.Byzantine
  alias Syncordian.Info
  alias Syncordian.Peer

  @network_size 3
  @author 0
  @receiver 2
  # The default boundary secret; installed explicitly so crafted authenticators match the
  # receiver's regardless of test order.
  @secret {"Infimum", "Supremum"}

  setup do
    Byzantine.install_boundary_secret!(@secret)
    :ok
  end

  # --- message crafting (what an author peer puts on the wire) --------------------------

  defp author_infimum, do: create_infimum_line(@author, @network_size)
  defp author_supremum, do: create_supremum_line(@author, @network_size)

  # The insert an author broadcasts between `left` and `right`. `superseded` is the line this
  # insert replaces (a re-issue), or nil for an ordinary insert. Returns {line, message}.
  defp insert_msg(left, right, content, op_id, vector, superseded \\ nil) do
    line = create_line_between_two_lines(content, left, right, @author, op_id)
    {line, insert_msg_for(line, left, right, content, op_id, vector, superseded, superseded)}
  end

  # Same, but the tag is computed over `tag_superseded` while the payload names
  # `link_superseded`. Passing two different lines forges the supersede authorization.
  defp insert_msg_for(line, left, right, content, op_id, vector, tag_superseded, link_superseded) do
    tag =
      Byzantine.create_tag_insert(
        get_signature(left),
        get_line_op_id(left),
        content,
        get_signature(right),
        get_line_op_id(right),
        @author,
        op_id,
        get_line_id(line),
        tag_superseded
      )

    replaces = link_superseded && get_line_op_id(link_superseded)

    payload =
      {get_line_id(line), content, @author, tag, vector, op_id, get_line_op_id(left),
       get_line_op_id(right), replaces}

    alpha = Byzantine.create_admission(@secret, :ins, payload)
    {:receive_insert_broadcast, payload, alpha}
  end

  # The broadcast an author produces to delete `target_line`.
  defp delete_msg(target_line, del_op_id) do
    tag =
      Byzantine.create_tag_delete(
        get_signature(target_line),
        get_line_op_id(target_line),
        del_op_id
      )

    payload = {get_line_op_id(target_line), get_line_id(target_line), tag, del_op_id}
    alpha = Byzantine.create_admission(@secret, :del, payload)
    {:receive_delete_broadcast, payload, alpha}
  end

  # The scenario every test draws from: the author writes one line, then the repair moves it
  # once and then a second time, and a delete names the ORIGINAL identity. The three inserts
  # are the author's inserts 1, 2 and 3, so their progress ranks are 1, 2 and 3; the delete
  # carries no rank. Each move places the new copy left of the copy it supersedes, which is
  # what a re-placement into a gap does.
  defp scenario do
    inf = author_infimum()
    sup = author_supremum()

    {line1, m_ins} = insert_msg(inf, sup, "moved", {@author, 1}, [1, 0, 0])
    {line2, m_move1} = insert_msg(inf, line1, "moved", {@author, 2}, [2, 0, 0], line1)
    {line3, m_move2} = insert_msg(inf, line2, "moved", {@author, 3}, [3, 0, 0], line2)

    %{
      line1: line1,
      line2: line2,
      line3: line3,
      ins: m_ins,
      move1: m_move1,
      move2: m_move2,
      del: delete_msg(line1, {@author, 4})
    }
  end

  # --- receiver driving ----------------------------------------------------------------

  defp spawn_receiver do
    pid = Peer.start(@receiver, @network_size)
    # Let the peer process its {:save_pid, ...} (which initializes its vector clock).
    Process.sleep(20)
    pid
  end

  defp kill(pid) do
    Process.exit(pid, :kill)
    :global.unregister_name(@receiver)
  end

  defp deliver(pid, messages), do: Enum.each(messages, &send(pid, &1))

  defp document(pid) do
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> document
    after
      1000 -> flunk("peer did not return its document")
    end
  end

  # Reads the materialized (tombstone-filtered) content until two consecutive reads agree,
  # which drains any self-re-dispatched suspended operations still in the mailbox.
  defp stable_content(pid, prev \\ :none, attempts \\ 200) do
    content = pid |> document() |> Info.string_document_content()

    cond do
      content == prev -> content
      attempts <= 0 -> content
      true -> stable_content(pid, content, attempts - 1)
    end
  end

  # Every line carrying `content`, with its status, in document order.
  defp copies(pid, content) do
    pid
    |> document()
    |> Enum.filter(&(get_content(&1) == content))
    |> Enum.map(&{get_line_op_id(&1), get_line_status(&1)})
  end

  defp live_copies(pid, content),
    do: pid |> copies(content) |> Enum.reject(fn {_op, status} -> status == :tombstone end)

  # --- no resurrection, in both arrival orders ------------------------------------------

  test "a delete that names the superseded identity reaches the moved copy" do
    %{ins: ins, move1: move1, del: del} = scenario()
    pid = spawn_receiver()

    # The move is applied first, so the delete names a line that is already a tombstone. It
    # must follow the alias link forward and retract the copy that replaced it.
    deliver(pid, [ins, move1, del])
    assert stable_content(pid) == ""
    assert live_copies(pid, "moved") == []
    assert length(copies(pid, "moved")) == 2

    kill(pid)
  end

  test "a move onto content that was already deleted here is born a tombstone" do
    %{ins: ins, move1: move1, del: del} = scenario()
    pid = spawn_receiver()

    # The delete lands before the move. The re-issued line must inherit the retracted status
    # of the line it supersedes, or the deleted content would come back.
    deliver(pid, [ins, del, move1])
    assert stable_content(pid) == ""
    assert live_copies(pid, "moved") == []

    kill(pid)
  end

  test "a delete stays applied across a further move of the same content" do
    %{ins: ins, move1: move1, move2: move2, del: del} = scenario()
    pid = spawn_receiver()

    # The second-order race: the delete arrives between two successive moves, so the writer
    # of the block moved content it had not yet seen deleted. The status has to travel one
    # more link.
    deliver(pid, [ins, move1, del, move2])
    assert stable_content(pid) == ""
    assert live_copies(pid, "moved") == []
    assert length(copies(pid, "moved")) == 3

    kill(pid)
  end

  # --- single live copy ------------------------------------------------------------------

  test "a chain of two moves leaves exactly one live copy and two tombstones" do
    %{ins: ins, move1: move1, move2: move2, line3: line3} = scenario()
    pid = spawn_receiver()

    deliver(pid, [ins, move1, move2])
    assert stable_content(pid) == "moved\n"

    assert live_copies(pid, "moved") == [{get_line_op_id(line3), :aura}]

    assert Enum.count(copies(pid, "moved"), fn {_op, status} -> status == :tombstone end) == 2

    kill(pid)
  end

  test "no two copies of moved content are ever live at the same time" do
    %{ins: ins, move1: move1, move2: move2, del: del} = scenario()
    pid = spawn_receiver()

    # Checked after every single delivery, so a window in which both the superseded and the
    # replacement line are live would be caught wherever it opened.
    Enum.each([ins, move1, move2, del], fn message ->
      deliver(pid, [message])
      stable_content(pid)

      assert length(live_copies(pid, "moved")) <= 1,
             "two live copies after delivering #{elem(message, 0)}"
    end)

    kill(pid)
  end

  # --- convergence under every delivery order -------------------------------------------

  test "all delivery orders of {insert, move, delete} converge to the same document" do
    %{ins: ins, move1: move1, del: del} = scenario()

    contents =
      [ins, move1, del]
      |> permutations()
      |> Enum.map(fn order ->
        pid = spawn_receiver()
        deliver(pid, order)
        content = stable_content(pid)
        kill(pid)
        content
      end)

    assert Enum.all?(contents, &(&1 == "")),
           "delivery orders diverged: #{inspect(Enum.uniq(contents))}"
  end

  # --- the supersede link is authorized --------------------------------------------------

  test "a re-issue whose tag does not bind the superseded line is rejected" do
    inf = author_infimum()
    sup = author_supremum()
    {line1, ins} = insert_msg(inf, sup, "moved", {@author, 1}, [1, 0, 0])

    # A line the sender does not hold the stored signature of: same identity as the real
    # target, but a different signature. The forged tag binds THAT line, while the payload
    # names the genuine one, so the receiver's recomputation over its own copy fails.
    impostor = line(line1, signature: "not the stored signature")
    moved = create_line_between_two_lines("moved", inf, line1, @author, {@author, 2})

    forged =
      insert_msg_for(moved, inf, line1, "moved", {@author, 2}, [2, 0, 0], impostor, line1)

    pid = spawn_receiver()
    deliver(pid, [ins, forged])

    # The original line is untouched: the forged re-issue neither added its copy nor
    # retracted anything.
    assert stable_content(pid) == "moved\n"
    assert live_copies(pid, "moved") == [{get_line_op_id(line1), :aura}]

    kill(pid)
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest]
  end
end
