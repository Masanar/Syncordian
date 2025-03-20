defmodule Syncordian.Info do
  # use TypeCheck
  import Syncordian.Utilities
  import Syncordian.Line_Object

  @doc """
   This function is responsible for saving the document content, filter the Infimum,
   Supremum and the tombstones line, to a file in the directory debug/document.
   The file name is: peer_id.
  """
  @spec save_document_content(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.peer_id()
        ) ::
          :ok
  def save_document_content(document, peer_id) do
    File.write!("debug/documents/syncordian/document_peer_#{peer_id}", string_document_content(document))
  end

  @doc """
    This function cast the syncordian document to a string, where each line in the
    document is a line in the string. Filtering the Infimum, Supremum and the tombstones
  """
  @spec string_document_content(Syncordian.Basic_Types.document()) :: String.t()
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

  @doc """
    This function cast the syncordian document to a string, where each line in the
    document is a line in the string. This function DO NOT filter any line in the
    document. It returns the document as it is.
  """
  @spec string_document_content(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.peer_id()
        ) :: String.t()
  def string_document_content(document, peer_id) do
    peer_id_string = Integer.to_string(peer_id)

    "-----------------Peer id: #{peer_id_string}-----------------\n" <>
      Enum.reduce(document, "", fn current_line, acc ->
        acc <> get_content(current_line) <> "\n"
      end) <>
      "-----------------End of Peer id: #{peer_id_string}-----------------\n"
  end

  @doc """
    This function print the document content to the console, without filtering the Infimum,
    Supremum and the tombstones line. That is, it prints the document as it is.
  """
  @spec print_document_content(
          Syncordian.Basic_Types.document(),
          Syncordian.Basic_Types.peer_id()
        ) ::
          :ok
  def print_document_content(document, peer_id) do
    string_document_content(document, peer_id) |> IO.puts()
  end
end
