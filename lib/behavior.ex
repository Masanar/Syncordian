defmodule CRDT.Behavior do
  @moduledoc """
    This module provides the implementation for the behavior of the CRDT implementation
  """

  @spec create_line_id_between_two_lines(
          content :: CRDT.Types.content(),
          previous :: CRDT.Types.line(),
          next :: CRDT.Types.line()
        ) :: CRDT.Types.line_id()
  def create_line_id_between_two_lines(
        content,
        previous_line,
        next_line
      ) do
    # TODO: create the signature and get the new line id
    {0.0, "", ""}
  end
end
