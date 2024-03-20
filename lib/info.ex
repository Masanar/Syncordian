defmodule Syncordian.Info do
  use TypeCheck
  import Syncordian.Line_Object

  def print_document_content(document, peer_id) do
    peer_id_string = Integer.to_string(peer_id)
    IO.puts("-----------------Peer id: #{peer_id_string}-----------------")
    Enum.reduce(document, "", fn current_line, acc ->
      acc <> get_content(current_line) <> "\n"
    end) |> IO.puts
    IO.puts("-----------------End of Peer id: #{peer_id_string}-----------------\n")
  end
end
