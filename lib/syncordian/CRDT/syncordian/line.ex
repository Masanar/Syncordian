defmodule Syncordian.Line_Object do
  @moduledoc """
    This module provides the line object and its basic operations
  """
  # use TypeCheck
  require Record
  import Syncordian.Utilities
  @min_float 130.0
  @max_float 230_584_300_921.0
  # This insertion attempt value is used by the insertion and delete operations
  # to know when to stop trying to insert/delete a line. May be a better name should be
  # used for this value.
  # TODO: Check this value
  @max_insertion_attempts 10_000
  Record.defrecord(:line,
    line_id: 0.0,
    content: "",
    signature: "",
    peer_id: 9_999_999,
    status: :aura,
    insertion_attempts: 0,
    commit_at: []
  )

  @type line ::
          record(
            :line,
            line_id: float(),
            content: Syncordian.Basic_Types.content(),
            signature: Syncordian.Basic_Types.signature(),
            peer_id: Syncordian.Basic_Types.peer_id(),
            status: Syncordian.Basic_Types.status(),
            insertion_attempts: integer(),
            commit_at: Syncordian.Basic_Types.commit_list()
          )

  @spec get_commit_at(Syncordian.Line_Object.line()) ::
          Syncordian.Basic_Types.commit_list()
  def get_commit_at(line),
    do: line(line, :commit_at)

  @spec check_insertions_attempts(Syncordian.Line_Object.line()) :: boolean()
  def check_insertions_attempts(line),
    do: line |> get_line_insertion_attempts |> compare_max_insertion_attempts

  @doc """
    Compares the count of attempts to delete a broadcasted line with the predefine maximum
    number, currently the insertion and deletion have both the same maximum number of
    attempts.

    true when the count of attempts to insert a line is greater than the maximum number.
    false otherwise.
  """
  @spec compare_max_insertion_attempts(integer()) :: boolean()
  def compare_max_insertion_attempts(count), do: count > @max_insertion_attempts

  @spec tick_line_insertion_attempts(line()) :: line()
  def tick_line_insertion_attempts(line),
    do: line(line, insertion_attempts: line(line, :insertion_attempts) + 1)

  @spec tick_line_insertion_attempts(line(), integer()) :: line()
  def tick_line_insertion_attempts(line, acc),
    do: line(line, insertion_attempts: line(line, :insertion_attempts) + acc)

  @spec get_line_insertion_attempts(line()) :: integer()
  def get_line_insertion_attempts(line), do: line(line, :insertion_attempts)

  @spec set_line_status(line(), new_status :: Syncordian.Basic_Types.status()) :: line()
  def set_line_status(line, new_status) do
    line(line, status: new_status)
  end
  
  @spec is_tombstone?(line()) :: boolean()
  def is_tombstone?(line), do: get_line_status(line) == :tombstone

  @doc """
    This function is a getter for the deleted field of a line record, this field is true
    when the line was marked as deleted false otherwise
  """
  @spec get_line_status(Syncordian.Line_Object.line()) :: Syncordian.Basic_Types.status()
  def get_line_status(line),
    do: line(line, :status)

  @doc """
    This function is a getter for  the line_id field of a line record
  """
  @spec get_line_id(Syncordian.Line_Object.line()) :: Syncordian.Basic_Types.line_id()
  def get_line_id(line),
    do: line(line, :line_id)

  @doc """
    This function is a getter for the content field of a line record
  """
  @spec get_content(Syncordian.Line_Object.line()) :: Syncordian.Basic_Types.content()
  def get_content(line),
    do: line(line, :content)

  @doc """
    This function is a getter for the signature field of a line record
  """
  @spec get_signature(Syncordian.Line_Object.line()) :: Syncordian.Basic_Types.signature()
  def get_signature(line),
    do: line(line, :signature)

  def update_line_signature(line, new_signature) do
    line(line, signature: new_signature)
  end

  @doc """
    This function is a getter for the peer_id field of a line record
  """
  @spec get_line_peer_id(Syncordian.Line_Object.line()) ::
          Syncordian.Basic_Types.peer_id()
  def get_line_peer_id(line),
    do: line(line, :peer_id)

  @doc """
    This function is a setter for the peer_id field of a line record
  """
  @spec set_line_peer_id(
          line(),
          new_peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: line()
  def set_line_peer_id(line, new_peer_id) do
    line(line, peer_id: new_peer_id)
  end

  @doc """
    This function creates the infimum line for the given peer id
    that is the absolute first line within peer's document
  """
  @spec create_infimum_line(
          Syncordian.Basic_Types.peer_id(),
          network_size :: integer
        ) :: Syncordian.Line_Object.line()
  def create_infimum_line(peer_id, network_size),
    do:
      line(
        line_id: @min_float,
        content: "Infimum",
        signature: "Infimum",
        status: :settled,
        peer_id: peer_id,
        commit_at: List.duplicate(true, network_size)
      )

  @doc """
    This function creates the supremum line for the given peer id
    that is the absolute last line within peer's document
  """
  @spec create_supremum_line(
          Syncordian.Basic_Types.peer_id(),
          network_size :: integer
        ) :: Syncordian.Line_Object.line()
  def create_supremum_line(peer_id, network_size),
    do:
      line(
        line_id: @max_float,
        content: "Supremum",
        signature: "Supremum",
        status: :settled,
        peer_id: peer_id,
        commit_at: List.duplicate(true, network_size)
      )

  @doc """
    Update the commit_at list of the line with in the received peer id projection, setting
    the value to true.
  """
  @spec update_line_commit_at(
          Syncordian.Line_Object.line(),
          received_peer_id :: Syncordian.Basic_Types.peer_id()
        ) ::
          Syncordian.Line_Object.line()
  def update_line_commit_at(line, received_peer_id) do
    commit_at = update_list_value(get_commit_at(line), received_peer_id, true)
    line(line, commit_at: commit_at)
  end

  @spec get_empty_line() :: Syncordian.Line_Object.line()
  def get_empty_line() do
    line()
  end

  def is_empty_line(line) do
    get_line_peer_id(line) == 9_999_999
  end
end

defmodule Syncordian.Line do
  @moduledoc """
    This module provides complex features for the line object
  """
  # use TypeCheck
  import Syncordian.Utilities
  import Syncordian.Byzantine
  import Syncordian.Line_Object

  @doc """
    Given two lines, left_parent and right_parent, this function creates a new line
    between them taken into account the parent's ids to calculate the new line id
    and the parent's content to create the line signature.
    There are two cases to consider:
      - If there is 'room' between the parent's ids, then the new line id is calculated
       create_line_b randomly between the parent's ids and the signature is created using
        the parent's content and the peer id.
      - If there is no 'room' between the parent's ids, then...
  """
  @spec create_line_between_two_lines(
          content :: Syncordian.Basic_Types.content(),
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Line_Object.line()
  def create_line_between_two_lines(
        content,
        left_parent,
        right_parent,
        peer_id
      ) do
    left_parent_id = get_line_id(left_parent)
    right_parent_id = get_line_id(right_parent)
    network_size = length(get_commit_at(left_parent))
    empty_commit_list = List.duplicate(false, network_size)

    new_line_id =
      get_random_range(right_parent_id, left_parent_id)

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
      commit_at: update_list_value(empty_commit_list, peer_id, true)
    )
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

  @spec line_to_string(Syncordian.Line_Object.line()) :: String.t()
  # This is just for debugging purposes
  def line_to_string(line) do
    "#{get_line_id(line)}" <>
      ", " <>
      Integer.to_string(get_line_peer_id(line)) <>
      ", " <>
      get_content(line) <>
      ", " <>
      get_signature(line) <> ", " <> "#{get_line_status(line)}"
  end
end
