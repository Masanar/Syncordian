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
  import Record
  import CRDT.Byzantine
  @min_float 130.0
  @max_float 230_584_300_921_369.0
  Record.defrecord(:line, line_id: None, content: None, signature: None, peer_id: None)

  @spec get_line_id(CRDT.Types.line()) :: CRDT.Types.line_id()
  def get_line_id(line),
    do: line(line, :line_id)

  @spec get_content(CRDT.Types.line()) :: CRDT.Types.content()
  def get_content(line),
    do: line(line, :content)

  @spec get_signature(CRDT.Types.line()) :: CRDT.Types.signature()
  def get_signature(line),
    do: line(line, :signature)

  @spec get_peer_id(CRDT.Types.line()) :: CRDT.Types.peer_id()
  def get_peer_id(line),
    do: line(line, :peer_id)

  @spec create_infimum_line(CRDT.Types.peer_id()) :: CRDT.Types.line()
  def create_infimum_line(peer_id),
    do: line(line_id: @min_float, content: "Infimum", signature: "", peer_id: peer_id)

  @spec create_supremum_line(CRDT.Types.peer_id()) :: CRDT.Types.line()
  def create_supremum_line(peer_id),
    do: line(line_id: @max_float, content: "Supremum", signature: "", peer_id: peer_id)

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
    # TODO: create the signature and get the new line id
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
            get_content(left_parent),
            content,
            get_content(right_parent),
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
end
