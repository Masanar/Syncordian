defmodule Syncordian.Line_Object do
  use TypeCheck
  require Record
  @min_float 130.0
  @max_float 230_584_300_921_369.0
  @max_insertion_attempts 5
  Record.defrecord(:line,
    line_id: 0.0,
    content: "",
    signature: "",
    peer_id: None,
    status: :settled,
    insertion_attempts: 0,
    commit_at: []
  )

  @type line ::
          record(
            :line,
            line_id: float(),
            content: Syncordian.Types.content(),
            signature: Syncordian.Types.signature(),
            peer_id: Syncordian.Types.peer_id(),
            status: Syncordian.Types.status(),
            insertion_attempts: integer(),
            commit_at: Syncordian.Types.commit_list()
          )

  @spec get_commit_at(Syncordian.Line_Object.line()) :: Syncordian.Types.commit_list()
  def get_commit_at(line),
    do: line(line, :commit_at)

  @spec check_insertions_attempts(Syncordian.Line_Object.line()) :: boolean()
  def check_insertions_attempts(line),
    do: line |> get_line_insertion_attempts |> compare_max_insertion_attempts

  @doc """
    Compares the count of attempts to delete a broadcasted line with the predefine maximum
    number, currently the insertion and deletion have both the same maximum number of
    attempts.

    Returns true if the count is greater than the maximum number of attempts, false
    otherwise.
  """
  def compare_max_insertion_attempts(count), do: count > @max_insertion_attempts

  def tick_line_insertion_attempts(line),
    do: line(line, insertion_attempts: line(line, :insertion_attempts) + 1)

  def get_line_insertion_attempts(line), do: line(line, :insertion_attempts)

  def set_line_status(line, new_status) do
    line(line, status: new_status)
  end

  @doc """
    This function is a getter for the deleted field of a line record, this field is true
    when the line was marked as deleted false otherwise
  """
  @spec get_status(Syncordian.Line_Object.line()) :: boolean()
  def get_status(line),
    do: line(line, :status)

  @doc """
    This function is a getter for  the line_id field of a line record
  """
  @spec get_line_id(Syncordian.Line_Object.line()) :: Syncordian.Types.line_id()
  def get_line_id(line),
    do: line(line, :line_id)

  @doc """
    This function is a getter for the content field of a line record
  """
  @spec get_content(Syncordian.Line_Object.line()) :: Syncordian.Types.content()
  def get_content(line),
    do: line(line, :content)

  @doc """
    This function is a getter for the signature field of a line record
  """
  @spec get_signature(Syncordian.Line_Object.line()) :: Syncordian.Types.signature()
  def get_signature(line),
    do: line(line, :signature)

  @doc """
    This function is a getter for the peer_id field of a line record
  """
  @spec get_line_peer_id(Syncordian.Line_Object.line()) :: Syncordian.Types.peer_id()
  def get_line_peer_id(line),
    do: line(line, :peer_id)

  @doc """
    This function creates the infimum line for the given peer id
    that is the absolute first line within peer's document
  """
  @spec create_infimum_line(Syncordian.Types.peer_id(), network_size :: integer) ::
          Syncordian.Line_Object.line()
  def create_infimum_line(peer_id, network_size),
    do:
      line(
        line_id: @min_float,
        content: "Infimum",
        signature: "Infimum",
        peer_id: peer_id,
        commit_at: List.duplicate(false, network_size)
      )

  @doc """
    This function creates the supremum line for the given peer id
    that is the absolute last line within peer's document
  """
  @spec create_supremum_line(Syncordian.Types.peer_id(), network_size :: integer) ::
          Syncordian.Line_Object.line()
  def create_supremum_line(peer_id, network_size),
    do:
      line(
        line_id: @max_float,
        content: "Supremum",
        signature: "Supremum",
        peer_id: peer_id,
        commit_at: List.duplicate(false, network_size)
      )
end

defmodule Syncordian.Line do
  use TypeCheck
  import Syncordian.Utilities
  import Syncordian.Byzantine
  import Syncordian.Line_Object

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
          content :: Syncordian.Types.content(),
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line()
        ) :: Syncordian.Line_Object.line()
  def create_line_between_two_lines(
        content,
        left_parent,
        right_parent
      ) do
    left_parent_id = get_line_id(left_parent)
    right_parent_id = get_line_id(right_parent)
    peer_id = get_line_peer_id(left_parent)
    network_size = length(get_commit_at(left_parent))
    empty_commit_list = List.duplicate(false, network_size)

    case abs(left_parent_id - right_parent_id) do
      # TODO: (implementation) review this case! What really happens when the distance is
      # 1?
      1.0 ->
        IO.puts(
          "The distance between the parents id is 1, this is yet to be implemented!!! line.ex"
        )

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
          create_signature_insert(
            get_signature(left_parent),
            content,
            get_signature(right_parent),
            peer_id
          )

        line(
          line_id: new_line_id,
          content: content,
          signature: signature,
          peer_id: peer_id,
          commit_at: update_list_value(empty_commit_list, peer_id, true, 0)
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
          line1 :: Syncordian.Line_Object.line(),
          line2 :: Syncordian.Line_Object.line()
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
