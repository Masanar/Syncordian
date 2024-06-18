defmodule SyncordianWeb.Node do
  use SyncordianWeb, :live_view
  def mount(_params, _session, socket) do
    lines = [
      %{line_id: 1, content: "Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving Syncordian: A Byzantine Fault Tolerant CRDT without Interleaving", signature: "1", peer_id: "1", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 2, content: "World", signature: "2fjasdjfklasdjfkasdjfkljsdafkljasdfk", peer_id: "2", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 3, content: "Hellokfsdafjkdsjfkdajsfkladjfklasdjfkljdsfkljsdfklsdjflkasdf", signature: "3", peer_id: "3", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 4, content: "World", signature: "4", peer_id: "4", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 5, content: "Hello", signature: "5", peer_id: "5", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 6, content: "World", signature: "6", peer_id: "6", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 7, content: "Hello", signature: "7", peer_id: "7", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 8, content: "World", signature: "8", peer_id: "8", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 9, content: "Hello", signature: "9", peer_id: "9", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 10, content: "World", signature: "10", peer_id: "10", status: "ccommittedcommittedcommittedcommittedcom mittedcommittedcommittedcommittedcommittedcommittedcommittedcommittedcommittedcommittedcommittedcommittedommitted", insertion_attempts: 0, committed_at: []},
      %{line_id: 11, content: "Hello", signature: "11", peer_id: "11", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 12, content: "World", signature: "12", peer_id: "12", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 13, content: "Hello", signature: "13", peer_id: "13", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 14, content: "World", signature: "14", peer_id: "14", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 15, content: "Hello", signature: "15", peer_id: "15", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 16, content: "World", signature: "16", peer_id: "16", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 17, content: "Hello", signature: "17", peer_id: "17", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 18, content: "World", signature: "18", peer_id: "18", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 19, content: "Hello", signature: "19", peer_id: "19", status: "committed", insertion_attempts: 0, committed_at: []},
      %{line_id: 20, content: "World", signature: "20", peer_id: "20", status: "committed", insertion_attempts: 0, committed_at: []},
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
