defmodule SyncordianWeb.Supervisor do
  use SyncordianWeb, :live_view
  import Syncordian.Supervisor

  def mount(_params, _session, socket) do
    logs = [
      %{author: "me", hash: "hash"}
    ]

    {
      :ok,
      assign(
        socket,
        logs: logs,
        launched: false,
        supervisor_pid: ""
      )
    }
  end

  def handle_event("launch", _data, socket) do
    launched? = socket.assigns.launched

    socket =
      if launched? do
        IO.inspect("Supervisor already launched")
        socket
      else
        IO.inspect("launching")
        supervisor_pid = Syncordian.Supervisor.init()
        assign(socket, launched: true, supervisor_pid: supervisor_pid)
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
        assign(socket, launched: false, supervisor_pid: "")
      else
        IO.inspect("Supervisor not launched")
        socket
      end

    {:noreply, socket}
  end

  def handle_event("next_commit", _data, socket) do
    IO.inspect("next_commit")
    # put_flash(socket, :info, "It worked!")
    socket = if socket.assigns.launched do
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

  def handle_event("update_logs", data, socket) do
    IO.inspect("update_logs")
    {:noreply, socket}

  end

  def handle_info({:commit_inserted, value}, socket) do
    IO.inspect("update_logs")
    IO.inspect(value)
    # logs = [%{author: value.author, hash: value.hash} | socket.assigns.logs]
    # {:noreply, assign(socket, logs: logs)}
    {:noreply, socket}
  end

  def handle_info({:limit_reached, value}, socket) do
    IO.inspect("Limit reached")
    {:noreply, socket}
  end
  # receive do
  #   {:commit_inserted, state} ->
  #     IO.inspect("Commit inserted :) ")
  #     # I would like to call handle_event("update_logs", value, socket) here but I do not
  #     # have access to the socket variable
  # end

end
