defmodule Syncordian.Byzantine do
  # use TypeCheck

  @moduledoc """
    Cryptographic core of Syncordian's protection against distrusted (outsider) nodes:
    the dual keyed-MAC signature scheme plus the per-message admission authenticator of
    the paper's formal model (the stored-signature definition, the wire tags, and the
    admission authenticator α of the formal-model section).

    ## Keyed MACs and per-domain keys

    Every value the scheme produces is a keyed message authentication code: HMAC-SHA256
    over a canonical encoding of the authenticated fields, under a key that is specific to
    the operation kind. The keys are derived once, from the document's *boundary secret*
    {κ⊥, κ⊤}, by an HKDF-SHA256 key schedule (`derive_keys/1`): one key per domain
    `:doc | :ins | :del | :ack | :adm`, each expanded under its own label so that two
    domains never share a key. Everything the scheme emits is therefore a pseudo-random
    function output under a secret-derived key.

    A line carries exactly **one** *stored signature* σ — its immutable identifier —
    computed once, under the `:doc` key, from immutable inputs and never recomputed
    afterwards:

        σ(line) = mac(:doc, [σ(left), o(left), content, σ(right), o(right), w, o, p])

    where `o(left)`/`o(right)` are the authored parents' op_ids, `w` the writer, `o` the
    line's own op_id, and `p` its position. The stored signature is **never transmitted**:
    the author computes it locally at insertion, and every receiver re-derives it locally
    from the parent pair it accepted (`create_signature_doc/8`). The MAC's unforgeability
    guarantees the insert wire tag admits exactly one parent pair — the authored one — so
    all replicas compute the *same* σ without it ever riding a message. What travels are
    only *wire tags*, MACs of the same fields under keys distinct from `:doc` and distinct
    per operation kind:

        t_ins = mac(:ins, [σ(left), o(left), content, σ(right), o(right), w, o, p])
        t_del = mac(:del, [σ(target), o(target), o_del])
        t_ack = mac(:ack, [σ(target), o(target), acker])

    Because the keys differ, a tag observed on the wire is never itself a stored signature
    and can never be replayed in the place of one — an insert tag cannot pass as a delete
    authorization, nor vice versa — and a traffic-observing outsider learns no stored
    signature, hence nothing about the boundary secret in which every stored signature is
    rooted (the signature-chain and opacity lemma of the formal model). Folding the op_id
    and position into every tag binds each operation to the exact line it acts on.

    ## Admission authenticator

    Every broadcast message additionally carries an admission authenticator

        α(m) = mac(:adm, [kind | payload fields])

    under the `:adm` key derived from the *boundary secret* {κ⊥, κ⊤}, the stored
    signatures of the document's permanent first and last lines, shared out-of-band among
    admitted peers and never put on the wire. A receiver checks α before anything else —
    before the replay/duplicate check, before any per-line verification, and before
    suspending an out-of-order message — and silently drops failures. A node that does not
    hold the boundary secret therefore cannot produce a single message that is applied *or
    buffered*. Since the authenticator covers the full payload, it also binds the `op_id`
    of inserts and deletes; tampering with any field invalidates it.

    The pair κ⊥/κ⊤ is drawn **at the document's inception** as two independent random
    values (`generate_boundary_secret/0`, called by the supervisor at launch) and handed
    to admitted peers out-of-band — here, via `:persistent_term`
    (`install_boundary_secret!/1` / `boundary_secret/0`), which models the out-of-band
    channel: honest peers read it when they build their initial document, while the
    Byzantine simulator (`Syncordian.ByzantinePeer`) never does, per the outsider
    adversary of `def:adversary`. Possession of the pair *is* the admission capability;
    its rotation is an out-of-band concern, discussed in the paper. When no secret has
    been installed (unit tests, ad-hoc peers) a fixed default pair is used so documents
    remain deterministic.

    ## Encoding

    `canonical/1` is a length-prefixed encoding: each field is encoded to bytes and
    concatenated behind a 4-byte big-endian length prefix, so field boundaries are part of
    the encoding and the concatenation ambiguity of naive string interpolation cannot be
    exploited to equate two distinct preimages. No `:erlang.term_to_binary/2` appears in
    the crypto path.

    ## Acknowledgements carry no op_id

    Insertion responses are deliberately *not* sequenced: their only effect is to set one
    peer's entry in the acknowledged line's response checklist, which is idempotent, so a
    replayed response is harmless — replay protection for responses is structural rather
    than identifier-based. Forgery is what matters, and the admission authenticator
    blocks it.
  """
  import Syncordian.Line_Object

  # Out-of-band channel for the boundary secret within this single-VM simulation. The
  # supervisor installs a fresh random pair at launch; honest peers read it when creating
  # their boundary sentinel lines. ByzantinePeer must never read this term — that is the
  # outsider assumption of def:adversary, and what theo:outsider's rejection guarantee
  # rests on.
  @boundary_secret_key {:syncordian, :boundary_secret}
  # Per-domain keys derived from the installed boundary secret, cached beside it so the
  # HKDF schedule runs once per run instead of once per tag.
  @domain_keys_key {:syncordian, :domain_keys}
  # Deterministic fallback used when no secret is installed (unit tests, ad-hoc peers).
  @default_boundary_secret {"Infimum", "Supremum"}

  @doc """
    Draws a fresh document boundary secret {κ⊥, κ⊤}: two independent 256-bit random
    values. Called once per document (experiment run) by the supervisor at launch,
    before any peer is spawned.
  """
  @spec generate_boundary_secret() ::
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()}
  def generate_boundary_secret do
    {random_secret(), random_secret()}
  end

  defp random_secret, do: :crypto.strong_rand_bytes(32) |> Base.encode16()

  @doc """
    Publishes the boundary secret to the admitted peers (the out-of-band distribution of
    the model, realized as a `:persistent_term` within this VM). Also derives and caches
    the per-domain key schedule so the HKDF expansion runs once per run. Idempotent per
    run.
  """
  @spec install_boundary_secret!(
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()}
        ) :: :ok
  def install_boundary_secret!({infimum_secret, supremum_secret} = secret) do
    :persistent_term.put(@boundary_secret_key, {infimum_secret, supremum_secret})
    :persistent_term.put(@domain_keys_key, derive_keys(secret))
  end

  @doc """
    The boundary secret {κ⊥, κ⊤} as seen by an admitted peer: the installed per-run pair,
    or the deterministic default when none was installed. Only honest peers may call this
    — the Byzantine simulator models an outsider that does not hold the secret.
  """
  @spec boundary_secret() ::
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()}
  def boundary_secret do
    :persistent_term.get(@boundary_secret_key, @default_boundary_secret)
  end

  # Operation kinds whose messages carry an admission authenticator.
  @wire_kinds [:ins, :del, :ack]
  # All keying domains: stored signatures, the three wire-tag kinds, and admission.
  @domains [:doc, :adm | @wire_kinds]

  ##########################################################################################
  # Key schedule (HKDF-SHA256, RFC 5869). OTP provides HMAC but not HKDF, so the extract
  # and expand steps are spelled out. A single 32-byte output block per domain suffices,
  # so expand needs only one HMAC per domain.
  ##########################################################################################

  @hkdf_salt "syncordian-hkdf-v1"

  # Derives one key per domain from the boundary secret. Extract folds the two boundary
  # values into a pseudo-random key (PRK); expand stretches the PRK into one independent
  # key per domain label, so distinct domains never share a key.
  @spec derive_keys({
          Syncordian.Basic_Types.signature(),
          Syncordian.Basic_Types.signature()
        }) :: %{atom() => binary()}
  defp derive_keys({infimum_secret, supremum_secret}) do
    prk = :crypto.mac(:hmac, :sha256, @hkdf_salt, infimum_secret <> supremum_secret)
    Map.new(@domains, fn domain -> {domain, hkdf_expand(prk, domain)} end)
  end

  defp hkdf_expand(prk, domain) do
    :crypto.mac(:hmac, :sha256, prk, <<"syncordian:", Atom.to_string(domain)::binary, 1>>)
  end

  # The key for a domain: the cached schedule of the installed secret, or a schedule
  # derived from the default pair when none is installed (unit tests, ad-hoc peers). The
  # default derivation is only reached before a run installs its secret.
  @spec domain_key(atom()) :: binary()
  defp domain_key(domain) when domain in @domains do
    case :persistent_term.get(@domain_keys_key, nil) do
      nil -> derive_keys(@default_boundary_secret) |> Map.fetch!(domain)
      keys -> Map.fetch!(keys, domain)
    end
  end

  ##########################################################################################
  # Keyed MAC and canonical encoding
  ##########################################################################################

  # Single MAC entry point: HMAC-SHA256 under the domain's key over the canonical encoding
  # of the field list. The per-domain key gives domain separation (a tag under one domain
  # is never valid under another), and the canonical encoding keeps field boundaries
  # explicit (injective encoding).
  @spec mac(atom(), [term()]) :: Syncordian.Basic_Types.signature()
  defp mac(domain, fields) when domain in @domains and is_list(fields) do
    :crypto.mac(:hmac, :sha256, domain_key(domain), canonical(fields))
    |> Base.encode16()
  end

  # Same, but keyed by the :adm key of an explicitly supplied boundary secret rather than
  # the installed one. The admission check must validate a message against *a* boundary
  # secret given by the caller (a receiver checks with its own; the forgery tests supply
  # deliberately wrong pairs), so the :adm key is derived from that pair, not the global
  # cache.
  @spec mac_adm(
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()},
          [term()]
        ) :: Syncordian.Basic_Types.signature()
  defp mac_adm(boundary_secret, fields) when is_list(fields) do
    key = derive_keys(boundary_secret) |> Map.fetch!(:adm)

    :crypto.mac(:hmac, :sha256, key, canonical(fields))
    |> Base.encode16()
  end

  # Canonical, length-prefixed encoding of a field list: each field is encoded to bytes and
  # prefixed with its 4-byte big-endian length, then concatenated. Because the length of
  # every field is part of the encoding, distinct field lists never share an encoding, so
  # boundary-shift ambiguities (e.g. ["ab", "c"] vs ["a", "bc"]) are impossible.
  @spec canonical([term()]) :: binary()
  defp canonical(fields) do
    fields
    |> Enum.map(fn field ->
      bytes = encode_field(field)
      [<<byte_size(bytes)::unsigned-big-32>>, bytes]
    end)
    |> IO.iodata_to_binary()
  end

  # One reserved byte per atom drawn from the fixed table (message kinds and the two
  # position sentinels). Atoms are the only fields whose value space is not self-evidently
  # a byte string, so the table pins each to a distinct byte.
  @atom_table %{ins: 1, del: 2, ack: 3, infimum: 4, supremum: 5}

  # Encodes a single field to bytes by its runtime shape. Order matters: the tagged tuples
  # ({:path, _}) are matched before the generic {w, s} op_id tuple.
  @spec encode_field(term()) :: binary()
  defp encode_field(field) when is_binary(field), do: field

  defp encode_field(field) when is_map_key(@atom_table, field),
    do: <<Map.fetch!(@atom_table, field)>>

  # A PathId position: {:path, [{digit, peer_id}, ...]}. Each segment is two signed 64-bit
  # integers; segments are fixed 16-byte blocks, self-delimiting under the outer length
  # prefix.
  defp encode_field({:path, segments}) when is_list(segments) do
    Enum.map_join(segments, fn {digit, peer_id} ->
      <<digit::signed-big-64, peer_id::signed-big-64>>
    end)
  end

  # An op_id {writer, seq}. The writer may be the -1 sentinel of the boundary identities,
  # so both components are encoded signed.
  defp encode_field({writer, seq}) when is_integer(writer) and is_integer(seq),
    do: <<writer::signed-big-64, seq::signed-big-64>>

  # A progress vector: a bare list of non-negative integer components (only reached inside
  # the admission payload). PathIds are :infimum/:supremum atoms or {:path, _} tuples, never
  # a bare list, so a list is unambiguously a vector.
  defp encode_field(field) when is_list(field),
    do: Enum.map_join(field, fn v -> <<v::unsigned-big-64>> end)

  # A peer id (non-negative integer).
  defp encode_field(field) when is_integer(field) and field >= 0,
    do: <<field::unsigned-big-64>>

  ##########################################################################################
  # Stored signature and wire tags
  ##########################################################################################

  @doc """
    Computes a line's *stored signature* σ — its immutable identifier — under the `:doc`
    key, from the parents' stored signatures and op_ids, the line's content, author,
    op_id, and position. Set exactly once per line (by the author at creation, or by a
    receiver from the accepted parent pair after the insert wire tag verified) and never
    recomputed when neighbors change; never transmitted. See the module-level invariant.
  """
  @spec create_signature_doc(
          left_parent_signature :: Syncordian.Basic_Types.signature(),
          left_parent_op_id :: Syncordian.Basic_Types.op_id(),
          content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.signature(),
          right_parent_op_id :: Syncordian.Basic_Types.op_id(),
          peer_id :: Syncordian.Basic_Types.peer_id(),
          op_id :: Syncordian.Basic_Types.op_id(),
          position :: Syncordian.Basic_Types.line_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_signature_doc(sig_l, op_l, content, sig_r, op_r, peer_id, op_id, position),
    do: mac(:doc, [sig_l, op_l, content, sig_r, op_r, peer_id, op_id, position])

  @doc """
    Builds the insert wire tag t_ins under the `:ins` key, over the same fields as the
    stored signature. The tag travels in the insert broadcast *in place of* the stored
    signature; a receiver that locates a parent pair verifying the tag recomputes σ itself
    from that pair (`create_signature_doc/8`).
  """
  @spec create_tag_insert(
          left_parent_signature :: Syncordian.Basic_Types.signature(),
          left_parent_op_id :: Syncordian.Basic_Types.op_id(),
          content :: Syncordian.Basic_Types.content(),
          right_parent_signature :: Syncordian.Basic_Types.signature(),
          right_parent_op_id :: Syncordian.Basic_Types.op_id(),
          peer_id :: Syncordian.Basic_Types.peer_id(),
          op_id :: Syncordian.Basic_Types.op_id(),
          position :: Syncordian.Basic_Types.line_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_tag_insert(sig_l, op_l, content, sig_r, op_r, peer_id, op_id, position),
    do: mac(:ins, [sig_l, op_l, content, sig_r, op_r, peer_id, op_id, position])

  @doc """
    Verifies an insert wire tag against the parent pair a receiver located by identity (the
    op_ids the insert names) and the received line's authored identity (`op_id`, carried by
    the message, and position). Recomputes t_ins from the parents' stored signatures and
    op_ids and the line's fields. Up to a MAC forgery exactly one parent pair verifies — the
    authored one — so every replica seals the same stored signature. A genuine insert always
    verifies, since its parents are resolved by the very op_ids it carries; a mismatch is
    therefore a forgery. Missing candidates never verify.
  """
  @spec check_tag_insert(
          left_parent :: Syncordian.Line_Object.line() | nil,
          to_check_line :: Syncordian.Line_Object.line(),
          right_parent :: Syncordian.Line_Object.line() | nil,
          op_id :: Syncordian.Basic_Types.op_id(),
          insert_tag :: Syncordian.Basic_Types.signature()
        ) :: boolean()
  def check_tag_insert(nil, _to_check_line, _right_parent, _op_id, _insert_tag), do: false
  def check_tag_insert(_left_parent, _to_check_line, nil, _op_id, _insert_tag), do: false

  def check_tag_insert(left_parent, to_check_line, right_parent, op_id, insert_tag) do
    insert_tag ==
      create_tag_insert(
        get_signature(left_parent),
        get_line_op_id(left_parent),
        get_content(to_check_line),
        get_signature(right_parent),
        get_line_op_id(right_parent),
        get_line_peer_id(to_check_line),
        op_id,
        get_line_id(to_check_line)
      )
  end

  @doc """
    Builds the delete authorization tag t_del under the `:del` key, binding the *target*
    line's stored signature and op_id together with the delete's own op_id. The tag is a
    derived, transient value: computed at delete origin, carried in the delete message,
    never stored on any line. Because it depends only on the target's immutable σ and
    identity — never on neighbor structure — delete verification is intrinsic: a present
    target either verifies the tag or the message is forged, and no wait can change the
    outcome.
  """
  @spec create_tag_delete(
          target_signature :: Syncordian.Basic_Types.signature(),
          target_op_id :: Syncordian.Basic_Types.op_id(),
          delete_op_id :: Syncordian.Basic_Types.op_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_tag_delete(target_signature, target_op_id, delete_op_id),
    do: mac(:del, [target_signature, target_op_id, delete_op_id])

  @doc """
    Verifies a delete authorization tag against the target line found in the local
    document and the delete's op_id carried by the message. A missing target never verifies
    (the caller suspends on the line's arrival instead).
  """
  @spec check_tag_delete(
          delete_tag :: Syncordian.Basic_Types.signature(),
          target_line :: Syncordian.Line_Object.line() | nil,
          delete_op_id :: Syncordian.Basic_Types.op_id()
        ) :: boolean()
  def check_tag_delete(_delete_tag, nil, _delete_op_id), do: false

  def check_tag_delete(delete_tag, target_line, delete_op_id),
    do:
      delete_tag ==
        create_tag_delete(get_signature(target_line), get_line_op_id(target_line), delete_op_id)

  @doc """
    Builds the response (acknowledgement) tag t_ack under the `:ack` key, binding the
    acknowledged line's stored signature and op_id and the acknowledging peer id. The
    boundary secret does not key this tag directly; it keys the response's admission
    authenticator (`create_admission/3`), exactly as for every other message kind.
    Responses carry no op_id: their effect is idempotent, so replay protection for them is
    structural (see the module doc).
  """
  @spec create_tag_ack(
          line_signature :: Syncordian.Basic_Types.signature(),
          line_op_id :: Syncordian.Basic_Types.op_id(),
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: Syncordian.Basic_Types.signature()
  def create_tag_ack(line_signature, line_op_id, peer_id),
    do: mac(:ack, [line_signature, line_op_id, peer_id])

  @doc """
    Checks a response tag against the acknowledged line (its stored signature and op_id)
    and the claimed acknowledging peer. Returns false for a tag bound to a different line
    or peer, so a captured response cannot be repurposed to acknowledge anything else.
  """
  @spec check_tag_ack(
          ack_tag :: Syncordian.Basic_Types.signature(),
          line :: Syncordian.Line_Object.line() | nil,
          peer_id :: Syncordian.Basic_Types.peer_id()
        ) :: boolean()
  def check_tag_ack(_ack_tag, nil, _peer_id), do: false

  def check_tag_ack(ack_tag, line, peer_id),
    do: ack_tag == create_tag_ack(get_signature(line), get_line_op_id(line), peer_id)

  @doc """
    Builds the admission authenticator α(m) under the `:adm` key derived from the boundary
    secret {κ⊥, κ⊤}: a MAC over the message kind and its full payload, flattened field by
    field. Two messages with the same authenticator are identical terms, so α binds every
    field a message carries — including the op_id of inserts and deletes. Only holders of
    the boundary secret can produce or check it; a receiver verifies α before doing
    anything else with a message and silently drops failures (neither applied nor
    buffered).
  """
  @spec create_admission(
          boundary_signatures :: {
            Syncordian.Basic_Types.signature(),
            Syncordian.Basic_Types.signature()
          },
          kind :: :ins | :del | :ack,
          payload :: tuple()
        ) :: Syncordian.Basic_Types.signature()
  def create_admission(boundary_secret, kind, payload)
      when kind in @wire_kinds and is_tuple(payload),
      do: mac_adm(boundary_secret, [kind | Tuple.to_list(payload)])

  @doc """
    Checks a message's admission authenticator against the local boundary secret, the
    expected message kind, and the payload as received. Any tampering — a forged wire tag,
    a changed op_id, content, position, or claimed author — invalidates it, as does
    producing it without the boundary secret.
  """
  @spec check_admission(
          alpha :: Syncordian.Basic_Types.signature(),
          boundary_signatures :: {
            Syncordian.Basic_Types.signature(),
            Syncordian.Basic_Types.signature()
          },
          kind :: :ins | :del | :ack,
          payload :: tuple()
        ) :: boolean()
  def check_admission(alpha, boundary_secret, kind, payload),
    do: alpha == create_admission(boundary_secret, kind, payload)
end
