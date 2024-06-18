defmodule Syncordian.Info do
  use TypeCheck
  import Syncordian.Line_Object
  import Syncordian.Utilities

  def save_document_content(document, peer_id) do
    File.write!("debug/document_peer_#{peer_id}", string_document_content(document))
  end

  def string_document_content(document),
    do:
      document
      |> remove_first_and_last
      |> Enum.reduce("", fn current_line, acc ->
        case get_line_status(current_line) do
          :tombstone -> acc
          _ -> acc <> get_content(current_line) <> "\n"
        end
      end)

  def string_document_content(document, peer_id) do
    peer_id_string = Integer.to_string(peer_id)

    "-----------------Peer id: #{peer_id_string}-----------------\n" <>
      Enum.reduce(document, "", fn current_line, acc ->
        acc <> get_content(current_line) <> "\n"
      end) <>
      "-----------------End of Peer id: #{peer_id_string}-----------------\n"
  end

  def print_document_content(document, peer_id) do
    string_document_content(document, peer_id) |> IO.puts()
  end
end
