defmodule CRDT.Types do
  @moduledoc """
      This module provides the types used in the CRDT implementation
  """

  @type content :: String.t()
  @type signature :: String.t()

  @type clock :: integer

  @typedoc """
      Type that represents the peer id
  """
  @type peer_id :: integer

  @typedoc """
      Type that represents the position identifier of a CRDT document line 
  """
  @type line_id :: float

  @typedoc """
      Type that represents a line of a CRDT document
  """
  @type line :: %{line_id: line_id,
                  content: content, 
                  signature: signature, 
                  peer_id: peer_id,
                  status: boolean
                }

  @typedoc """
      Type that represents a CRDT document, that is a list of lines, each line has an
      unique position identifier and a content
  """
  @type document :: [line]

  @typedoc """
      Type that represents the individual replica of the CRDT document for each peer
  """
  @type site :: %{
          id: peer_id(),
          clock: clock(),
          document: document(),
          pid: pid()
        }
end
