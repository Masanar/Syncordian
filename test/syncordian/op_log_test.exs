defmodule Syncordian.OpLogTest do
  @moduledoc """
  Pins the origin log `Syncordian.OpLog`: a peer's record of the broadcasts it authored,
  used to retransmit any of them verbatim when a replica reports it missing (the
  anti-entropy fetch path, reviewer R5). Stores by op_id, serves by identity and by insert
  progress rank, and re-sends the exact stored message.
  """
  use ExUnit.Case, async: true

  alias Syncordian.OpLog

  doctest Syncordian.OpLog

  defp insert_msg(op_id, tag), do: {:receive_insert_broadcast, {:payload, op_id}, tag}
  defp delete_msg(op_id, tag), do: {:receive_delete_broadcast, {:payload, op_id}, tag}

  describe "store and identity lookup" do
    test "get/2 returns the exact stored message, unchanged" do
      msg = insert_msg({1, 1}, "ALPHA")
      log = OpLog.new() |> OpLog.put(:ins, {1, 1}, msg)

      assert OpLog.get(log, {1, 1}) == msg
    end

    test "an absent op_id returns nil" do
      assert OpLog.get(OpLog.new(), {1, 9}) == nil
    end

    test "both inserts and deletes are retrievable by identity" do
      log =
        OpLog.new()
        |> OpLog.put(:ins, {1, 1}, insert_msg({1, 1}, "I"))
        |> OpLog.put(:del, {1, 2}, delete_msg({1, 2}, "D"))

      assert OpLog.get(log, {1, 1}) == insert_msg({1, 1}, "I")
      assert OpLog.get(log, {1, 2}) == delete_msg({1, 2}, "D")
      assert OpLog.size(log) == 2
    end
  end

  describe "range serving by insert progress rank" do
    test "inserts are indexed by authoring order, so a rank range returns them in order" do
      log =
        OpLog.new()
        |> OpLog.put(:ins, {1, 1}, insert_msg({1, 1}, "first"))
        # A delete between the two inserts consumes an op-id but no progress rank.
        |> OpLog.put(:del, {1, 2}, delete_msg({1, 2}, "del"))
        |> OpLog.put(:ins, {1, 3}, insert_msg({1, 3}, "second"))

      assert OpLog.range_inserts(log, 1, 2) == [
               insert_msg({1, 1}, "first"),
               insert_msg({1, 3}, "second")
             ]
    end

    test "a range extending past the authored inserts returns only what exists" do
      log = OpLog.new() |> OpLog.put(:ins, {1, 1}, insert_msg({1, 1}, "only"))

      assert OpLog.range_inserts(log, 1, 5) == [insert_msg({1, 1}, "only")]
    end

    test "a range below the first authored insert is empty" do
      log = OpLog.new() |> OpLog.put(:ins, {1, 1}, insert_msg({1, 1}, "only"))

      assert OpLog.range_inserts(log, 5, 9) == []
    end

    test "deletes never occupy a progress rank" do
      log =
        OpLog.new()
        |> OpLog.put(:del, {1, 1}, delete_msg({1, 1}, "d1"))
        |> OpLog.put(:del, {1, 2}, delete_msg({1, 2}, "d2"))

      assert OpLog.range_inserts(log, 1, 9) == []
    end
  end

  test "byte_size grows as operations are recorded" do
    empty = OpLog.byte_size(OpLog.new())
    one = OpLog.new() |> OpLog.put(:ins, {1, 1}, insert_msg({1, 1}, "x")) |> OpLog.byte_size()

    assert one > empty
  end
end
