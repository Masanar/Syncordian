defmodule CRDT.Document do
  import CRDT.Line

  @doc """
      This function insert a line into the document in the right position
  """
  @spec add_line_to_document(CRDT.Types.line(), CRDT.Types.document()) ::
          CRDT.Types.document()
  def add_line_to_document(line, document = [head | tail]) do
    case compare_lines(line, head) do
      1 ->
        [head | add_line_to_document(line, tail)]

      0 ->
        IO.inspect("Line Error")
        document

      -1 ->
        [line | document]
    end
  end
end
