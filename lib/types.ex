defmodule Syncordian.Types do
  @moduledoc """
      This module provides the types used in the Syncordian implementation
  """
  use TypeCheck

  @type content :: String.t()
  @type signature :: String.t()

  @type clock :: integer

  @typedoc """
      Type that represents the peer id
  """
  @type peer_id :: integer

  @typedoc """
      Type that represents the position identifier of a Syncordian document line 
  """
  @type line_id :: float

  @typedoc """
      Type that represents a line of a Syncordian document
  """
  @type line :: %{line_id: line_id,
                  content: content, 
                  signature: signature, 
                  peer_id: peer_id,
                  status: boolean,
                  insertion_attempts: integer
                }

  @typedoc """
      Type that represents a Syncordian document, that is a list of lines, each line has an
      unique position identifier and a content
  """
  @type document :: [line]

  @typedoc """
      Type that represents the individual replica of the Syncordian document for each peer
  """
  @type peer :: %{
          id: peer_id(),
          clock: clock(),
          document: document(),
          pid: pid()
        }
end
