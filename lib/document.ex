defmodule Syncordian.Document do
  use TypeCheck
  import Syncordian.Line_Object
  import Syncordian.Line


  @doc """
    Given a document and a index, this function change the status of the line at the given
    index, returning the updated document.
  """
  @spec update_line_status(Syncordian.Types.document(), integer(), boolean()) ::
          Syncordian.Types.document() 
  def update_line_status(document, index, new_value) do
    line = Enum.at(document, index)
    updated_line = set_line_status(line, new_value)
    Enum.concat(Enum.take(document, index), [ updated_line | Enum.drop(document, index + 1)])
  end

  @doc """
    This function returns the length of the document
  """
  @spec get_document_length(Syncordian.Types.document()) :: integer
  def get_document_length(document) ,do:
    Enum.count(document)
  @doc """
      This function insert a line into the document in the right position
  """
  @spec add_line_to_document(Syncordian.Types.line(), Syncordian.Types.document()) ::
          Syncordian.Types.document()
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
