defmodule Syncordian.Live.DifficultExecutionsTest do
  @moduledoc """
  The four executions the evaluation calls difficult (WS7, reviewer R8).

  The reviewer's objection is that the adversarial experiment modifies messages that cannot
  pass the admission check, so it validates the guard rather than resilience. These tests
  answer that objection directly, by putting the replicas under executions the guard has
  nothing to say about.

    * **Reorder storm.** Almost nothing arrives in the order it was sent. Every link
      duplicates and holds messages back, and the adversary injects.
    * **Offline window.** A replica is cut off in both directions and reconnected. What it
      missed has to be recovered by asking for it.
    * **Post-collection replay.** Genuine messages, captured and re-broadcast unchanged after
      the replica has stopped remembering them. These *pass* admission. What answers them is
      idempotence: the tombstone, and the fact that a position identifier names a place
      rather than describes one.
    * **Bounded loss.** Messages are suppressed on every link throughout, within a rate that
      leaves eventual delivery intact.

  They drive real peer processes, so they are tagged `:live` and run only under
  `mix test --include live`.
  """
  use ExUnit.Case, async: false
  @moduletag :live

  alias Syncordian.Byzantine
  alias Syncordian.ByzantinePeer
  alias Syncordian.Info
  alias Syncordian.Network
  alias Syncordian.Peer
  alias Syncordian.Run

  setup do
    # Recovery has to happen within a test rather than within a replay of a whole history.
    Application.put_env(:syncordian, :fetch_soft_threshold, 1)
    Application.put_env(:syncordian, :fetch_sweep_interval_ms, 20)

    on_exit(fn ->
      Application.delete_env(:syncordian, :fetch_soft_threshold)
      Application.delete_env(:syncordian, :fetch_sweep_interval_ms)
      Network.reconnect_all()
      Run.reset!()
      Byzantine.install_boundary_secret!({"Infimum", "Supremum"})
    end)

    :ok
  end

  # Installs a run, its network, and its boundary secret, in the order a real run does: the
  # description first, then the secret it implies, then the peers that bake the secret in.
  defp start_run(scenario, overrides) do
    Run.reset!()

    Run.install!(
      Keyword.merge(
        [seed: 1, scenario: scenario, delay: {:uniform, 1, 15}, root: "debug"],
        overrides
      )
    )

    Network.create()
    Byzantine.generate_boundary_secret() |> Byzantine.install_boundary_secret!()
    :ok
  end

  defp start_peers(count) do
    peers =
      for id <- 0..(count - 1) do
        pid = Peer.start(id, count)
        on_exit(fn -> Process.exit(pid, :kill) end)
        pid
      end

    Process.sleep(300)
    peers
  end

  defp start_adversary(id) do
    ByzantinePeer.start_byzantine_peer(id)
    pid = :global.whereis_name(id)
    on_exit(fn -> if is_pid(pid), do: Process.exit(pid, :kill) end)
    Process.sleep(100)
    pid
  end

  defp content(pid) do
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> Info.string_document_content(document)
    after
      2_000 -> flunk("peer did not return its document")
    end
  end

  defp document(pid) do
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> document
    after
      2_000 -> flunk("peer did not return its document")
    end
  end

  defp assert_converged(peers) do
    [reference | rest] = Enum.map(peers, &content/1)

    Enum.each(rest, fn other ->
      assert other == reference, "replicas did not converge"
    end)

    reference
  end

  defp lines(text), do: text |> String.split("\n", trim: true)

  ########################################################################################

  describe "reorder storm" do
    test "replicas converge when almost nothing arrives in order" do
      start_run(:reorder_storm, delay: {:uniform, 0, 120})
      [a, b] = start_peers(2)
      start_adversary(1_000_001)

      for index <- 0..3 do
        Peer.insert(a, "alpha-#{index}", index, index, 0, 0)
        Peer.insert(b, "beta-#{index}", index, index, 0, 0)
      end

      # Long enough for the held, duplicated, and injected traffic to drain.
      Process.sleep(6_000)

      converged = assert_converged([a, b])

      for index <- 0..3 do
        assert String.contains?(converged, "alpha-#{index}")
        assert String.contains?(converged, "beta-#{index}")
      end

      # Duplication is a property of the network, not of the document. Every line the writers
      # authored appears exactly once.
      assert length(lines(converged)) == length(Enum.uniq(lines(converged)))
    end
  end

  describe "offline window" do
    test "a replica cut off and reconnected recovers what it missed" do
      start_run(:offline_window, delay: {:uniform, 1, 10})
      [a, b] = start_peers(2)

      Peer.insert(a, "before-the-window", 0, 0, 0, 0)
      Process.sleep(300)
      assert String.contains?(content(b), "before-the-window")

      # The window: B receives nothing and sends nothing.
      Network.partition(1, true)

      Peer.insert(a, "during-the-window-1", 1, 1, 0, 0)
      Process.sleep(200)
      Peer.insert(a, "during-the-window-2", 2, 2, 0, 0)
      Process.sleep(400)

      refute String.contains?(content(b), "during-the-window-1"),
             "the partitioned replica received traffic"

      # The window closes. Nothing that was sent during it is re-broadcast, so the only way B
      # can hold the missed operations is by asking their origin for them.
      Network.partition(1, false)

      # A authors again. This message is what tells B that it fell behind: it carries A's
      # progress, which is ahead of what B has seen, so B suspends it on the gap and asks A
      # for what is missing. A replica that is cut off learns nothing while it is cut off,
      # and nothing afterwards either until someone speaks to it again.
      Peer.insert(a, "after-the-window", 3, 3, 0, 0)
      Process.sleep(300)

      # B authors too, so its edit count advances and the suspended operation ages past the
      # threshold that arms the sweep.
      Peer.insert(b, "b-after-the-window", 0, 0, 0, 0)
      Process.sleep(4_000)

      recovered = content(b)
      assert String.contains?(recovered, "during-the-window-1"), "the outage was never repaired"
      assert String.contains?(recovered, "during-the-window-2")
      assert_converged([a, b])
    end
  end

  describe "post-collection replay" do
    test "a genuine message replayed verbatim is admitted and changes nothing" do
      # This is the execution the reviewer asks for. The message is not forged: it carries a
      # valid authenticator written by an admitted peer, so the admission check accepts it.
      start_run(:post_collection_replay,
        delay: :none,
        adversary: %{replay_rate: 1.0, replay_hold_ms: 400, inject_rate: 0.0}
      )

      [a, b] = start_peers(2)
      start_adversary(1_000_001)

      Peer.insert(a, "replayed-line", 0, 0, 0, 0)
      Process.sleep(200)

      before_replay = content(b)
      assert String.contains?(before_replay, "replayed-line")

      # The adversary is holding a verbatim copy. Let it arrive.
      Process.sleep(1_500)

      assert content(b) == before_replay, "a replayed message changed the document"
      assert_converged([a, b])

      # And the line it names appears once, not once per copy of the message.
      assert Enum.count(lines(content(b)), &String.contains?(&1, "replayed-line")) == 1
    end

    test "a replayed insert does not resurrect the line a later delete removed" do
      start_run(:post_collection_replay,
        delay: :none,
        adversary: %{replay_rate: 1.0, replay_hold_ms: 1_200, inject_rate: 0.0}
      )

      [a, b] = start_peers(2)
      start_adversary(1_000_001)

      Peer.insert(a, "doomed-line", 0, 0, 0, 0)
      Process.sleep(300)
      assert String.contains?(content(b), "doomed-line")

      # The line is deleted while the adversary is still holding the insert that created it.
      Peer.delete_line(a, 0, 1, 0, 0)
      Process.sleep(300)
      refute String.contains?(content(b), "doomed-line")

      # The held copy now arrives, after the delete. It is genuine, so it passes admission.
      Process.sleep(2_000)

      refute String.contains?(content(b), "doomed-line"),
             "a replayed insert resurrected a deleted line"

      refute String.contains?(content(a), "doomed-line")
      assert_converged([a, b])
    end
  end

  describe "bounded loss" do
    test "replicas converge when messages are lost on every link" do
      start_run(:bounded_loss, delay: {:uniform, 1, 10}, adversary: %{drop_rate: 0.3})
      [a, b] = start_peers(2)

      for index <- 0..2 do
        Peer.insert(a, "lossy-a-#{index}", index, index, 0, 0)
        Process.sleep(150)
        Peer.insert(b, "lossy-b-#{index}", index, index, 0, 0)
        Process.sleep(150)
      end

      # The loss is bounded, which is what the scenario is named for and what keeps the
      # network assumption the recovery path is judged under intact. The window of loss
      # closes here.
      Process.sleep(1_000)
      Network.calm()

      # Both replicas write once more. This is what reveals the gaps: a replica that lost an
      # operation does not know it lost one, and learns only when a later message from that
      # writer arrives carrying progress it has not seen. Recovery is by retransmission from
      # there, so the sweep needs several turns.
      Peer.insert(a, "after-the-loss-a", 0, 0, 0, 0)
      Process.sleep(200)
      Peer.insert(b, "after-the-loss-b", 0, 0, 0, 0)
      Process.sleep(10_000)

      converged = assert_converged([a, b])

      for index <- 0..2 do
        assert String.contains?(converged, "lossy-a-#{index}"),
               "an operation lost on the way was never recovered"

        assert String.contains?(converged, "lossy-b-#{index}")
      end
    end
  end

  describe "what a settled document looks like after a difficult execution" do
    test "no line is left waiting for an acknowledgement it will never get" do
      start_run(:reorder_storm, delay: {:uniform, 0, 60})
      [a, b] = start_peers(2)

      Peer.insert(a, "settling-line", 0, 0, 0, 0)
      Peer.insert(b, "other-line", 0, 0, 0, 0)
      Process.sleep(6_000)

      for peer <- [a, b] do
        unsettled =
          peer
          |> document()
          |> Enum.filter(fn line -> Syncordian.Line_Object.get_line_status(line) == :aura end)

        assert unsettled == [],
               "#{length(unsettled)} line(s) never settled after the network went quiet"
      end
    end
  end
end
