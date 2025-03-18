defmodule SyncordianWeb.Node do
  use SyncordianWeb, :live_view
  require Syncordian.Line_Object

  def mount(_params, _session, socket) do
    {:ok, assign(socket, peer_id: 5, lines: [])}
  end

  def handle_event("refresh", _data, socket) do
    peer_id = socket.assigns.peer_id
    peer_pid = :global.whereis_name(peer_id)

    case peer_pid do
      :undefined -> IO.puts("Node has not been started yet")
      _ -> send(peer_pid, {:request_live_view_document, self()})
    end

    {:noreply, socket}
  end

  def handle_event("select_node", %{"node_id" => node_id}, socket) do
    {:noreply, assign(socket, peer_id: String.to_integer(node_id))}
  end

  def handle_info({:receive_live_view_document, document, handler_function}, socket) do
    IO.puts("Received document")

    lines = Enum.map(document, fn line -> handler_function.(line) end)

    {:noreply, assign(socket, lines: lines)}
  end
end
