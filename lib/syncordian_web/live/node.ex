defmodule SyncordianWeb.Node do
  use SyncordianWeb, :live_view
  require Syncordian.Line_Object

  def mount(_params, _session, socket) do
    {
      :ok,
      assign(
        socket,
        peer_id: 16,
        lines: []
      )
    }
  end

  def handle_event("refresh", _data, socket) do
    peer_id = socket.assigns.peer_id
    peer_pid = :global.whereis_name(peer_id)

    case peer_pid do
      :undefined ->
        IO.inspect("Node has not been started yet")

      _ ->
        send(peer_pid, {:request_live_view_document, self()})
    end

    {:noreply, socket}
  end

  def handle_info({:receive_live_view_document, document}, socket) do
    # This process is not efficient!! but this will affect the performance of the web app
    # and that is not my goal here, actually this is my first time using LiveView so I am
    # completely sure that there are others parts of the code that can be improved.
    # Additionally, this app do not uses a DB it is trying to simulate a P2P network
    # and I THINK that Phonenix LiveView was not designed to be used in this way. (I THINK)
    IO.inspect("Received document")

    lines =
      Enum.map(document, fn line ->
        %{
          line_id: Syncordian.Line_Object.get_line_id(line),
          content: Syncordian.Line_Object.get_content(line),
          signature: Syncordian.Line_Object.get_signature(line),
          peer_id: Syncordian.Line_Object.get_line_peer_id(line),
          status: Syncordian.Line_Object.get_line_status(line),
          insertion_attempts: Syncordian.Line_Object.get_line_insertion_attempts(line),
          commit_at: Syncordian.Line_Object.get_commit_at(line)
        }
      end)

    {:noreply, assign(socket, lines: lines)}
    # {:noreply,socket}
  end
end
