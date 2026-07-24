defmodule Syncordian.WireSignatureTest do
  @moduledoc """
  Pins the dual keyed-MAC signature scheme and the admission authenticator of
  `Syncordian.Byzantine`, mirroring the paper's formal model:

    * stored signature σ under the `:doc` key — never transmitted, sealed locally by every
      replica from the parent pair that verifies the insert wire tag;
    * wire tags under the `:ins` / `:del` / `:ack` keys — what actually travels, each
      binding the operation's authored identity (op_id) and, for inserts, the position;
    * admission authenticator α under the `:adm` key — keyed by the boundary secret, bound
      to the full message payload, checked before anything else at receipt.

  The central convergence invariant is pinned end-to-end at unit level: a receiver that
  locates the authored parents by identity seals the *same* stored signature the author
  computed, without σ ever riding a message.
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  import Syncordian.Line
  import Syncordian.Document
  alias Syncordian.Byzantine

  @network_size 3
  @author_peer 1
  @author_op {@author_peer, 1}
  @boundary {"Infimum", "Supremum"}

  # Author side for a single line placed between the boundary sentinels. Returns the
  # authored line (carrying the σ the author computed), the insert wire tag it broadcasts,
  # and the two boundary lines.
  defp author_side(content) do
    infimum = create_infimum_line(0, @network_size)
    supremum = create_supremum_line(0, @network_size)

    authored_line =
      create_line_between_two_lines(content, infimum, supremum, @author_peer, @author_op)

    insert_tag =
      Byzantine.create_tag_insert(
        get_signature(infimum),
        get_line_op_id(infimum),
        content,
        get_signature(supremum),
        get_line_op_id(supremum),
        @author_peer,
        @author_op,
        get_line_id(authored_line)
      )

    {authored_line, insert_tag, infimum, supremum}
  end

  describe "domain (key) separation" do
    test "the insert wire tag never equals the stored signature on identical fields" do
      # Identical eight-field input under two different domain keys (:doc vs :ins). The
      # tags differ because the keys differ, not because of any prefix byte in the encoding.
      fields = [
        "LEFT_SIG",
        {-1, 0},
        "content",
        "RIGHT_SIG",
        {-1, 1},
        @author_peer,
        @author_op,
        {:path, [{1, @author_peer}]}
      ]

      assert apply(Byzantine, :create_signature_doc, fields) !=
               apply(Byzantine, :create_tag_insert, fields)
    end

    test "tags of different kinds are pairwise distinct on overlapping inputs" do
      sig = "SOME_STORED_SIGNATURE"
      op = {1, 1}
      t_del = Byzantine.create_tag_delete(sig, op, {1, 2})
      t_ack = Byzantine.create_tag_ack(sig, op, @author_peer)

      t_ins =
        Byzantine.create_tag_insert(sig, op, "", sig, op, @author_peer, {1, 1}, {:path, [{1, 1}]})

      assert t_del != t_ack
      assert t_del != t_ins
      assert t_ack != t_ins
    end

    test "an observed insert tag cannot be replayed as a delete authorization" do
      {authored_line, insert_tag, _infimum, _supremum} = author_side("payload")
      refute Byzantine.check_tag_delete(insert_tag, authored_line, {@author_peer, 2})
    end
  end

  describe "insert wire tag (t_ins) and local sealing of σ" do
    test "the genuine tag verifies against the authored parents and only them" do
      {authored_line, insert_tag, infimum, supremum} = author_side("hello world")

      provisional =
        create_line_from_wire(get_line_id(authored_line), "hello world", @author_peer, 3)

      assert Byzantine.check_tag_insert(infimum, provisional, supremum, @author_op, insert_tag)

      # A different candidate pair — e.g. one guessed by an observer who never learns
      # stored signatures — does not verify.
      other_line = create_line_between_two_lines("other", infimum, supremum, 2, {2, 1})
      refute Byzantine.check_tag_insert(other_line, provisional, supremum, @author_op, insert_tag)
      refute Byzantine.check_tag_insert(infimum, provisional, other_line, @author_op, insert_tag)
    end

    test "a tag verifying under the wrong op_id or position is rejected" do
      {authored_line, insert_tag, infimum, supremum} = author_side("bind me")

      provisional =
        create_line_from_wire(get_line_id(authored_line), "bind me", @author_peer, 3)

      # Right parents and content, but a different claimed op_id: the tag binds the op_id,
      # so it no longer verifies.
      refute Byzantine.check_tag_insert(
               infimum,
               provisional,
               supremum,
               {@author_peer, 2},
               insert_tag
             )

      # Right parents and op_id, but the line arrives at a different position: the tag binds
      # the position too.
      shifted = create_line_from_wire({:path, [{9, @author_peer}]}, "bind me", @author_peer, 3)
      refute Byzantine.check_tag_insert(infimum, shifted, supremum, @author_op, insert_tag)
    end

    test "missing parents never verify" do
      {authored_line, insert_tag, infimum, supremum} = author_side("x")
      provisional = create_line_from_wire(get_line_id(authored_line), "x", @author_peer, 3)

      refute Byzantine.check_tag_insert(nil, provisional, supremum, @author_op, insert_tag)
      refute Byzantine.check_tag_insert(infimum, provisional, nil, @author_op, insert_tag)
    end

    test "a tag forged without knowledge of the stored signatures does not verify" do
      {authored_line, _genuine, infimum, supremum} = author_side("target")
      # The forgery is in the guessed parent signatures, not the claimed author: the id
      # must be a valid index into the per-peer response checklist (peer_id < network_size).
      provisional =
        create_line_from_wire(get_line_id(authored_line), "target", @author_peer, @network_size)

      forged =
        Byzantine.create_tag_insert(
          "guessed_left",
          {-1, 0},
          "target",
          "guessed_right",
          {-1, 1},
          @author_peer,
          @author_op,
          get_line_id(authored_line)
        )

      refute Byzantine.check_tag_insert(infimum, provisional, supremum, @author_op, forged)
    end

    test "a receiver locating the authored parents by identity seals the author's σ (convergence)" do
      content = "converging line"
      {authored_line, insert_tag, _inf, _sup} = author_side(content)

      # Receiver side: its own copies of the boundary lines carry the same sentinel
      # signatures, and the line arrives WITHOUT its stored signature. The author placed
      # the line between the infimum and supremum, so the receiver resolves those two
      # authored parents by identity (op_id) and re-derives σ from their signatures.
      receiver_infimum = create_infimum_line(2, @network_size)
      receiver_supremum = create_supremum_line(2, @network_size)

      provisional =
        create_line_from_wire(get_line_id(authored_line), content, @author_peer, @network_size)

      # The wire tag verifies against exactly the authored parent pair.
      assert Byzantine.check_tag_insert(
               receiver_infimum,
               provisional,
               receiver_supremum,
               @author_op,
               insert_tag
             )

      sigma_sealed =
        Byzantine.create_signature_doc(
          get_signature(receiver_infimum),
          get_line_op_id(receiver_infimum),
          content,
          get_signature(receiver_supremum),
          get_line_op_id(receiver_supremum),
          @author_peer,
          @author_op,
          get_line_id(authored_line)
        )

      # The receiver seals exactly the author's σ — without σ ever traveling.
      assert sigma_sealed == get_signature(authored_line)
    end

    test "direct path verifies an insert whose right neighbor is the second-to-last line" do
      # Regression for the splice-index/git-index confusion: the author inserts between
      # (infimum, a) in a document whose only live line is `a`, so at the receiver the
      # incoming line's right neighbor sits at index len-2.
      infimum = create_infimum_line(0, @network_size)
      supremum = create_supremum_line(0, @network_size)

      line_a =
        create_line_between_two_lines("existing line", infimum, supremum, @author_peer, {
          @author_peer,
          1
        })

      content = "inserted at top"
      op = {@author_peer, 2}

      authored_line =
        create_line_between_two_lines(content, infimum, line_a, @author_peer, op)

      insert_tag =
        Byzantine.create_tag_insert(
          get_signature(infimum),
          get_line_op_id(infimum),
          content,
          get_signature(line_a),
          get_line_op_id(line_a),
          @author_peer,
          op,
          get_line_id(authored_line)
        )

      receiver_document = [infimum, line_a, supremum]

      provisional =
        create_line_from_wire(get_line_id(authored_line), content, @author_peer, @network_size)

      line_index = get_document_new_index_by_incoming_line_id(provisional, receiver_document)
      [left_parent, right_parent] = get_splice_parents(receiver_document, line_index)

      assert Byzantine.check_tag_insert(left_parent, provisional, right_parent, op, insert_tag)

      sealed_sigma =
        Byzantine.create_signature_doc(
          get_signature(left_parent),
          get_line_op_id(left_parent),
          content,
          get_signature(right_parent),
          get_line_op_id(right_parent),
          @author_peer,
          op,
          get_line_id(authored_line)
        )

      assert sealed_sigma == get_signature(authored_line)
    end
  end

  describe "delete authorization tag (t_del)" do
    test "binds the target line's stored signature and identity" do
      {authored_line, _t_ins, infimum, _sup} = author_side("to delete")
      del_op = {@author_peer, 7}

      tag =
        Byzantine.create_tag_delete(
          get_signature(authored_line),
          get_line_op_id(authored_line),
          del_op
        )

      assert Byzantine.check_tag_delete(tag, authored_line, del_op)
      # The same tag authorizes no other line.
      refute Byzantine.check_tag_delete(tag, infimum, del_op)
    end

    test "a missing target never verifies" do
      refute Byzantine.check_tag_delete("ANY_TAG", nil, {1, 1})
    end

    test "lines differing in one character of content yield different delete tags" do
      {line_a, _, infimum, supremum} = author_side("content a")

      line_b =
        create_line_between_two_lines(
          "content b",
          infimum,
          supremum,
          @author_peer,
          {@author_peer, 2}
        )

      del_op = {@author_peer, 9}
      tag_a = Byzantine.create_tag_delete(get_signature(line_a), get_line_op_id(line_a), del_op)
      refute Byzantine.check_tag_delete(tag_a, line_b, del_op)
    end
  end

  describe "response tag (t_ack)" do
    test "binds the acknowledged line and the acknowledging peer" do
      {authored_line, _t_ins, infimum, _sup} = author_side("acked line")

      tag =
        Byzantine.create_tag_ack(get_signature(authored_line), get_line_op_id(authored_line), 2)

      assert Byzantine.check_tag_ack(tag, authored_line, 2)
      # A different acker, or a different line, does not verify.
      refute Byzantine.check_tag_ack(tag, authored_line, 3)
      refute Byzantine.check_tag_ack(tag, infimum, 2)
    end
  end

  describe "canonical encoding is injective" do
    test "a boundary shift across two string fields yields a different stored signature" do
      # ["ab", "c"] and ["a", "bc"] share the naive concatenation "abc"; the length-prefixed
      # canonical encoding keeps their field boundaries distinct, so the tags differ.
      op = {@author_peer, 1}
      pos = {:path, [{1, @author_peer}]}

      a = Byzantine.create_signature_doc("ab", op, "c", "R", op, @author_peer, op, pos)
      b = Byzantine.create_signature_doc("a", op, "bc", "R", op, @author_peer, op, pos)

      assert a != b
    end

    test "moving a byte between content and a parent signature yields a different tag" do
      op = {@author_peer, 1}
      pos = {:path, [{1, @author_peer}]}

      a = Byzantine.create_tag_insert("LX", op, "content", "R", op, @author_peer, op, pos)
      b = Byzantine.create_tag_insert("L", op, "Xcontent", "R", op, @author_peer, op, pos)

      assert a != b
    end
  end

  describe "admission authenticator (α)" do
    setup do
      # The full insert payload: line_id, content, author, wire tag, progress vector,
      # op_id, and the two authored parent op_ids. α binds every field, parents included.
      payload =
        {{:path, [{1, 1}]}, "content", 1, "SOME_TAG", [0, 1, 0], {1, 1}, {-1, 0}, {-1, 1}}

      alpha = Byzantine.create_admission(@boundary, :ins, payload)
      %{payload: payload, alpha: alpha}
    end

    test "a genuine authenticator verifies and is deterministic", %{
      payload: payload,
      alpha: alpha
    } do
      assert Byzantine.check_admission(alpha, @boundary, :ins, payload)
      assert alpha == Byzantine.create_admission(@boundary, :ins, payload)
    end

    test "an authenticator minted without the boundary secret does not verify", %{
      payload: payload
    } do
      forged = Byzantine.create_admission({"guess", "guess"}, :ins, payload)
      refute Byzantine.check_admission(forged, @boundary, :ins, payload)
    end

    test "tampering with any payload field invalidates the stale authenticator", %{
      payload: payload,
      alpha: alpha
    } do
      # This is exactly the Byzantine simulator's strongest move: mutate a field and
      # rebroadcast under the observed (now stale) authenticator.
      {line_id, content, peer_id, tag, vc, op_id, lpo, rpo} = payload

      mutations = [
        {line_id, "tampered", peer_id, tag, vc, op_id, lpo, rpo},
        {line_id, content, 9, tag, vc, op_id, lpo, rpo},
        {line_id, content, peer_id, "FORGED_TAG", vc, op_id, lpo, rpo},
        {line_id, content, peer_id, tag, [9, 9, 9], op_id, lpo, rpo},
        {line_id, content, peer_id, tag, vc, {1, 2}, lpo, rpo},
        # Tampering with either authored parent op_id also invalidates α.
        {line_id, content, peer_id, tag, vc, op_id, {9, 9}, rpo},
        {line_id, content, peer_id, tag, vc, op_id, lpo, {9, 9}}
      ]

      for mutated <- mutations do
        refute Byzantine.check_admission(alpha, @boundary, :ins, mutated),
               "mutation #{inspect(mutated)} must invalidate the authenticator"
      end
    end

    test "kind confusion is rejected (an :ins authenticator does not admit a :del)", %{
      payload: payload,
      alpha: alpha
    } do
      refute Byzantine.check_admission(alpha, @boundary, :del, payload)
      refute Byzantine.check_admission(alpha, @boundary, :ack, payload)
    end

    test "the authenticator has the base16 sha256 shape", %{alpha: alpha} do
      assert String.length(alpha) == 64
      assert alpha =~ ~r/\A[0-9A-F]+\z/
    end
  end
end
