defmodule Syncordian.ProgressSemanticsTest do
  @moduledoc """
  Pins the delivery rule of the revised Syncordian receive path (WS1, reviewer R1/R2):

    * the progress vector counts **applied inserts only** — a delete does not advance it,
      so an insert authored after a delete is deliverable as soon as the sender's preceding
      *insert* has been applied (the clock gate);
    * inserts and deletes name their authored parents / target by **identity** (op_id), and
      an operation whose named line is not present yet is suspended on that line's arrival
      (the parent / target gate), never dropped;
    * a delete whose target is already tombstoned is a strict no-op;
    * all valid deliveries **converge** regardless of order.

  These are integration tests: a single real receiver peer is driven with crafted,
  admission-authenticated messages, exactly as an author peer would broadcast them, and its
  materialized document is read back. Only the receiver is registered, so its acknowledgement
  broadcasts have no recipients and cannot perturb the assertions. The peer is a hand-written
  receive loop, so a released (re-dispatched) suspended operation lands at the mailbox tail;
  `stable_content/1` reads until two consecutive reads agree, which drains those self-sends.
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

  # Builds the line and the broadcast an author produces for an insert between `left` and
  # `right`. Returns {line, message}; the line can seed the next insert or a delete.
  defp insert_msg(left, right, content, op_id, vector) do
    line = create_line_between_two_lines(content, left, right, @author, op_id)

    tag =
      Byzantine.create_tag_insert(get_signature(left), content, get_signature(right), @author)

    payload =
      {get_line_id(line), content, @author, tag, vector, op_id, get_line_op_id(left),
       get_line_op_id(right)}

    alpha = Byzantine.create_admission(@secret, :ins, payload)
    {line, {:receive_insert_broadcast, payload, alpha}}
  end

  # The broadcast an author produces to retract `target_line`.
  defp delete_msg(target_line, del_op_id) do
    tag = Byzantine.create_tag_delete(get_signature(target_line))
    payload = {get_line_op_id(target_line), get_line_id(target_line), tag, del_op_id}
    alpha = Byzantine.create_admission(@secret, :del, payload)
    {:receive_delete_broadcast, payload, alpha}
  end

  # A fixed single-author scenario: two inserts with the delete of the first sandwiched
  # between them at op-sequence 2, so the second insert's progress vector is [2, 0, 0] —
  # NOT [3, 0, 0]. That gap is the whole point: it proves the vector counts inserts only.
  defp scenario do
    inf = author_infimum()
    sup = author_supremum()
    {line1, m_i1} = insert_msg(inf, sup, "line1", {@author, 1}, [1, 0, 0])
    m_del1 = delete_msg(line1, {@author, 2})
    {_line2, m_i2} = insert_msg(inf, sup, "line2", {@author, 3}, [2, 0, 0])
    %{i1: m_i1, i2: m_i2, del1: m_del1}
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
    ref = make_ref()
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> document
    after
      1000 -> flunk("peer #{inspect(ref)} did not return its document")
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

  # --- (a) the vector counts inserts only ----------------------------------------------

  test "an insert authored after a delete applies once the sender's preceding insert has" do
    %{i1: i1, i2: i2} = scenario()
    pid = spawn_receiver()

    # i2 carries progress [2, 0, 0]. Deliver i1 (progress 1) then i2 (progress 2): the
    # clock gate is satisfied (2 == 1 + 1) precisely because the intervening delete did
    # not advance the vector, so i2 is applied without waiting.
    deliver(pid, [i1, i2])
    content = stable_content(pid)

    assert String.contains?(content, "line1")
    assert String.contains?(content, "line2")
    kill(pid)
  end

  test "an insert ahead of the sender's applied inserts is suspended, then released" do
    %{i1: i1, i2: i2} = scenario()
    pid = spawn_receiver()

    # i2 alone (progress 2) is ahead of the receiver (0 applied): the clock gate suspends it.
    deliver(pid, [i2])
    refute String.contains?(stable_content(pid), "line2")

    # i1 fills the gap; the {:clock_advanced, 0, 1} it fires releases i2 exactly once.
    deliver(pid, [i1])
    content = stable_content(pid)
    assert String.contains?(content, "line1")
    assert String.contains?(content, "line2")
    kill(pid)
  end

  # --- (b) delete before its target suspends on identity, then applies ------------------

  test "a delete arriving before its target suspends on the target's identity and applies after" do
    %{i1: i1, i2: i2, del1: del1} = scenario()
    pid = spawn_receiver()

    # The delete names line1 by op_id {0, 1}; that line is absent, so it suspends on
    # {:line, {0, 1}}. When i1 adds the line, {:line_added, {0, 1}} releases the delete.
    deliver(pid, [del1, i1, i2])
    content = stable_content(pid)

    refute String.contains?(content, "line1")
    assert String.contains?(content, "line2")
    kill(pid)
  end

  # --- (c) a delete of an already-tombstoned target is a no-op --------------------------

  test "a second delete of an already tombstoned line is a strict no-op" do
    %{i1: i1, del1: del1} = scenario()
    # A distinct delete op (different op_id) targeting the same line: a concurrent
    # double-delete, the same code path a post-seen-set replay would take.
    inf = author_infimum()
    sup = author_supremum()
    {line1, _} = insert_msg(inf, sup, "line1", {@author, 1}, [1, 0, 0])
    del1b = delete_msg(line1, {@author, 9})

    pid = spawn_receiver()
    deliver(pid, [i1, del1, del1b])
    content = stable_content(pid)

    refute String.contains?(content, "line1")
    assert Process.alive?(pid)
    kill(pid)
  end

  # --- (d) convergence under every delivery order ---------------------------------------

  test "all delivery orders of {insert1, insert2, delete1} converge to the same document" do
    %{i1: i1, i2: i2, del1: del1} = scenario()
    # The reference: line1 authored then deleted, line2 live.
    expected = "line2\n"

    contents =
      [i1, i2, del1]
      |> permutations()
      |> Enum.map(fn order ->
        pid = spawn_receiver()
        deliver(pid, order)
        content = stable_content(pid)
        kill(pid)
        content
      end)

    assert Enum.all?(contents, &(&1 == expected)),
           "delivery orders diverged: #{inspect(Enum.uniq(contents))}"
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest]
  end
end
