defmodule CRDT.Byzantine do
  @moduledoc """
    This module is responsible for the byzantine operations aiming to provide the features
    to support the byzantine fault tolerance in the CRDT implementation.
  """
  @spec create_signature(
          left_parent_content :: CRDT.Types.content(),
          new_content :: CRDT.Types.content(),
          right_parent_content :: CRDT.Types.content(),
          peer_id :: CRDT.Types.peer_id()
        ) :: CRDT.Types.signature()
  def create_signature(left_parent_content, new_content, right_parent_content, peer_id) do
    element = "#{left_parent_content}#{new_content}#{right_parent_content}#{peer_id}"
    :crypto.hash(:sha256, element) |> Base.encode16()
  end
end

# :crypto.hash(:sha256, [3, "things", "!"]) |> Base.encode16
