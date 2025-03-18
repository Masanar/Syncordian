defmodule Syncordian.Basic_Types do
  @moduledoc """
      This module provides the types used in the Syncordian implementation
  """
#   use TypeCheck

  @typedoc """
    Type that represents the status of a Syncordian document line, those are: -
        :tombstone: The line was deleted by the peer, but still exists in the document.

        - :aura:
            - The line has not been received but the whole network.

        - :settled: The line was received but all the peers.

        - :conflict: The line was stash due to a clock inconsistency, and will be reinserted
            in the document when the stash is resolved.
  """
  @type status :: :tombstone | :aura | :settled | :conflict | :nil

  @typedoc """
      Type that represents the content of a Syncordian document line
  """
  @type content :: String.t()

  @typedoc """
      Type that represents the signature of a Syncordian document line
  """
  @type signature :: String.t()

  @typedoc """
      Type that represents the vector clock of a Syncordian peer, are the same proposed by
      Lamport in 1978 (?)
  """
  @type vector_clock :: [integer()]

  @typedoc """
    Type that represents the commit list of a Syncordian document line, it is a list of
    boolean values, each value represents the commit status of the line in the peer
    position
  """
  @type commit_list :: [boolean()]

  @typedoc """
      Type that represents the peer id
  """
  @type peer_id :: integer()

  @typedoc """
      Type that represents the position identifier of a Syncordian document's line
  """
  @type line_id :: float()

  #   Type that represents a line of a Syncordian document
  # No longer needed, instead define within the Line module
  #   @type line :: %{
  #           line_id: line_id(),
  #           content: content(),
  #           signature: signature(),
  #           peer_id: peer_id(),
  #           status: status(),
  #           insertion_attempts: integer(),
  #           committed_at: commit_list()
  #         }

  @typedoc """
      Type that represents a Syncordian document, that is a list of lines, each line has an
      unique position identifier and a content
  """
  @type document :: [Syncordian.Line_Object.line()]

  #   Type that represents the individual replica of the Syncordian document for each peer
  #   The pid is the actual pid generated by the Erlang VM when the peer is started, based
  #   on the peer_id given by the 'user'. The deleted_limit is a fixed number of lines that
  #   can be deleted from the document, after that the peer will call the garbage collection
  #   process in the whole network i.e. the update operation.
  # No longer needed, instead define within the Peer module
  #   @type peer :: %{
  #           peer_id: peer_id(),
  #           document: document(),
  #           pid: pid(),
  #           deleted_count: integer(),
  #           deleted_limit: integer(),
  #           vector_clock: vector_clock()
  #         }

  @type git_document_index :: integer()

  @type crdt_id :: :syncordian | :fugue | :treedoc | :logoot | nil
end
