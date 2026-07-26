defmodule SyncordianWeb.Supervisor do
  @moduledoc """
  LiveView control panel for driving an experiment (route `/supervisor`).

  This is the main bridge between the browser and the experiment engine. From here
  you pick a CRDT module and a Byzantine node count, **Launch** (which spawns one
  peer per author in the test git log plus the Byzantine peers), then replay
  commits one at a time or all at once, dump every peer's document to disk, and
  collect metadata. Each button sends a message
  (`{:send_next_commit, ...}`, `{:send_all_commits, ...}`,
  `{:write_current_peers_document}`, `{:collect_metadata_from_peers}`, `{:kill}`)
  to the globally-registered `Syncordian.Supervisor` process, whose helper
  functions are imported here. Selection state is kept in the Phoenix LiveSession.
  """
  use SyncordianWeb, :live_view
  import Syncordian.Supervisor

  def mount(_params, session, socket) do
    socket =
      socket
      |> PhoenixLiveSession.maybe_subscribe(session)
      |> put_session_assigns(session)

    {:ok, socket}
  end

  def handle_event("write_current_peers_document", _data, socket) do
    launched? = socket.assigns.launched

    if launched? do
      IO.puts("Writing current peers document...")
      send(socket.assigns.supervisor_pid, {:write_current_peers_document})
    else
      IO.puts("Supervisor not launched")
    end

    {:noreply, socket}
  end

  def handle_event("select_node", %{"byzantine_nodes" => byzantine_nodes}, socket) do
    PhoenixLiveSession.put_session(socket, "byzantine_nodes", String.to_integer(byzantine_nodes))
    {:noreply, socket}
  end

  def handle_event("launch", _data, socket) do
    launched? = socket.assigns.launched

    socket =
      if launched? do
        IO.puts("Supervisor already launched")
        socket
      else
        IO.puts("launching")
        crdt_module = socket.assigns.crdt_module
        supervisor_pid = init(socket.assigns.byzantine_nodes, crdt_module)
        PhoenixLiveSession.put_session(socket, "launched", true)
        PhoenixLiveSession.put_session(socket, "supervisor_pid", supervisor_pid)
        PhoenixLiveSession.put_session(socket, "logs", [])
      end

    {:noreply, socket}
  end

  def handle_event("collect_metadata", _data, socket) do
    launched? = socket.assigns.launched
    supervisor_pid = socket.assigns.supervisor_pid

    if launched? do
      IO.puts("Collecting metadata...")
      IO.puts("Please wait until the process is finished...")
      send(supervisor_pid, {:collect_metadata_from_peers})
    else
      IO.puts("Supervisor not launched")
    end

    {:noreply, socket}
  end

  def handle_event("print_metadata", _data, socket) do
    launched? = socket.assigns.launched
    supervisor_pid = socket.assigns.supervisor_pid

    if launched? do
      IO.puts("Printing metadata...")
      IO.puts("Check /debug/metadata/ for the metadata files")
      send(supervisor_pid, {:print_supervisor_metadata})
    else
      IO.puts("Supervisor not launched")
    end

    {:noreply, socket}
  end

  def handle_event("select_crdt", %{"crdt_module" => value}, socket) do
    # Matched against the known implementations rather than converted, for the reason
    # `Syncordian.Utilities.parse_crdt_id/1` records: the atom naming an implementation exists only
    # once something has referred to that module, so converting here fails on a fresh node.
    crdt_module = Syncordian.Utilities.parse_crdt_id(value)
    IO.puts("Selected CRDT module: #{crdt_module}")
    IO.inspect(crdt_module)
    PhoenixLiveSession.put_session(socket, "crdt_module", crdt_module)
    {:noreply, socket}
  end

  def handle_event("kill", _data, socket) do
    launched? = socket.assigns.launched
    supervisor_pid = socket.assigns.supervisor_pid

    socket =
      if launched? do
        IO.puts("Killing supervisor")
        send(supervisor_pid, {:kill})
        PhoenixLiveSession.put_session(socket, "launched", false)
        PhoenixLiveSession.put_session(socket, "supervisor_pid", "")
        PhoenixLiveSession.put_session(socket, "logs", [])
      else
        IO.puts("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_event("all_commits", _data, socket) do
    socket =
      if socket.assigns.launched do
        if socket.assigns.disable_next_commit do
          IO.puts("Next commit disabled")
          socket
        else
          IO.puts("Sending All Commits")
          supervisor_pid = socket.assigns.supervisor_pid
          send(supervisor_pid, {:send_all_commits, self(), socket.assigns.byzantine_nodes})
          socket
        end
      else
        IO.puts("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_event("next_commit", _data, socket) do
    socket =
      if socket.assigns.launched do
        if socket.assigns.disable_next_commit do
          IO.puts("Next commit disabled")
          socket
        else
          IO.puts("Sending next commit")
          supervisor_pid = socket.assigns.supervisor_pid
          send(supervisor_pid, {:send_next_commit, self(), socket.assigns.byzantine_nodes})
          socket
        end
      else
        IO.puts("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:enable_button, socket) do
    PhoenixLiveSession.put_session(socket, "disable_next_commit", false)
    {:noreply, socket}
  end

  def handle_info({:commit_inserted, value}, socket) do
    logs = [%{author: value.author, hash: value.hash} | socket.assigns.logs]
    PhoenixLiveSession.put_session(socket, "logs", logs)
    {:noreply, assign(socket, logs: logs)}
  end

  def handle_info({:limit_reached, _value}, socket) do
    IO.puts("Web supervisor: limit reached")
    IO.puts("--------------------------------")
    IO.puts("")
    {:noreply, socket}
  end

  def handle_info({:live_session_updated, session}, socket) do
    {:noreply, put_session_assigns(socket, session)}
  end

  def put_session_assigns(socket, session) do
    socket
    |> assign(:logs, Map.get(session, "logs", []))
    |> assign(:launched, Map.get(session, "launched", false))
    |> assign(:supervisor_pid, Map.get(session, "supervisor_pid", ""))
    |> assign(:disable_next_commit, Map.get(session, "disable_next_commit", false))
    |> assign(:byzantine_nodes, Map.get(session, "byzantine_nodes", 0))
    |> assign(:crdt_module, Map.get(session, "crdt_module", :syncordian))
  end
end
