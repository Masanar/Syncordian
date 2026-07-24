defmodule Syncordian.DocumentTest do
  @moduledoc """
  Unit tests for the document's total line order ⋖ (position with identity tiebreak,
  `Syncordian.Line.compare_lines/2`) and its insert semantics
  (`Syncordian.Document.add_line_to_document/2`): a redelivered line must be reported as
  `:duplicate` (clean drop at the caller), while distinct lines at an equal position must
  still be ordered deterministically by their authored identity.
  """
  use ExUnit.Case, async: true

  import Syncordian.Line_Object
  import Syncordian.Line
  import Syncordian.Document

  defp mk_line(path, peer, op_id) do
    line(
      line_id: path,
      content: "content #{inspect(op_id)}",
      signature: "sig #{inspect(op_id)}",
      peer_id: peer,
      status: :aura,
      commit_at: [],
      op_id: op_id,
      parent_left_op_id: nil,
      parent_right_op_id: nil
    )
  end

  defp base_document do
    [create_infimum_line(0, 3), create_supremum_line(0, 3)]
  end

  describe "compare_lines/2 (the ⋖ total order)" do
    test "orders by position first" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      b = mk_line({:path, [{20, 2}]}, 2, {2, 1})
      assert compare_lines(a, b) == -1
      assert compare_lines(b, a) == 1
    end

    test "breaks equal positions by authored identity (writer, seq)" do
      same_path = {:path, [{10, 3}]}
      a = mk_line(same_path, 1, {1, 5})
      b = mk_line(same_path, 2, {2, 1})
      c = mk_line(same_path, 1, {1, 7})

      # writer 1 < writer 2
      assert compare_lines(a, b) == -1
      assert compare_lines(b, a) == 1
      # same writer: seq 5 < seq 7
      assert compare_lines(a, c) == -1
    end

    test "returns 0 only for the same authored identity" do
      same_path = {:path, [{10, 3}]}
      a = mk_line(same_path, 1, {1, 5})
      assert compare_lines(a, a) == 0
    end
  end

  describe "add_line_to_document/2" do
    test "inserts at the position-ordered spot" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      b = mk_line({:path, [{20, 2}]}, 2, {2, 1})

      {:ok, document} = add_line_to_document(b, base_document())
      {:ok, document} = add_line_to_document(a, document)

      contents = document |> Enum.map(&get_line_id/1)
      assert contents == [:infimum, {:path, [{10, 1}]}, {:path, [{20, 2}]}, :supremum]
    end

    test "reports a redelivered line as :duplicate" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      {:ok, document} = add_line_to_document(a, base_document())
      assert add_line_to_document(a, document) == :duplicate
    end

    test "distinct lines at an equal position both insert, identity-ordered" do
      same_path = {:path, [{10, 3}]}
      a = mk_line(same_path, 1, {1, 5})
      b = mk_line(same_path, 2, {2, 1})

      {:ok, document} = add_line_to_document(b, base_document())
      {:ok, document} = add_line_to_document(a, document)

      # The boundary sentinels carry the reserved authored identities {-1, 0} / {-1, 1}.
      assert Enum.map(document, &get_line_op_id/1) == [{-1, 0}, {1, 5}, {2, 1}, {-1, 1}]
    end
  end

  describe "get_document_index_by_line_id/2" do
    test "returns the index of a present line and nil for an absent id" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      {:ok, document} = add_line_to_document(a, base_document())

      assert get_document_index_by_line_id(document, {:path, [{10, 1}]}) == 1
      assert get_document_index_by_line_id(document, {:path, [{99, 9}]}) == nil
    end
  end

  describe "get_splice_parents/2" do
    # The splice index of an incoming line is the index of its right neighbor
    # (get_document_new_index_by_incoming_line_id/2), so the parents are always the
    # adjacent pair {doc[i-1], doc[i]} — for EVERY valid splice position, including the
    # second-to-last one that get_parents_by_index/2 (git-index semantics) maps to the
    # append pair instead.
    test "returns the adjacent pair around every splice position" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      b = mk_line({:path, [{20, 2}]}, 2, {2, 1})
      {:ok, document} = add_line_to_document(a, base_document())
      {:ok, document} = add_line_to_document(b, document)

      # document: [infimum, a, b, supremum]
      for i <- 1..3 do
        assert get_splice_parents(document, i) ==
                 [Enum.at(document, i - 1), Enum.at(document, i)]
      end
    end

    test "splice before the last real line yields that line as right parent (len-2 geometry)" do
      a = mk_line({:path, [{10, 1}]}, 1, {1, 1})
      {:ok, document} = add_line_to_document(a, base_document())

      # Incoming line between infimum and a: right neighbor a sits at index len-2.
      incoming = mk_line({:path, [{5, 2}]}, 2, {2, 1})
      splice = get_document_new_index_by_incoming_line_id(incoming, document)
      assert splice == 1

      [left, right] = get_splice_parents(document, splice)
      assert get_line_id(left) == :infimum
      assert get_line_id(right) == {:path, [{10, 1}]}
    end
  end
end
