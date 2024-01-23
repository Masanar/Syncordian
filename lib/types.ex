defmodule CRDT.Types do
  @moduledoc """
      This module provides the types used in the CRDT implementation
  """

  @type clock :: integer

  @typedoc """
      Type that represents the peer id
  """
  @type peer_id :: integer

  @typedoc """
      Type that represents the id of a Logoot document line
  """
  @type id :: {integer, peer_id}

  @typedoc """
      Type that represents the position identifier of a Logoot document line 
  """
  @type pid_ :: {list[id], clock}

  @typedoc """
      Type that represents a line of a Logoot document
  """
  @type line :: {pid_, String.t()}

  @type document :: [line]

  @type site :: %{
          id: integer(),
          clock: integer(),
          document: any(),
          pid: pid()
        }
end
