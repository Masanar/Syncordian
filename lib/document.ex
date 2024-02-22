defmodule Syncordian.Document do
  use TypeCheck
  import Syncordian.Line_Object
  import Syncordian.Line

  @doc """
    This is a private function used to get the index (position in the document i.e. list)
    of new line by its line_id. It calls an auxiliary function to do the job, passing the
    line_id, the document as arguments ant the initial index 0.

    It is different from the get_document_index_by_line_id/2 because it is used to get in
    the process of inserting a new line broadcasted in the document, so it is important to
    get the index by comparing the line_id with the line_id of the lines in the document.
    And giving the 'middle' index to insert the new line. In the current local peer
    incoming the new insert.
  """
  @spec get_document_new_index_by_incoming_line_id(
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.document()
        ) ::
          integer
  def get_document_new_index_by_incoming_line_id(line, document) do
    line_id = get_line_id(line)
    get_document_new_index_by_incoming_line_id_aux(line_id, document, 0)
  end

  # This is an private recursive auxiliar function over the length of the document to get
  # the index of the line by its line_id.

  # NOTE: It is important to keep the precondition of not having any line ID greater than
  # the @max_float defined at Syncordian.Line module! or else this function will get to an
  # empty document and will return an error. I define a case for this situation, but it is
  # better just to ensure that the line_id is always less than the @max_float.
  @spec get_document_new_index_by_incoming_line_id_aux(
          Syncordian.Basic_Types.line_id(),
          Syncordian.Basic_Types.document(),
          integer()
        ) :: integer

  defp get_document_new_index_by_incoming_line_id_aux(_, [], _) do
    IO.puts("There is an error with the line id it is greater than the maximum float")
    1
  end

  defp get_document_new_index_by_incoming_line_id_aux(line_id, [head | tail], index) do
    head_line_id = get_line_id(head)

    case line_id < head_line_id do
      true -> index
      _ -> get_document_new_index_by_incoming_line_id_aux(line_id, tail, index + 1)
    end
  end

  @doc """
    Given the document and the line_id this function return the index of the corresponding
    line in the document.
  """
  @spec get_document_index_by_line_id(
          document :: Syncordian.Basic_Types.document(),
          line_id :: Syncordian.Type.line_id()
        ) :: integer()
  def get_document_index_by_line_id(document, line_id) do
    index = Enum.find_index(document, fn line -> get_line_id(line) == line_id end)

    case index do
      # 1 is returned in this case because is the safest way to return the first element,
      # since the first element is the infimum line and in the worst case scenario the
      # next is the supremum line.
      nil -> 1
      _ -> index
    end
  end

  @doc """
    Given the document and the line_id, this function search through the document to find the
    line with the given line_id. If not found returns nil.
  """
  @spec get_document_line_by_line_id(Syncordian.Basic_Types.document(), Syncordian.Basic_Types.line_id()) ::
          Syncordian.Line_Object.line()
  def get_document_line_by_line_id(document, line_id) do
    # TODO: check if this functions takes into account that the first and last elements of
    # the document are the infimum and supremum lines.
    Enum.find(document, fn line -> get_line_id(line) == line_id end)
  end

  @doc """
    Given a line of the document, this function returns both parents of the line.
  """
  @spec get_document_line_fathers(Syncordian.Basic_Types.document(), Syncordian.Line_Object.line()) ::
          {Syncordian.Line_Object.line(), Syncordian.Line_Object.line()}
  def get_document_line_fathers(document, line) do
    index = get_document_index_by_line_id(document, get_line_id(line))
    left_parent = get_document_line_by_index(document, index - 1)
    right_parent = get_document_line_by_index(document, index + 1)
    [left_parent, right_parent]
  end

  @doc """
    This function returns the specific line at the given index in the document
  """
  @spec get_document_line_by_index(Syncordian.Basic_Types.document(), integer()) ::
          Syncordian.Line_Object.line()
  def get_document_line_by_index(document, index), do: Enum.at(document, index)

  @doc """
    Given a document and a index, this function change the status of the line at the given
    index, returning the updated document.
  """
  @spec update_line_status(Syncordian.Basic_Types.document(), integer(), boolean()) ::
          Syncordian.Basic_Types.document()
  def update_line_status(document, index, new_value) do
    line = Enum.at(document, index)
    updated_line = set_line_status(line, new_value)
    Enum.concat(Enum.take(document, index), [updated_line | Enum.drop(document, index + 1)])
  end

  @doc """
    This function returns the length of the document
  """
  @spec get_document_length(Syncordian.Basic_Types.document()) :: integer
  def get_document_length(document), do: Enum.count(document)

  @doc """
      This function insert a line into the document in the right position
  """
  @spec add_line_to_document(Syncordian.Line_Object.line(), Syncordian.Basic_Types.document()) ::
          Syncordian.Basic_Types.document()
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
