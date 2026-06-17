defmodule Syncordian.Byzantine do
  # use TypeCheck

  @moduledoc """
    Cryptographic core of Syncordian's protection against distrusted (outsider) nodes:
    the dual domain-separated signature scheme plus the per-message admission
    authenticator of the paper's formal model (the stored-signature definition, the wire
    tags, and the admission authenticator α of the formal-model section).

    ## Dual signatures (domain separation)

    A line carries exactly **one** *stored signature* σ — its immutable identifier —
    computed once, under the `:doc` domain, from immutable inputs and never recomputed
    afterwards:

        σ(line) = h( :doc, σ(left_parent), content, σ(right_parent), peer_id )

    The stored signature is **never transmitted**: the author computes it locally at
    insertion, and every receiver re-derives it locally from the parent pair it accepted
    (`create_signature_doc/4`). Collision resistance of `h` guarantees the insert wire
    tag admits exactly one parent pair — the authored one — so all replicas compute the
    *same* σ without it ever riding a message. What travels are only *wire tags*, hashes
    of stored signatures under domains distinct from `:doc` and distinct per operation
    kind:

        t_ins = h( :ins, σ(left_parent), content, σ(right_parent), peer_id )
        t_del = h( :del, σ(target) )
        t_ack = h( :ack, σ(line),  acker_peer_id )

    Because the domains differ, a digest observed on the wire is never itself a stored
    signature and can never be replayed in the place of one — an insert tag cannot pass
    as a delete authorization, nor vice versa — and a traffic-observing outsider learns
    no stored signature, hence nothing about the boundary secret in which every stored
    signature is rooted (the signature-chain and opacity lemma of the formal model).

    ## Admission authenticator

    Every broadcast message additionally carries an admission authenticator

        α(m) = h( :adm, κ⊥, kind, payload, κ⊤ )

    keyed by the *boundary secret*: the digests κ⊥/κ⊤ of the document's permanent first
    and last lines, shared out-of-band among admitted peers and never put on the wire.
    A receiver checks α before anything else — before the replay/duplicate check, before
    any per-line verification, and before suspending an out-of-order message — and
    silently drops failures. A node that does not hold the boundary secret therefore
    cannot produce a single message that is applied *or buffered*. Since the
    authenticator covers the full payload, it also binds the `op_id` of inserts and
    deletes; tampering with any field invalidates it.

    In this simulation κ⊥/κ⊤ are the constant sentinel signatures of the infimum and
    supremum lines (`Syncordian.Line_Object.create_infimum_line/2` /
    `create_supremum_line/2`), standing in for per-document random secrets drawn at the
    document's inception; possession of the pair *is* the admission capability. Their
    distribution and rotation are an out-of-band concern, discussed in the paper.

    ## Encoding

    `h` is sha256 over the deterministic external term format
    (`:erlang.term_to_binary/2`) of a domain-tagged tuple. The tuple encoding is
    injective — field boundaries are part of the encoding — so the concatenation
    ambiguity of naive string interpolation cannot be exploited to equate two distinct
    preimages.

    ## Acknowledgements carry no op_id

    Insertion responses are deliberately *not* sequenced: their only effect is to set one
    peer's entry in the acknowledged line's response checklist, which is idempotent, so a
    replayed response is harmless — replay protection for responses is structural rather
    than identifier-based. Forgery is what matters, and the admission authenticator
    blocks it.
  """
  import Syncordian.Line_Object

  # Operation kinds whose messages carry an admission authenticator.
  @wire_kinds [:ins, :del, :ack]
  # All hashing domains: stored signatures, the three wire-tag kinds, and admission.
  @domains [:doc, :adm | @wire_kinds]

  # Single hash entry point: sha256 over the deterministic external term format of a
  # domain-tagged tuple. The domain tag is the first component, so digests from different
  # domains can never coincide on equal field tuples (domain separation), and the tuple
  # encoding keeps field boundaries explicit (injective encoding).
  @spec digest(atom(), tuple()) :: Syncordian.Basic_Types.signature()
  defp digest(domain, fields) when domain in @domains do
    :crypto.hash(:sha256, :erlang.term_to_binary({domain, fields}, [:deterministic]))
    |> Base.encode16()
  end

  @doc """
    Computes a line's *stored signature* σ — its immutable identifier — under the `:doc`
    domain, from the parents' stored signatures, the line's content, and the authoring
    peer id. Set exactly once per line (by the author at creation, or by a receiver from
    the accepted parent pair after the insert wire tag verified) and never recomputed
    when neighbors change; never transmitted. See the module-level invariant.
  """
  @spec create_signature_doc(
          left_parent_signature :: Syncordian.Basic_Types.signature(),
          content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.signature(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_signature_doc(left_parent_signature, content, right_parent_signature, peer_id),
    do: digest(:doc, {left_parent_signature, content, right_parent_signature, peer_id})

  @doc """
    Builds the insert wire tag t_ins under the `:ins` domain, over the same fields as the
    stored signature. The tag travels in the insert broadcast *in place of* the stored
    signature; a receiver that locates a parent pair verifying the tag recomputes σ
    itself from that pair (`create_signature_doc/4`).
  """
  @spec create_tag_insert(
          left_parent_signature :: Syncordian.Basic_Types.signature(),
          content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.signature(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_tag_insert(left_parent_signature, content, right_parent_signature, peer_id),
    do: digest(:ins, {left_parent_signature, content, right_parent_signature, peer_id})

  @doc """
    Verifies an insert wire tag against a candidate parent pair: recomputes t_ins from
    the candidates' stored signatures and the received line's content and author. Up to a
    hash collision exactly one parent pair verifies — the authored one — so every replica
    that accepts the tag (directly or at any offset of the windowed search) accepts the
    same parents and seals the same stored signature. Missing candidates never verify.
  """
  @spec check_tag_insert(
          left_parent :: Syncordian.Line_Object.line() | nil,
          to_check_line :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line() | nil,
          insert_tag :: Syncordian.Basic_Types.signature()
        ) :: boolean()
  def check_tag_insert(nil, _to_check_line, _right_parent, _insert_tag), do: false
  def check_tag_insert(_left_parent, _to_check_line, nil, _insert_tag), do: false

  def check_tag_insert(left_parent, to_check_line, right_parent, insert_tag) do
    insert_tag ==
      create_tag_insert(
        get_signature(left_parent),
        get_content(to_check_line),
        get_signature(right_parent),
        get_line_peer_id(to_check_line)
      )
  end

  @doc """
    Builds the delete authorization tag t_del under the `:del` domain, binding the
    *target* line's stored signature. The tag is a derived, transient value: computed at
    delete origin, carried in the delete message, never stored on any line. Because it
    depends only on the target's immutable σ — never on neighbor structure — delete
    verification is intrinsic: a present target either verifies the tag or the message is
    forged, and no wait can change the outcome.
  """
  @spec create_tag_delete(target_signature :: Syncordian.Basic_Types.signature()) ::
          Syncordian.Basic_Types.signature()
  def create_tag_delete(target_signature), do: digest(:del, {target_signature})

  @doc """
    Verifies a delete authorization tag against the target line found in the local
    document. A missing target never verifies (the caller suspends on the line's arrival
    instead).
  """
  @spec check_tag_delete(
          delete_tag :: Syncordian.Basic_Types.signature(),
          target_line :: Syncordian.Line_Object.line() | nil
        ) :: boolean()
  def check_tag_delete(_delete_tag, nil), do: false

  def check_tag_delete(delete_tag, target_line),
    do: delete_tag == create_tag_delete(get_signature(target_line))

  @doc """
    Builds the response (acknowledgement) tag t_ack under the `:ack` domain, binding the
    acknowledged line's stored signature and the acknowledging peer id. The boundary
    secret does not enter this tag; it enters the response's admission authenticator
    (`create_admission/3`), exactly as for every other message kind. Responses carry no
    op_id: their effect is idempotent, so replay protection for them is structural (see
    the module doc).
  """
  @spec create_tag_ack(
          line_signature :: Syncordian.Basic_Types.signature(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_tag_ack(line_signature, peer_id), do: digest(:ack, {line_signature, peer_id})

  @doc """
    Checks a response tag against the acknowledged line's stored signature and the
    claimed acknowledging peer. Returns false for a tag bound to a different line or
    peer, so a captured response cannot be repurposed to acknowledge anything else.
  """
  @spec check_tag_ack(
          ack_tag :: Syncordian.Basic_Types.signature(),
          line_signature :: Syncordian.Basic_Types.signature(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: boolean()
  def check_tag_ack(ack_tag, line_signature, peer_id),
    do: ack_tag == create_tag_ack(line_signature, peer_id)

  @doc """
    Builds the admission authenticator α(m) under the `:adm` domain: a hash keyed by the
    boundary secret {κ⊥, κ⊤} over the message kind and its full payload. Two messages
    with the same authenticator are identical terms, so α binds every field a message
    carries — including the op_id of inserts and deletes. Only holders of the boundary
    secret can produce or check it; a receiver verifies α before doing anything else with
    a message and silently drops failures (neither applied nor buffered).
  """
  @spec create_admission(
          boundary_signatures :: {
            Syncordian.Basic_Types.signature(),
            Syncordian.Basic_Types.signature()
          },
          kind :: :ins | :del | :ack,
          payload :: term()
        ) :: Syncordian.Basic_Types.signature()
  def create_admission({infimum_signature, supremum_signature}, kind, payload)
      when kind in @wire_kinds,
      do: digest(:adm, {infimum_signature, kind, payload, supremum_signature})

  @doc """
    Checks a message's admission authenticator against the local boundary secret, the
    expected message kind, and the payload as received. Any tampering — a forged wire
    tag, a changed op_id, content, position, or claimed author — invalidates it, as does
    producing it without the boundary secret.
  """
  @spec check_admission(
          alpha :: Syncordian.Basic_Types.signature(),
          boundary_signatures :: {
            Syncordian.Basic_Types.signature(),
            Syncordian.Basic_Types.signature()
          },
          kind :: :ins | :del | :ack,
          payload :: term()
        ) :: boolean()
  def check_admission(alpha, boundary_signatures, kind, payload),
    do: alpha == create_admission(boundary_signatures, kind, payload)
end
