defmodule Syncordian.Live.RecoveryTest do
  @moduledoc """
  Live recovery tests for the anti-entropy fetch path (WS3, reviewer R5).

  These pin the liveness guarantee the horizon reclamation used to break: an operation that
  is admitted but whose dependency is delayed or lost is *never* discarded. When the
  dependency does not arrive within the soft threshold, the waiting replica asks the
  operation's origin to retransmit it, and the origin re-sends it verbatim from its origin
  log (`Syncordian.OpLog`).

  They drive real peer processes, so they are tagged `:live` and run only under
  `mix test --include live`. The soft threshold and sweep cadence are lowered so recovery
  happens within a short window instead of thousands of edits.
  """
  use ExUnit.Case, async: false
  @moduletag :live

  alias Syncordian.Peer
  alias Syncordian.Byzantine
  alias Syncordian.Info

  @secret {"Infimum", "Supremum"}

  setup do
    Byzantine.install_boundary_secret!(@secret)
    Application.put_env(:syncordian, :fetch_soft_threshold, 1)
    Application.put_env(:syncordian, :fetch_sweep_interval_ms, 20)

    on_exit(fn ->
      Application.delete_env(:syncordian, :fetch_soft_threshold)
      Application.delete_env(:syncordian, :fetch_sweep_interval_ms)
      Byzantine.install_boundary_secret!(@secret)
    end)

    :ok
  end

  defp start_peer(id, network_size) do
    pid = Peer.start(id, network_size)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp content(pid) do
    send(pid, {:request_live_view_document, self()})

    receive do
      {:receive_live_view_document, document, _handler} -> Info.string_document_content(document)
    after
      1000 -> flunk("peer did not return its document")
    end
  end

  test "an insert withheld from a replica is recovered from its origin by fetch" do
    a = start_peer(0, 2)
    b = start_peer(1, 2)
    Process.sleep(200)

    # Arm the lossy channel at B: the next inbound broadcast is dropped, as if lost.
    send(b, {:test_drop_next_broadcasts, 1})
    Process.sleep(50)

    # A authors two lines. B loses the first (dropped) and receives the second, which is
    # therefore causally ahead and suspends on the missing first insert. The lost line
    # reached B exactly once, so the only way B can end up holding it is a fetch.
    Peer.insert(a, "line-1", 0, 0, 0, 0)
    Process.sleep(200)
    Peer.insert(a, "line-2", 0, 1, 0, 0)
    Process.sleep(200)

    # B authors its own edits so its edit count advances and the suspended insert ages past
    # the soft threshold, arming the anti-entropy sweep.
    Peer.insert(b, "b-line", 0, 0, 0, 0)
    Process.sleep(100)
    Peer.insert(b, "b-line-2", 0, 1, 0, 0)

    # Let the periodic sweep fire, the fetch reach A, and A's retransmission be applied.
    Process.sleep(1_500)

    b_content = content(b)
    assert String.contains?(b_content, "line-1"), "the withheld line was not recovered by fetch"
    assert String.contains?(b_content, "line-2")

    # Both replicas converge to the same document.
    assert b_content == content(a)
  end

  test "a fetch request without the boundary secret is rejected, a genuine one is served" do
    a = start_peer(0, 1)
    Process.sleep(200)

    # A authors one line, so its origin log holds the operation {0, 1}.
    Peer.insert(a, "served-line", 0, 0, 0, 0)
    Process.sleep(200)

    # The test process stands in for a requester peer, registered so A can answer it.
    requester_id = 50
    :global.register_name(requester_id, self())
    on_exit(fn -> :global.unregister_name(requester_id) end)

    want = {:op, {0, 1}}

    # A forged request (no valid authenticator) is dropped: nothing is served.
    send(a, {:fetch_request, requester_id, want, "FORGED-ALPHA"})
    refute_receive {:receive_insert_broadcast, _payload, _alpha}, 300

    # A genuine, admission-authenticated request is served verbatim.
    alpha = Byzantine.create_admission(@secret, :fetch, {requester_id, want})
    send(a, {:fetch_request, requester_id, want, alpha})
    assert_receive {:receive_insert_broadcast, _payload, _alpha}, 500
  end
end
