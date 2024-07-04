defmodule SyncordianWeb.Supervisor do
  use SyncordianWeb, :live_view
  import Syncordian.Supervisor

  def mount(_params, session, socket) do
    socket =
      socket
      |> PhoenixLiveSession.maybe_subscribe(session)
      |> put_session_assigns(session)

    {:ok, socket}
  end

  def handle_event("write", _data, socket) do
    #  the write_current_peers_document message is written but committed
    IO.inspect(
      "Pending, here send (write_current_peers_document) message to supevisor if the supervisor is running"
    )

    {:noreply, socket}
  end

  def handle_event("launch", _data, socket) do
    launched? = socket.assigns.launched

    socket =
      if launched? do
        IO.inspect("Supervisor already launched")
        socket
      else
        IO.inspect("launching")
        supervisor_pid = init()
        PhoenixLiveSession.put_session(socket, "launched", true)
        PhoenixLiveSession.put_session(socket, "supervisor_pid", supervisor_pid)
        PhoenixLiveSession.put_session(socket, "logs", [])
        # assign(socket, launched: true, supervisor_pid: supervisor_pid, logs: [])
      end

    IO.inspect("launched")
    IO.inspect(socket.assigns.supervisor_pid)
    {:noreply, socket}
  end

  def handle_event("kill", _data, socket) do
    launched? = socket.assigns.launched
    supervisor_pid = socket.assigns.supervisor_pid

    socket =
      if launched? do
        IO.inspect("Killing supervisor")
        send(supervisor_pid, {:kill})
        PhoenixLiveSession.put_session(socket, "launched", false)
        PhoenixLiveSession.put_session(socket, "supervisor_pid", "")
        PhoenixLiveSession.put_session(socket, "logs", [])
        # assign(socket, launched: false, supervisor_pid: "")
      else
        IO.inspect("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_event("next_commit", _data, socket) do
    IO.inspect("next_commit")
    # put_flash(socket, :info, "It worked!")
    socket =
      if socket.assigns.launched do
        supervisor_pid = socket.assigns.supervisor_pid
        send(supervisor_pid, {:send_next_commit, self()})
        IO.inspect("Sending next commit")
        socket
      else
        IO.inspect("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:commit_inserted, value}, socket) do
    logs = [%{author: value.author, hash: value.hash} | socket.assigns.logs]
    PhoenixLiveSession.put_session(socket, "logs", logs)
    {:noreply, assign(socket, logs: logs)}
  end

  def handle_info({:limit_reached, _value}, socket) do
    IO.inspect("Limit reached")
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
  end
end
