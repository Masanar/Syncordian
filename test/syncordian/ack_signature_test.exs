defmodule Syncordian.AckSignatureTest do
  @moduledoc """
  Pins the insertion-response (acknowledgement) tag: `create_tag_ack/2` /
  `check_tag_ack/3` bind the acknowledged line's stored signature and the acknowledging
  peer id under the `:ack` domain. The boundary secret does not enter this tag — it
  enters the response's admission authenticator, covered in
  `Syncordian.WireSignatureTest` — and responses deliberately carry no op_id: their
  effect is idempotent, so replay protection for them is structural (also pinned below).
  """
  use ExUnit.Case, async: true

  alias Syncordian.Byzantine

  @line_signature "ABCD1234"
  @peer_id 5

  describe "create_tag_ack/2 and check_tag_ack/3" do
    test "a genuine tag verifies" do
      tag = Byzantine.create_tag_ack(@line_signature, @peer_id)
      assert Byzantine.check_tag_ack(tag, @line_signature, @peer_id)
    end

    test "the tag is deterministic for the same inputs" do
      a = Byzantine.create_tag_ack(@line_signature, @peer_id)
      b = Byzantine.create_tag_ack(@line_signature, @peer_id)
      assert a == b
    end

    test "the tag is bound to the acknowledging peer id (no impersonation)" do
      tag = Byzantine.create_tag_ack(@line_signature, @peer_id)
      # A captured response cannot be replayed under a different peer's identity.
      refute Byzantine.check_tag_ack(tag, @line_signature, 9)
    end

    test "the tag is bound to the acknowledged line's stored signature" do
      tag = Byzantine.create_tag_ack(@line_signature, @peer_id)
      refute Byzantine.check_tag_ack(tag, "DIFFERENT", @peer_id)
    end

    test "distinct lines and peers yield distinct tags" do
      base = Byzantine.create_tag_ack(@line_signature, @peer_id)
      other_line = Byzantine.create_tag_ack("OTHER", @peer_id)
      other_peer = Byzantine.create_tag_ack(@line_signature, 6)

      assert base != other_line
      assert base != other_peer
      assert other_line != other_peer
    end

    test "the tag is the base16 sha256 hash shape used elsewhere in Syncordian" do
      tag = Byzantine.create_tag_ack(@line_signature, @peer_id)
      assert String.length(tag) == 64
      assert tag =~ ~r/\A[0-9A-F]+\z/
    end
  end

  describe "response idempotency (structural replay protection)" do
    import Syncordian.Line_Object
    import Syncordian.Document

    test "recording the same acknowledgement twice equals recording it once" do
      network_size = 3
      line_id = {:path, [{1, 0}]}

      document = [
        create_infimum_line(0, network_size),
        create_line_from_wire(line_id, "content", 0, network_size),
        create_supremum_line(0, network_size)
      ]

      once = update_document_line_commit_at(document, line_id, 2)
      twice = update_document_line_commit_at(once, line_id, 2)

      # Acks carry no op_id by design: their effect is a set-to-true on one checklist
      # entry, so a replayed response leaves the state unchanged.
      assert once == twice
      assert get_commit_at(get_document_line_by_line_id(once, line_id)) == [true, false, true]
    end
  end
end
