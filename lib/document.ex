defmodule CRDT.Document do
  use TypeCheck
  import CRDT.Line_Object
  import CRDT.Line


  @doc """
    Given a document and a index, this function change the status of the line at the given
    index, returning the updated document.
  """
  @spec update_line_status(CRDT.Types.document(), integer(), boolean()) ::
          CRDT.Types.document() 
  def update_line_status(document, index, new_value) do
    line = Enum.at(document, index)
    updated_line = set_line_status(line, new_value)
    Enum.concat(Enum.take(document, index), [ updated_line | Enum.drop(document, index + 1)])
  end

  @doc """
    This function returns the length of the document
  """
  @spec get_document_length(CRDT.Types.document()) :: integer
  def get_document_length(document) ,do:
    Enum.count(document)
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
