defmodule Syncordian.AckSignatureTest do
  @moduledoc """
  Pins the insertion-response (acknowledgement) tag: `create_tag_ack/3` /
  `check_tag_ack/3` bind the acknowledged line's stored signature and op_id and the
  acknowledging peer id under the `:ack` key. The boundary secret does not key this tag
  directly — it keys the response's admission authenticator, covered in
  `Syncordian.WireSignatureTest` — and responses deliberately carry no op_id of their own:
  their effect is idempotent, so replay protection for them is structural (also pinned
  below).
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  alias Syncordian.Byzantine

  @line_signature "ABCD1234"
  @line_op {0, 1}
  @peer_id 5

  # A minimal acknowledged line carrying a known stored signature and op_id.
  defp acked_line(signature \\ @line_signature, op_id \\ @line_op) do
    create_line_from_wire({:path, [{1, 0}]}, "content", 0, 3)
    |> seal_line_authored(signature, op_id, nil, nil)
  end

  describe "create_tag_ack/3 and check_tag_ack/3" do
    test "a genuine tag verifies" do
      line = acked_line()
      tag = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), @peer_id)
      assert Byzantine.check_tag_ack(tag, line, @peer_id)
    end

    test "the tag is deterministic for the same inputs" do
      a = Byzantine.create_tag_ack(@line_signature, @line_op, @peer_id)
      b = Byzantine.create_tag_ack(@line_signature, @line_op, @peer_id)
      assert a == b
    end

    test "the tag is bound to the acknowledging peer id (no impersonation)" do
      line = acked_line()
      tag = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), @peer_id)
      # A captured response cannot be replayed under a different peer's identity.
      refute Byzantine.check_tag_ack(tag, line, 9)
    end

    test "the tag is bound to the acknowledged line's stored signature" do
      line = acked_line()
      tag = Byzantine.create_tag_ack(get_signature(line), get_line_op_id(line), @peer_id)
      refute Byzantine.check_tag_ack(tag, acked_line("DIFFERENT"), @peer_id)
    end

    test "distinct lines and peers yield distinct tags" do
      base = Byzantine.create_tag_ack(@line_signature, @line_op, @peer_id)
      other_line = Byzantine.create_tag_ack("OTHER", @line_op, @peer_id)
      other_peer = Byzantine.create_tag_ack(@line_signature, @line_op, 6)

      assert base != other_line
      assert base != other_peer
      assert other_line != other_peer
    end

    test "a missing acknowledged line never verifies" do
      tag = Byzantine.create_tag_ack(@line_signature, @line_op, @peer_id)
      refute Byzantine.check_tag_ack(tag, nil, @peer_id)
    end

    test "the tag is the base16 sha256 hash shape used elsewhere in Syncordian" do
      tag = Byzantine.create_tag_ack(@line_signature, @line_op, @peer_id)
      assert String.length(tag) == 64
      assert tag =~ ~r/\A[0-9A-F]+\z/
    end
  end

  describe "response idempotency (structural replay protection)" do
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
