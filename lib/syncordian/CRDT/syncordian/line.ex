defmodule Syncordian.Line_Object do
  @moduledoc """
    This module provides the line object and its basic operations
  """
  # use TypeCheck
  require Record
  import Syncordian.Utilities
  alias Syncordian.PathId

  Record.defrecord(:line,
    line_id: nil,
    content: "",
    # Stored signature σ: immutable identifier, set exactly once — by the author at
    # creation, or sealed by a receiver from the accepted parent pair — and never
    # recomputed (see the invariant in Syncordian.Byzantine). It is never transmitted:
    # only domain-separated wire tags travel, and each replica derives the identical σ
    # locally from the authored parent pair it resolves by identity (op_id), never by
    # rehashing when neighbors drift.
    signature: "",
    peer_id: 9_999_999,
    status: :aura,
    # Retained for the LiveView node view only; no longer a retry gate. Undeliverable
    # operations are now suspended on their dependency (see Syncordian.PendingOps) instead
    # of being re-tried up to a fixed counter, so this stays 0 in normal operation.
    insertion_attempts: 0,
    commit_at: [],
    # Authored identity, used to reconstruct edit blocks for interleaving detection
    # (def:editblock). op_id is the {writer, seq} of the insert that created this line;
    # parent_left_op_id / parent_right_op_id are the op_ids of its authored parents — the
    # pair the writer created it between, located on receivers by the verifying signature
    # (the verifying pair is the authored pair). nil on the boundary sentinels, which
    # belong to no block. Immutable, like the stored signature.
    op_id: nil,
    parent_left_op_id: nil,
    parent_right_op_id: nil
  )

  @type line ::
          record(
            :line,
            line_id: Syncordian.Basic_Types.line_id() | nil,
            content: Syncordian.Basic_Types.content(),
            signature: Syncordian.Basic_Types.signature(),
            peer_id: Syncordian.Basic_Types.peer_id(),
            status: Syncordian.Basic_Types.status(),
            insertion_attempts: integer(),
            commit_at: Syncordian.Basic_Types.commit_list(),
            op_id: Syncordian.Basic_Types.op_id() | nil,
            parent_left_op_id: Syncordian.Basic_Types.op_id() | nil,
            parent_right_op_id: Syncordian.Basic_Types.op_id() | nil
          )

  @spec get_commit_at(Syncordian.Line_Object.line()) ::
          Syncordian.Basic_Types.commit_list()
  def get_commit_at(line),
    do: line(line, :commit_at)

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

  @doc """
    Getter for the op_id of a line: the {writer, seq} of the insert that created it
    (nil on the boundary sentinels).
  """
  @spec get_line_op_id(Syncordian.Line_Object.line()) :: Syncordian.Basic_Types.op_id() | nil
  def get_line_op_id(line),
    do: line(line, :op_id)

  @doc "Getter for the op_id of the line's authored left parent (nil if a boundary)."
  @spec get_line_parent_left_op_id(Syncordian.Line_Object.line()) ::
          Syncordian.Basic_Types.op_id() | nil
  def get_line_parent_left_op_id(line),
    do: line(line, :parent_left_op_id)

  @doc "Getter for the op_id of the line's authored right parent (nil if a boundary)."
  @spec get_line_parent_right_op_id(Syncordian.Line_Object.line()) ::
          Syncordian.Basic_Types.op_id() | nil
  def get_line_parent_right_op_id(line),
    do: line(line, :parent_right_op_id)

  @doc """
    Seals a remotely received line's authored identity in one step: its stored signature
    (computed locally from the accepted parent pair) together with its op_id and the op_ids
    of its authored parents (that same accepted pair, which up to a hash collision is the
    pair the author created it between). Set exactly once, here, and never recomputed — the
    op_ids let every replica reconstruct authored edit blocks identically for interleaving
    detection (`Syncordian.Interleaving`, def:editblock).
  """
  @spec seal_line_authored(
          line(),
          Syncordian.Basic_Types.signature(),
          Syncordian.Basic_Types.op_id(),
          Syncordian.Basic_Types.op_id() | nil,
          Syncordian.Basic_Types.op_id() | nil
        ) :: line()
  def seal_line_authored(line, signature, op_id, parent_left_op_id, parent_right_op_id) do
    line(line,
      signature: signature,
      op_id: op_id,
      parent_left_op_id: parent_left_op_id,
      parent_right_op_id: parent_right_op_id
    )
  end

  @doc """
    Builds the local line record for a remotely received insert. Only the public fields
    travel on the wire (position, content, author); the stored signature is *not* among
    them — the receiver computes it from the accepted parents and attaches it with
    `seal_line_authored/5`. The response checklist is initialized exactly as the author
    initialized its own copy: all false except the author's own entry.
  """
  @spec create_line_from_wire(
          line_id :: Syncordian.Basic_Types.line_id(),
          content :: Syncordian.Basic_Types.content(),
          peer_id :: Syncordian.Basic_Types.peer_id(),
          network_size :: integer()
        ) :: line()
  def create_line_from_wire(line_id, content, peer_id, network_size) do
    commit_at =
      List.duplicate(false, network_size)
      |> update_list_value(peer_id, true)

    line(
      line_id: line_id,
      content: content,
      peer_id: peer_id,
      commit_at: commit_at
    )
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
    that is the absolute first line within peer's document. Its stored signature is κ⊥,
    the first half of the document's boundary secret (`Syncordian.Byzantine.boundary_secret/0`)
    — the root of every stored-signature chain and half of the admission key.
  """
  @spec create_infimum_line(
          Syncordian.Basic_Types.peer_id(),
          network_size :: integer
        ) :: Syncordian.Line_Object.line()
  def create_infimum_line(peer_id, network_size) do
    {infimum_secret, _} = Syncordian.Byzantine.boundary_secret()

    line(
      line_id: PathId.infimum(),
      content: "Infimum",
      signature: infimum_secret,
      status: :settled,
      peer_id: peer_id,
      commit_at: List.duplicate(true, network_size),
      # Sentinel authored identity: real peer ids are non-negative, so the reserved
      # writer -1 belongs to no peer. A line authored just after the infimum names this
      # op_id as its left parent, and every replica resolves it to its own infimum line
      # through the peer's op-id index (see Syncordian.Peer.get_line_by_op_id/2).
      op_id: {-1, 0}
    )
  end

  @doc """
    This function creates the supremum line for the given peer id
    that is the absolute last line within peer's document. Its stored signature is κ⊤,
    the second half of the document's boundary secret.
  """
  @spec create_supremum_line(
          Syncordian.Basic_Types.peer_id(),
          network_size :: integer
        ) :: Syncordian.Line_Object.line()
  def create_supremum_line(peer_id, network_size) do
    {_, supremum_secret} = Syncordian.Byzantine.boundary_secret()

    line(
      line_id: PathId.supremum(),
      content: "Supremum",
      signature: supremum_secret,
      status: :settled,
      peer_id: peer_id,
      commit_at: List.duplicate(true, network_size),
      # Sentinel authored identity, the supremum counterpart of the infimum's {-1, 0}
      # (see create_infimum_line/2). A line authored just before the supremum names this
      # op_id as its right parent.
      op_id: {-1, 1}
    )
  end

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
    # Settling when the checklist completes is the caller's concern:
    # Syncordian.Document.settle_line_if_complete/2 joins :aura into :settled once every
    # entry is true, right after the checklist update.
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
  alias Syncordian.PathId

  @doc """
    Given two lines, left_parent and right_parent, this function creates a new line
    between them: its position is allocated strictly between the parents' PathIds
    (`Syncordian.PathId.between/3`, total — a fresh position always exists), and its
    stored signature σ is derived from the parents' stored signatures, the content, and
    the authoring peer id (`Syncordian.Byzantine.create_signature_doc/4`).
  """
  @spec create_line_between_two_lines(
          content :: Syncordian.Basic_Types.content(),
          left_parent :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line(),
          peer_id :: Syncordian.Basic_Types.peer_id(),
          op_id :: Syncordian.Basic_Types.op_id()
        ) :: Syncordian.Line_Object.line()
  def create_line_between_two_lines(
        content,
        left_parent,
        right_parent,
        peer_id,
        op_id
      ) do
    left_parent_id = get_line_id(left_parent)
    right_parent_id = get_line_id(right_parent)
    network_size = length(get_commit_at(left_parent))
    empty_commit_list = List.duplicate(false, network_size)

    new_line_id =
      PathId.between(left_parent_id, right_parent_id, peer_id)

    signature =
      create_signature_doc(
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
      commit_at: update_list_value(empty_commit_list, peer_id, true),
      op_id: op_id,
      parent_left_op_id: get_line_op_id(left_parent),
      parent_right_op_id: get_line_op_id(right_parent)
    )
  end

  @doc """
    Given two lines this function defines the replica-independent total order ⋖ of the
    formal model: primarily the PathId position order, with position ties broken by the
    lines' authored identity — the `{writer, seq}` op_id (formalism def of ⋖: order by
    position, ties by identity). Distinct lines therefore never compare equal; 0 is
    returned only for the *same* line (same op_id), which callers treat as a duplicate
    delivery. It returns:
      - 1 if the first line is greater than the second line
      - 0 if the first line is the same line as the second line
      - -1 if the first line is less than the second line
  """
  @spec compare_lines(
          line1 :: Syncordian.Line_Object.line(),
          line2 :: Syncordian.Line_Object.line()
        ) :: 0 | 1 | -1
  def compare_lines(line1, line2) do
    case PathId.compare(get_line_id(line1), get_line_id(line2)) do
      :gt -> 1
      :lt -> -1
      :eq -> compare_lines_identity(line1, line2)
    end
  end

  # Identity tiebreak for equal positions: op_ids are {writer, seq} tuples, so Erlang
  # term order on them is exactly the lexicographic (writer, seq) order the model uses.
  # The boundary sentinels carry the reserved op_ids {-1, 0} / {-1, 1} but hold unique
  # sentinel positions, so PathId.compare/2 already separates them from every real line
  # and they never reach this tiebreak; the nil clauses below are retained only as
  # defense in depth for a line whose identity was somehow left unset.
  defp compare_lines_identity(line1, line2) do
    op_id1 = get_line_op_id(line1)
    op_id2 = get_line_op_id(line2)

    cond do
      op_id1 == op_id2 -> 0
      op_id1 == nil -> -1
      op_id2 == nil -> 1
      op_id1 < op_id2 -> -1
      true -> 1
    end
  end

  @spec line_to_string(Syncordian.Line_Object.line()) :: String.t()
  # This is just for debugging purposes
  def line_to_string(line) do
    PathId.to_string(get_line_id(line)) <>
      ", " <>
      Integer.to_string(get_line_peer_id(line)) <>
      ", " <>
      get_content(line) <>
      ", " <>
      get_signature(line) <> ", " <> "#{get_line_status(line)}"
  end
end
