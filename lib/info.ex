defmodule Logoot.Info do
  @moduledoc """
  This module provides information functions about the site document:
  - print_document_info(document) : prints the document content as an string and the
    length of the document, returns nothing.
  - document_length(document) : returns the length of the document, prints nothing.
  - show_document_str(document) : returns a list with the document content as an string
    and the length of the document, prints nothing. It is a private function.
  """

  @doc """
  Prints the document content as an string and the length of the document, returns
  nothing.
  """
  @spec print_document_info(CRDT.Types.document()) :: any
  def print_document_info(document) do
    [document_str, document_len] = document |> show_document_str
    IO.puts("\n ------------------")
    IO.puts("The current document is: ")
    IO.puts(document_str)
    IO.puts("The length of the document is #{inspect(document_len)} ")
    IO.puts("------------------ \n")
  end

  @doc """
  Returns the length of the document, prints nothing.
  """
  @spec document_length(CRDT.Types.document()) :: integer
  def document_length(document), do: document |> length |> Kernel.-(2)

  @doc """
  This a private function that returns a list with the document content as an string and
  the length of the document.
  """
  @spec show_document_str(CRDT.Types.document()) :: {String.t(), integer}
  defp show_document_str(document),
    do:
      Enum.reduce(document, ["", 0], fn [_, value], [str, count] -> [str <> value, count + 1] end)
end