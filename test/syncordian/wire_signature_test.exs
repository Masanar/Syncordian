defmodule Syncordian.WireSignatureTest do
  @moduledoc """
  Pins the dual domain-separated signature scheme and the admission authenticator of
  `Syncordian.Byzantine`, mirroring the paper's formal model:

    * stored signature σ under `:doc` — never transmitted, sealed locally by every
      replica from the parent pair that verifies the insert wire tag;
    * wire tags under `:ins` / `:del` / `:ack` — what actually travels;
    * admission authenticator α under `:adm` — keyed by the boundary secret, bound to
      the full message payload, checked before anything else at receipt.

  The central convergence invariant is pinned end-to-end at unit level: the direct
  receive path and the windowed (stash) path accept the same parent pair and seal the
  *same* stored signature the author computed, without σ ever riding a message.
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  import Syncordian.Line
  import Syncordian.Document
  alias Syncordian.Byzantine

  @network_size 3
  @author_peer 1
  @boundary {"Infimum", "Supremum"}

  defp author_side(content) do
    infimum = create_infimum_line(0, @network_size)
    supremum = create_supremum_line(0, @network_size)

    authored_line =
      create_line_between_two_lines(content, infimum, supremum, @author_peer, {@author_peer, 1})

    insert_tag =
      Byzantine.create_tag_insert(
        get_signature(infimum),
        content,
        get_signature(supremum),
        @author_peer
      )

    {authored_line, insert_tag, infimum, supremum}
  end

  describe "domain separation" do
    test "the insert wire tag never equals the stored signature on identical fields" do
      fields = {"LEFT_SIG", "content", "RIGHT_SIG", @author_peer}
      {l, c, r, w} = fields

      assert Byzantine.create_signature_doc(l, c, r, w) !=
               Byzantine.create_tag_insert(l, c, r, w)
    end

    test "tags of different kinds are pairwise distinct on overlapping inputs" do
      sig = "SOME_STORED_SIGNATURE"
      t_del = Byzantine.create_tag_delete(sig)
      t_ack = Byzantine.create_tag_ack(sig, @author_peer)
      t_ins = Byzantine.create_tag_insert(sig, "", sig, @author_peer)

      assert t_del != t_ack
      assert t_del != t_ins
      assert t_ack != t_ins
    end

    test "an observed insert tag cannot be replayed as a delete authorization" do
      {authored_line, insert_tag, _infimum, _supremum} = author_side("payload")
      refute Byzantine.check_tag_delete(insert_tag, authored_line)
    end
  end

  describe "insert wire tag (t_ins) and local sealing of σ" do
    test "the genuine tag verifies against the authored parents and only them" do
      {_authored_line, insert_tag, infimum, supremum} = author_side("hello world")

      provisional =
        create_line_from_wire({:path, [{1, @author_peer}]}, "hello world", @author_peer, 3)

      assert Byzantine.check_tag_insert(infimum, provisional, supremum, insert_tag)

      # A different candidate pair — e.g. one guessed by an observer who never learns
      # stored signatures — does not verify.
      other_line = create_line_between_two_lines("other", infimum, supremum, 2, {2, 1})
      refute Byzantine.check_tag_insert(other_line, provisional, supremum, insert_tag)
      refute Byzantine.check_tag_insert(infimum, provisional, other_line, insert_tag)
    end

    test "missing parents never verify" do
      {_authored_line, insert_tag, infimum, supremum} = author_side("x")
      provisional = create_line_from_wire({:path, [{1, @author_peer}]}, "x", @author_peer, 3)

      refute Byzantine.check_tag_insert(nil, provisional, supremum, insert_tag)
      refute Byzantine.check_tag_insert(infimum, provisional, nil, insert_tag)
    end

    test "a tag forged without knowledge of the stored signatures does not verify" do
      {_authored_line, _genuine, infimum, supremum} = author_side("target")
      # The forgery is in the guessed parent signatures, not the claimed author: the id
      # must be a valid index into the per-peer response checklist (peer_id < network_size).
      provisional = create_line_from_wire({:path, [{1, 2}]}, "target", 2, @network_size)

      forged =
        Byzantine.create_tag_insert("guessed_left", "target", "guessed_right", 2)

      refute Byzantine.check_tag_insert(infimum, provisional, supremum, forged)
    end

    test "direct path and windowed path seal the identical stored signature (convergence)" do
      content = "converging line"
      {authored_line, insert_tag, _inf, _sup} = author_side(content)

      # Receiver side: its own copies of the boundary lines carry the same sentinel
      # signatures, and the line arrives WITHOUT its stored signature.
      receiver_document = [
        create_infimum_line(2, @network_size),
        create_supremum_line(2, @network_size)
      ]

      provisional =
        create_line_from_wire(get_line_id(authored_line), content, @author_peer, @network_size)

      # Direct path: locate parents by position, verify the tag, seal σ from the pair.
      line_index = get_document_new_index_by_incoming_line_id(provisional, receiver_document)
      [left_parent, right_parent] = get_splice_parents(receiver_document, line_index)
      assert Byzantine.check_tag_insert(left_parent, provisional, right_parent, insert_tag)

      sigma_direct =
        Byzantine.create_signature_doc(
          get_signature(left_parent),
          content,
          get_signature(right_parent),
          @author_peer
        )

      # Windowed (stash) path: the search returns the accepted parent pair; seal from it.
      {found?, {stash_left, stash_right}} =
        stash_document_lines_insert(
          receiver_document,
          provisional,
          [1, 0, 1],
          [0, 1, 0],
          insert_tag
        )

      assert found?

      sigma_stash =
        Byzantine.create_signature_doc(
          get_signature(stash_left),
          content,
          get_signature(stash_right),
          @author_peer
        )

      # Both receiver routes and the author agree on σ — without σ ever traveling.
      assert sigma_direct == sigma_stash
      assert sigma_direct == get_signature(authored_line)
    end

    test "direct path verifies an insert whose right neighbor is the second-to-last line" do
      # Regression for the splice-index/git-index confusion: the author inserts between
      # (infimum, a) in a document whose only live line is `a`, so at the receiver the
      # incoming line's right neighbor sits at index len-2. Feeding the splice index into
      # get_parents_by_index/2 (git semantics, `distance == 2` append case) mislocated the
      # pair as (a, supremum), failed the tag check, and permanently dropped the honest
      # insert once the receiver held the sender's full causal context — divergence.
      infimum = create_infimum_line(0, @network_size)
      supremum = create_supremum_line(0, @network_size)

      line_a =
        create_line_between_two_lines("existing line", infimum, supremum, @author_peer, {
          @author_peer,
          1
        })

      content = "inserted at top"

      authored_line =
        create_line_between_two_lines(content, infimum, line_a, @author_peer, {@author_peer, 2})

      insert_tag =
        Byzantine.create_tag_insert(
          get_signature(infimum),
          content,
          get_signature(line_a),
          @author_peer
        )

      receiver_document = [infimum, line_a, supremum]

      provisional =
        create_line_from_wire(get_line_id(authored_line), content, @author_peer, @network_size)

      line_index = get_document_new_index_by_incoming_line_id(provisional, receiver_document)
      [left_parent, right_parent] = get_splice_parents(receiver_document, line_index)

      assert Byzantine.check_tag_insert(left_parent, provisional, right_parent, insert_tag)

      sealed_sigma =
        Byzantine.create_signature_doc(
          get_signature(left_parent),
          content,
          get_signature(right_parent),
          @author_peer
        )

      assert sealed_sigma == get_signature(authored_line)
    end
  end

  describe "delete authorization tag (t_del)" do
    test "binds the target line's stored signature" do
      {authored_line, _t_ins, infimum, _sup} = author_side("to delete")
      tag = Byzantine.create_tag_delete(get_signature(authored_line))

      assert Byzantine.check_tag_delete(tag, authored_line)
      # The same tag authorizes no other line.
      refute Byzantine.check_tag_delete(tag, infimum)
    end

    test "a missing target never verifies" do
      refute Byzantine.check_tag_delete("ANY_TAG", nil)
    end

    test "lines differing in one character of content yield different delete tags" do
      {line_a, _, infimum, supremum} = author_side("content a")

      line_b =
        create_line_between_two_lines(
          "content b",
          infimum,
          supremum,
          @author_peer,
          {@author_peer, 1}
        )

      tag_a = Byzantine.create_tag_delete(get_signature(line_a))
      refute Byzantine.check_tag_delete(tag_a, line_b)
    end
  end

  describe "admission authenticator (α)" do
    setup do
      payload = {{:path, [{1, 1}]}, "content", 1, "SOME_TAG", [0, 1, 0], {1, 1}}
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
      {line_id, content, peer_id, tag, vc, op_id} = payload

      mutations = [
        {line_id, "tampered", peer_id, tag, vc, op_id},
        {line_id, content, 9, tag, vc, op_id},
        {line_id, content, peer_id, "FORGED_TAG", vc, op_id},
        {line_id, content, peer_id, tag, [9, 9, 9], op_id},
        {line_id, content, peer_id, tag, vc, {1, 2}}
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
