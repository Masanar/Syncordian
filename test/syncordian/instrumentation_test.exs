defmodule Syncordian.InstrumentationTest do
  @moduledoc """
  Pins the evaluation instrumentation: the process-local cost accumulators
  (`Syncordian.Instrument`), how the per-peer record combines across a network
  (`Syncordian.Metadata`), the operation-timing table (`Syncordian.OpTimes`), and the two
  pure quantities the interleaving measurement rests on (`Syncordian.Interleaving.conflicts/1`
  and `Syncordian.PathId.depth/1`).

  An instrumentation defect is worse than a missing metric, because a wrong number is
  reported with the same confidence as a right one. The cases below are therefore about the
  ways a measurement can be silently wrong: a field added to the record but dropped from the
  merge or the artifact, a high-water mark summed as though it were a total, a sample list
  averaged into nothing, a mean taken over the wrong denominator, and a conflict identity
  that changes while the conflict stands.
  """
  use ExUnit.Case, async: false

  require Syncordian.Metadata

  import Syncordian.Line_Object

  alias Syncordian.Byzantine
  alias Syncordian.Instrument
  alias Syncordian.Interleaving
  alias Syncordian.Metadata
  alias Syncordian.OpTimes
  alias Syncordian.PathId

  setup do
    Instrument.reset()
    :ok
  end

  describe "wire accounting" do
    test "classifies each broadcast by the operation it carries" do
      assert Instrument.wire_kind({:receive_insert_broadcast, {}, "a"}) == :insert
      assert Instrument.wire_kind({:receive_delete_broadcast, {}, "a"}) == :delete
      assert Instrument.wire_kind({:receive_confirmation_line_insertion, {}, "a"}) == :ack
      assert Instrument.wire_kind({:fetch_request, 1, [], "a"}) == :fetch
      assert Instrument.wire_kind({:some_internal_tick}) == :other
    end

    test "accumulates messages and bytes per kind" do
      Instrument.record_message(:insert, 100)
      Instrument.record_message(:insert, 50)
      Instrument.record_message(:ack, 10, 3)

      assert %{wire: %{insert: {2, 150}, ack: {3, 10}}} = Instrument.snapshot()
    end

    test "a broadcast counts one message per recipient" do
      # The load a deployment carries is one delivery per peer, not one call per broadcast.
      # Counting calls is what would hide the quadratic growth of acknowledgement traffic.
      recipients = [self(), self(), self()]
      message = {:receive_confirmation_line_insertion, {:payload}, "alpha"}
      Syncordian.Utilities.broadcast_to(recipients, message, 0..0)

      assert %{wire: %{ack: {3, bytes}}} = Instrument.snapshot()
      assert bytes == :erlang.external_size(message) * 3
    end

    test "a snapshot does not consume what it reports" do
      # The counters are cumulative over a peer's life and the metadata record they feed is
      # cumulative over the same life, so folding one in is an assignment. Clearing them
      # here would make a discarded snapshot lose work, and would restart the authenticator
      # sampling phase at every snapshot.
      Instrument.record_message(:insert, 100)
      assert %{wire: %{insert: {1, 100}}} = Instrument.snapshot()
      assert %{wire: %{insert: {1, 100}}} = Instrument.snapshot()
      Instrument.record_message(:insert, 50)
      assert %{wire: %{insert: {2, 150}}} = Instrument.snapshot()
    end

    test "accumulators are private to a process" do
      Instrument.record_message(:insert, 100)
      task = Task.async(fn -> Instrument.snapshot() end)
      assert %{wire: wire} = Task.await(task)
      assert wire == %{}
      assert %{wire: %{insert: {1, 100}}} = Instrument.snapshot()
    end

    test "the sampling phase survives a snapshot" do
      # Regression: clearing the counters at each snapshot restarted the one-in-64 phase, so
      # a domain seeing fewer than 64 calls between two snapshots was never timed and the
      # support of the reported mean depended on the harness's snapshot cadence.
      for _ <- 1..40 do
        Instrument.record_mac(:ins)
        Instrument.snapshot()
      end

      sampled = for _ <- 1..24, do: Instrument.record_mac(:ins)

      assert Enum.count(sampled, & &1) == 1, "the 64th call is sampled, snapshots notwithstanding"
      assert %{mac: %{ins: 64}} = Instrument.snapshot()
    end
  end

  describe "authenticator accounting" do
    test "counts every call and asks to time one in sixty-four" do
      sampled = for _ <- 1..64, do: Instrument.record_mac(:ins)

      assert Enum.count(sampled, & &1) == 1, "exactly one call of the first 64 is sampled"
      assert %{mac: %{ins: 64}} = Instrument.snapshot()
    end

    test "domains are counted independently" do
      Instrument.record_mac(:doc)
      Instrument.record_mac(:adm)
      Instrument.record_mac(:adm)

      assert %{mac: %{doc: 1, adm: 2}} = Instrument.snapshot()
    end

    test "the real authenticator path records its calls and samples its timing" do
      # Through the public API rather than the private hash, so the accounting is pinned
      # where it actually happens.
      for _ <- 1..64, do: Byzantine.create_tag_ack("SIGNATURE", {0, 1}, 2)

      assert %{mac: %{ack: 64}, mac_time: {samples, nanoseconds, values}} = Instrument.snapshot()
      assert samples == 1
      assert nanoseconds > 0, "a sampled call has a positive elapsed time"
      assert values == [nanoseconds], "the sample itself is kept, not only its sum"
    end
  end

  describe "combining per-peer records into a network view" do
    test "every field of the record reaches the artifact" do
      # The guard against a counter being added to the record and dropped from the saved
      # map, which reads as a real zero rather than as a missing measurement.
      map = Metadata.to_map(Metadata.metadata())
      assert map_size(map) > 40
      assert Map.has_key?(map, "conflicts_observed")
      assert Map.has_key?(map, "bytes_ack")
      assert Map.has_key?(map, "mac_calls_adm")
      assert Map.has_key?(map, "pid_depth_sum")
    end

    test "totals are summed" do
      a = Metadata.metadata(insert_valid_counter: 3, bytes_ack: 100)
      b = Metadata.metadata(insert_valid_counter: 4, bytes_ack: 20)
      merged = Metadata.merge_metadata(a, b)

      assert Metadata.metadata(merged, :insert_valid_counter) == 7
      assert Metadata.metadata(merged, :bytes_ack) == 120
    end

    test "high-water marks take the maximum, not the total" do
      # A peak is something one replica saw at one moment. Summing peaks reports a network
      # state that never existed.
      a = Metadata.metadata(max_concurrent_conflicts: 3, pid_depth_max: 5, live_duplicates_max: 0)
      b = Metadata.metadata(max_concurrent_conflicts: 7, pid_depth_max: 2, live_duplicates_max: 0)
      merged = Metadata.merge_metadata(a, b)

      assert Metadata.metadata(merged, :max_concurrent_conflicts) == 7
      assert Metadata.metadata(merged, :pid_depth_max) == 5
      assert Metadata.metadata(merged, :live_duplicates_max) == 0
    end

    test "samples are concatenated, not summed" do
      a = Metadata.metadata(repair_latency_ms: [10, 20], reissued_lines_per_conflict: [4])
      b = Metadata.metadata(repair_latency_ms: [30], reissued_lines_per_conflict: [2])
      merged = Metadata.merge_metadata(a, b)

      assert Enum.sort(Metadata.metadata(merged, :repair_latency_ms)) == [10, 20, 30]
      assert Enum.sort(Metadata.metadata(merged, :reissued_lines_per_conflict)) == [2, 4]
    end

    test "the mean position depth is over lines, not over peers" do
      # A big replica and a small one do not contribute equally. Keeping the sum and the line
      # count apart is what makes the network mean the mean over its lines; averaging the two
      # per-peer means would weight them the same.
      big = Metadata.metadata(pid_depth_sum: 300, pid_depth_lines: 100)
      small = Metadata.metadata(pid_depth_sum: 8, pid_depth_lines: 2)
      merged = Metadata.merge_metadata(big, small)

      assert Metadata.metadata(merged, :pid_depth_sum) == 308
      assert Metadata.metadata(merged, :pid_depth_lines) == 102
    end

    test "the conflict gauge reports the busiest replica" do
      metadata =
        Metadata.metadata()
        |> Metadata.observe_conflicts(2, 2)
        |> Metadata.observe_conflicts(1, 3)
        |> Metadata.observe_conflicts(0, 1)

      assert Metadata.metadata(metadata, :conflicts_observed) == 3
      assert Metadata.metadata(metadata, :concurrent_conflicts) == 1
      assert Metadata.metadata(metadata, :max_concurrent_conflicts) == 3
    end

    test "the process accumulators fold into the record" do
      Instrument.record_message(:insert, 500, 2)
      Instrument.record_mac(:ins)

      metadata = Metadata.absorb_instruments(Metadata.metadata())

      assert Metadata.metadata(metadata, :bytes_insert) == 500
      assert Metadata.metadata(metadata, :msgs_insert) == 2
      assert Metadata.metadata(metadata, :mac_calls_ins) == 1
    end

    test "folding the accumulators twice counts them once" do
      Instrument.record_message(:insert, 500, 2)

      metadata =
        Metadata.metadata()
        |> Metadata.absorb_instruments()
        |> Metadata.absorb_instruments()

      assert Metadata.metadata(metadata, :bytes_insert) == 500
      assert Metadata.metadata(metadata, :msgs_insert) == 2
    end

    test "a quantity never observed is reported as absent, not as zero" do
      # A zero bytes-per-insert would read as a measured result. There was no measurement.
      json = Metadata.metadata() |> saved_json()

      assert json["pid_depth_mean"] == nil
      assert json["mac_mean_us"] == nil
      assert json["mac_median_us"] == nil
      assert json["bytes_per_insert"] == nil
      assert json["bytes_total"] == 0
    end

    test "the reported authenticator cost is a median, robust to scheduling outliers" do
      # A wall-clock delta around one call includes any time the process spent descheduled,
      # so a single outlier moves the mean by a factor. The median does not, which is why the
      # samples are kept and both are reported.
      json = Metadata.metadata(mac_sample_ns: [1_000, 1_100, 1_200, 90_000]) |> saved_json()

      assert json["mac_median_us"] == 1.15
    end

    test "derived quantities use the denominator they belong to" do
      json =
        Metadata.metadata(
          pid_depth_sum: 300,
          pid_depth_lines: 100,
          mac_sampled_ns: 4_000,
          mac_sampled_calls: 2,
          bytes_insert: 900,
          msgs_insert: 3,
          bytes_ack: 100
        )
        |> saved_json()

      assert json["pid_depth_mean"] == 3.0
      # The mean authenticator time is over the sampled calls, in microseconds.
      assert json["mac_mean_us"] == 2.0
      assert json["bytes_per_insert"] == 300.0
      assert json["bytes_total"] == 1_000
    end
  end

  describe "conflict identity" do
    test "a conflict keeps its identity when a block loses a line" do
      # The identity has to survive the two events a repair works across, otherwise a
      # conflict that merely changed shape reads as one repair plus one fresh anomaly, and
      # every repair-duration sample is wrong.
      document = interleaved_document()
      [conflict] = Interleaving.conflicts(document)

      shortened = tombstone_content(document, "b-2")

      assert Interleaving.conflicts(shortened) == [conflict],
             "the same interleaving, still named the same way"
    end

    test "a conflict is named once, ordered by writer" do
      assert [{{0, _}, {1, _}}] = Interleaving.conflicts(interleaved_document())
    end

    test "a document with no interleaving reports none" do
      assert Interleaving.conflicts(separated_document()) == []
    end

    test "the conflicts and the repairs come from one analysis" do
      document = interleaved_document()
      analysis = Interleaving.analyze(document)

      assert analysis.conflicts == Interleaving.conflicts(document)
      assert analysis.replacements == Interleaving.detect_replacements(document)
    end
  end

  describe "position depth" do
    test "the boundary sentinels carry no depth" do
      assert PathId.depth(PathId.infimum()) == 0
      assert PathId.depth(PathId.supremum()) == 0
    end

    test "depth counts the segments an identifier was allocated" do
      shallow = PathId.between(PathId.infimum(), PathId.supremum(), 0)
      assert PathId.depth(shallow) == 1
      assert PathId.depth(PathId.between(shallow, PathId.supremum(), 0)) >= 1
    end
  end

  describe "operation timing" do
    setup do
      OpTimes.create()
      on_exit(fn -> if OpTimes.active?(), do: :ets.delete(:syncordian_op_times) end)
      :ok
    end

    test "pairs an application with the issue it followed" do
      OpTimes.record_issue({0, 1})
      OpTimes.record_apply({0, 1}, 1)
      OpTimes.record_apply({0, 1}, 2)
      OpTimes.record_settle({0, 1})

      samples = OpTimes.samples()

      assert samples.operations == 1
      assert samples.applies == 2, "one sample per replica that applied it"
      assert samples.settles == 1
      assert Enum.all?(samples.apply_latency_us, &(&1 >= 0))
    end

    test "an application with no recorded issue contributes no sample" do
      # Rather than a zero, which would pull a reported percentile toward nothing.
      OpTimes.record_apply({9, 9}, 1)

      samples = OpTimes.samples()
      assert samples.operations == 0
      assert samples.applies == 0
    end

    test "the first stamp of an event is the one kept" do
      OpTimes.record_issue({0, 1})
      OpTimes.record_apply({0, 1}, 1)
      [first] = OpTimes.samples().apply_latency_us
      OpTimes.record_apply({0, 1}, 1)

      assert OpTimes.samples().apply_latency_us == [first],
             "a re-delivery must not shorten the recorded latency"
    end

    test "recording is a no-op when no run is being timed" do
      :ets.delete(:syncordian_op_times)

      refute OpTimes.active?()
      assert OpTimes.record_issue({0, 1}) == :ok
      assert OpTimes.record_apply({0, 1}, 1) == :ok
      assert OpTimes.dump("unused") == :inactive
      assert OpTimes.samples().operations == 0
    end
  end

  # --- fixtures ---------------------------------------------------------------------------

  @network_size 3

  defp saved_json(metadata) do
    # Round-trips through the encoder the harness writes with, so the assertions are about
    # the artifact rather than about an intermediate map.
    directory = "debug/metadata/individual_peer/instrumentation_test/"
    File.mkdir_p!(directory)
    Metadata.save_metadata_one_peer(metadata, 0, "instrumentation_test", "unit")
    path = Path.join(directory, "unit_0.json")
    json = path |> File.read!() |> Jason.decode!()
    File.rm(path)
    json
  end

  # Two writers' blocks allocated into the same empty interval, with overlapping positions:
  # the interleaving the detector exists to find.
  defp separated_document do
    infimum = create_infimum_line(0, @network_size)
    supremum = create_supremum_line(0, @network_size)
    [infimum, supremum]
  end

  defp interleaved_document do
    infimum = create_infimum_line(0, @network_size)
    supremum = create_supremum_line(0, @network_size)
    session = {get_line_op_id(infimum), get_line_op_id(supremum)}

    # Positions interleave a-1 < b-1 < a-2 < b-2, both blocks anchored between the sentinels.
    lines =
      [
        {"a-1", 0, {0, 1}, {:path, [{2, 0}]}},
        {"b-1", 1, {1, 1}, {:path, [{3, 1}]}},
        {"a-2", 0, {0, 2}, {:path, [{4, 0}]}},
        {"b-2", 1, {1, 2}, {:path, [{5, 1}]}}
      ]
      |> Enum.map(fn {content, writer, op_id, position} ->
        create_line_from_wire(position, content, writer, @network_size)
        |> seal_line_authored("SIG-#{content}", op_id, nil, nil, session)
      end)

    [infimum] ++ lines ++ [supremum]
  end

  defp tombstone_content(document, content) do
    Enum.map(document, fn line ->
      if get_content(line) == content, do: set_line_status(line, :tombstone), else: line
    end)
  end
end
