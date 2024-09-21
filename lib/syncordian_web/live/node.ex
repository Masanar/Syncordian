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

  def handle_info({:receive_live_view_document, document}, socket) do
    IO.puts("Received document")

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
  end
end
