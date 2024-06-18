defmodule SyncordianWeb.Node do
  use SyncordianWeb, :live_view

  def mount(_params, _session, socket) do
    lines = [
      %{
        line_id: 1,
        content:
          "Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving",
        signature: "1",
        peer_id: "1",
        status: "committed",
        insertion_attempts: 0,
        committed_at: []
      }
    ]
    {
      :ok,
      assign(
        socket,
        peer: 0,
        lines: lines
      )
    }
  end

  def handle_event("guess", %{"number" => guess} = data, socket) do
    IO.inspect(data)
    message = "Your guess : #{guess}. Wrong guess. Try again."
    score = socket.assigns.score - 1
    {:noreply, assign(socket, score: score, message: message)}
  end
end
