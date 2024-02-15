defmodule CRDT.Line_Object do
  import Record
  @min_float 130.0
  @max_float 230_584_300_921_369.0
  Record.defrecord(:line,
    line_id: None,
    content: None,
    signature: None,
    peer_id: None,
    status: false,
    insertion_attempts: 0
  )

  def tick_insertion_attempts(line),
    do: line(line, insertion_attempts: line(line, :insertion_attempts) + 1)

  def get_insertion_attempts(line), do: line(line, :insertion_attempts)

  def set_line_status(line, new_status) do
    line(line, status: new_status)
  end

  @doc """
    This function is a getter for the deleted field of a line record, this field is true
    when the line was marked as deleted false otherwise
  """
  @spec get_status(CRDT.Types.line()) :: boolean()
  def get_status(line),
    do: line(line, :status)

  @doc """
    This function is a getter for  the line_id field of a line record
  """
  @spec get_line_id(CRDT.Types.line()) :: CRDT.Types.line_id()
  def get_line_id(line),
    do: line(line, :line_id)

  @doc """
    This function is a getter for the content field of a line record
  """
  @spec get_content(CRDT.Types.line()) :: CRDT.Types.content()
  def get_content(line),
    do: line(line, :content)

  @doc """
    This function is a getter for the signature field of a line record
  """
  @spec get_signature(CRDT.Types.line()) :: CRDT.Types.signature()
  def get_signature(line),
    do: line(line, :signature)

  @doc """
    This function is a getter for the peer_id field of a line record
  """
  @spec get_peer_id(CRDT.Types.line()) :: CRDT.Types.peer_id()
  def get_peer_id(line),
    do: line(line, :peer_id)

  @doc """
    This function creates the infimum line for the given peer id
    that is the absolute first line within peer's document
  """
  @spec create_infimum_line(CRDT.Types.peer_id()) :: CRDT.Types.line()
  def create_infimum_line(peer_id),
    do:
      line(
        line_id: @min_float,
        content: "Infimum",
        signature: "Infimum",
        peer_id: peer_id
      )

  @doc """
    This function creates the supremum line for the given peer id
    that is the absolute last line within peer's document
  """
  @spec create_supremum_line(CRDT.Types.peer_id()) :: CRDT.Types.line()
  def create_supremum_line(peer_id),
    do:
      line(
        line_id: @max_float,
        content: "Supremum",
        signature: "Supremum",
        peer_id: peer_id
      )
end

defmodule CRDT.Line do
  @moduledoc """
    This module is responsible for the line structure and the line operations provides the
    following functions:
    - get_line_id(line) : returns the line id
    - get_content(line) : returns the content of the line
    - get_signature(line) : returns the signature of the line
    - get_peer_id(line) : returns the peer id of the line
    - create_infimum_line(peer_id) : creates the infimum line for the given peer id
      document
    - create_supremum_line(peer_id) : creates the supremum line for the given peer id
      document
    - create_line_between_two_lines(content, left_parent, right_parent) : creates a new
      line between two lines
  """
  import CRDT.Line_Object
  import CRDT.Byzantine

  @doc """
    Given two lines, left_parent and right_parent, this function creates a new line
    between them taken into account the parent's ids to calculate the new line id
    and the parent's content to create the line signature.
    There are two cases to consider:
      - If there is 'room' between the parent's ids, then the new line id is calculated
        randomly between the parent's ids and the signature is created using the parent's
        content and the peer id.
      - If there is no 'room' between the parent's ids, then...
  """
  @spec create_line_between_two_lines(
          content :: CRDT.Types.content(),
          left_parent :: CRDT.Types.line(),
          right_parent :: CRDT.Types.line()
        ) :: CRDT.Types.line()
  def create_line_between_two_lines(
        content,
        left_parent,
        right_parent
      ) do
    left_parent_id = get_line_id(left_parent)
    right_parent_id = get_line_id(right_parent)
    peer_id = get_peer_id(left_parent)

    case abs(left_parent_id - right_parent_id) do
      1.0 ->
        line(
          line_id: 0.0,
          content: content,
          signature: "",
          peer_id: peer_id
        )

      _ ->
        new_line_id =
          :rand.uniform(round(right_parent_id) - round(left_parent_id) - 1) + left_parent_id

        signature =
          create_signature(
            get_signature(left_parent),
            content,
            get_signature(right_parent),
            peer_id
          )

        line(
          line_id: new_line_id,
          content: content,
          signature: signature,
          peer_id: peer_id
        )
    end
  end

  @doc """
    Given two lines this function defines the order between them, mainly based on the
    line_id field of the lines and the usual number comparison. It returns:
      - 1 if the first line is greater than the second line
      - 0 if the first line is equal to the second line
      - -1 if the first line is less than the second line
      TODO: When is the case that the distance between the lines is 1 is important review
      this, I think that in the case the 0 option should be returned (?)
  """
  @spec compare_lines(
          line1 :: CRDT.Types.line(),
          line2 :: CRDT.Types.line()
        ) :: 0 | 1 | -1
  def compare_lines(line1, line2) do
    line1_id = get_line_id(line1)
    line2_id = get_line_id(line2)

    case {line1_id - line2_id > 0, line1_id - line2_id == 0, line1_id - line2_id < 0} do
      {true, _, _} -> 1
      {_, true, _} -> 0
      {_, _, true} -> -1
    end
  end
end
