defmodule Syncordian.InsiderScopeTest do
  @moduledoc """
  Records the boundary of Syncordian's authentication as an executable non-goal.

  Every key is derived from the one document boundary secret under a label that names only
  the domain, so all admitted peers hold identical key material and no per-peer secret
  exists. The consequence is that the mechanism authenticates *group membership* and not
  peer identity: the claimed `peer_id` enters each authenticator as an authenticated field,
  never as key material. This is `prop:insider` in the paper (`Latex/content/formalism.tex`),
  and the scope statement at the head of `Latex/content/byzantine.tex`.

  The tests below therefore **assert that the capability holds**. They are not regressions to
  be fixed. They exist so the paper's limitation is backed by something that runs, and so a
  later change that claims to authenticate peer identity has to confront them.

  What *is* guaranteed is the outsider case, covered by `Syncordian.BoundarySecretTest` and
  `Syncordian.WireSignatureTest`: a node without the secret mints nothing admissible. What is
  not guaranteed is who, among the admitted peers, composed a given message.
  """
  use ExUnit.Case, async: false

  import Syncordian.Line_Object
  import Syncordian.Line
  alias Syncordian.Byzantine
  alias Syncordian.Peer

  @network_size 3
  @author 0
  # The peer whose acknowledgement is forged. It never runs and never acts.
  @impersonated 1
  @receiver 2
  @secret {"Infimum", "Supremum"}

  setup do
    Byzantine.install_boundary_secret!(@secret)
    :ok
  end

  # --- unit level: the tags themselves --------------------------------------------------

  # A minimal acknowledged line carrying a known stored signature and op_id.
  defp acked_line do
    create_line_from_wire({:path, [{1, 0}]}, "content", @author, @network_size)
    |> seal_line_authored("ABCD1234", {@author, 1}, nil, nil, nil)
  end

  describe "an admitted peer can authenticate as any peer" do
    test "it mints a response tag naming a peer that is not itself" do
      line = acked_line()
      # The forger passes @impersonated as a free argument. Nothing ties the peer_id to the
      # caller, because the :ack key depends on the boundary secret alone.
      forged = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), @impersonated)

      assert Byzantine.check_tag_ack(forged, line, @impersonated),
             "expected the response tag to verify under the impersonated peer id, " <>
               "since peer_id is an authenticated field and not key material"
    end

    test "it mints the admission authenticator for that same response" do
      line = acked_line()
      forged = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), @impersonated)
      payload = {get_line_id(line), @impersonated, forged}
      alpha = Byzantine.create_admission(@secret, :ack, payload)

      assert Byzantine.check_admission(alpha, @secret, :ack, payload)
    end

    test "it mints a response for every peer in the network" do
      line = acked_line()

      # The whole response checklist is computable by one secret holder.
      for peer_id <- 0..(@network_size - 1) do
        tag = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), peer_id)
        assert Byzantine.check_tag_ack(tag, line, peer_id)
      end
    end
  end

  # --- integration level: one forger settles a line alone -------------------------------

  describe "a forged response settles a line at a real replica" do
    test "one response naming a peer that never acted moves the line to :settled" do
      pid = spawn_receiver()

      try do
        {line, insert} = authored_insert()
        send(pid, insert)
        await_line(pid, get_line_id(line))

        # The receiver has applied the insert, so the checklist holds the author's entry and
        # its own. Only @impersonated is outstanding, and that peer is not running.
        assert commit_at_of(pid, get_line_id(line)) == [true, false, true]
        assert status_of(pid, get_line_id(line)) == :aura

        send(pid, forged_ack(line, @impersonated))
        await_settled(pid, get_line_id(line))

        # @impersonated never acknowledged anything. Its entry is set because a response is
        # admissible whenever its tags recompute, whoever composed it.
        assert commit_at_of(pid, get_line_id(line)) == [true, true, true]

        assert status_of(pid, get_line_id(line)) == :settled,
               ":settled certifies that each response came from an admitted peer, " <>
                 "not that each named peer holds the line"
      after
        kill(pid)
      end
    end
  end

  # --- message crafting ------------------------------------------------------------------

  # The insert an author broadcasts between the two boundary lines.
  defp authored_insert do
    left = create_infimum_line(@author, @network_size)
    right = create_supremum_line(@author, @network_size)
    content = "settled by a forgery"
    op_id = {@author, 1}
    line = create_line_between_two_lines(content, left, right, @author, op_id)

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
        nil
      )

    payload =
      {get_line_id(line), content, @author, tag, [1, 0, 0], op_id, get_line_op_id(left),
       get_line_op_id(right), nil}

    {line,
     {:receive_insert_broadcast, payload, Byzantine.create_admission(@secret, :ins, payload)}}
  end

  # A response for `line` naming `acker`, composed by a secret holder that is not `acker`.
  defp forged_ack(line, acker) do
    tag = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), acker)
    payload = {get_line_id(line), acker, tag}

    {:receive_confirmation_line_insertion, payload,
     Byzantine.create_admission(@secret, :ack, payload)}
  end

  # --- receiver driving (same shape as Syncordian.ReissueAliasTest) ---------------------

  defp spawn_receiver do
    pid = Peer.start(@receiver, @network_size)
    # Let the peer process its {:save_pid, ...}, which initializes its vector clock.
    Process.sleep(20)
    pid
  end

  defp kill(pid) do
    Process.exit(pid, :kill)
    :global.unregister_name(@receiver)
  end

  defp document(pid) do
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> document
    after
      1000 -> flunk("peer did not return its document")
    end
  end

  defp line_of(pid, line_id) do
    pid |> document() |> Enum.find(&(get_line_id(&1) == line_id))
  end

  defp commit_at_of(pid, line_id), do: pid |> line_of(line_id) |> get_commit_at()
  defp status_of(pid, line_id), do: pid |> line_of(line_id) |> get_line_status()

  defp await_line(pid, line_id, attempts \\ 200) do
    cond do
      line_of(pid, line_id) != nil -> :ok
      attempts <= 0 -> flunk("the insert was never applied")
      true -> await_line(pid, line_id, attempts - 1)
    end
  end

  defp await_settled(pid, line_id, attempts \\ 200) do
    cond do
      status_of(pid, line_id) == :settled -> :ok
      attempts <= 0 -> :ok
      true -> await_settled(pid, line_id, attempts - 1)
    end
  end
end
