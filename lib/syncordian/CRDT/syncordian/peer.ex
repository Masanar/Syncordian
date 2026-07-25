defmodule Syncordian.Peer do
  @moduledoc """
    This module is responsible for the peer structure and the peer operations provides the
    following functions:
    - start(peer_id) : starts a peer with the given peer_id
    - insert(pid,content,index) : inserts a content at the given index
    - info(pid) : prints the document of the peer
    - raw_print(pid) : prints the document of the peer without the peer structure
  """
  # use TypeCheck
  require Record
  import Syncordian.Metadata
  import Syncordian.Info
  import Syncordian.Line
  import Syncordian.Document
  import Syncordian.Byzantine
  import Syncordian.Line_Object
  import Syncordian.Utilities
  alias Syncordian.PendingOps
  alias Syncordian.OpLog
  alias Syncordian.SeenOps
  alias Syncordian.Interleaving
  @delete_limit 10_000
  @peer_metadata_id 7
  # Epoch size, in applied edits, for the bounded replay-protection seen-set
  # (Syncordian.SeenOps). The set keeps two generations and rotates every @seen_ops_epoch
  # edits, so memory is bounded by the distinct operations applied within the last two
  # epochs while any replay observed within that window is still rejected. Sized at the same
  # order as @dependency_wait_horizon: a replayed message is reorder-bounded under reliable
  # eventual delivery, so a window this large catches every in-flight replay.
  @seen_ops_epoch 5_000
  # Liveness backstop for the dependency-based delivery buffer (Syncordian.PendingOps).
  # A suspended operation is reclaimed once the peer has applied this many edits without
  # the operation's dependency arriving. Under reliable eventual delivery with monotone
  # per-sender progress vectors, an honest operation's dependency is satisfied within the
  # in-flight reorder window, so any horizon at least that large never drops an honest
  # operation, while the live buffer stays bounded by @dependency_wait_horizon * peers.
  # This replaces the previous unjustified @max_insertion_attempts constant.
  @dependency_wait_horizon 5_000
  # Anti-entropy soft threshold, in applied edits (Syncordian.PendingOps.sweep/3): a
  # suspended operation whose dependency has not arrived within this many edits triggers a
  # targeted retransmission request to the operation's origin, rather than being discarded.
  # Sized at a fifth of the reorder scale, so an ordinary in-flight reorder is resolved by
  # normal delivery long before a fetch is ever issued. Overridable per run so tests can
  # exercise recovery without pumping thousands of edits.
  @fetch_soft_threshold div(@dependency_wait_horizon, 5)
  # Cadence of the periodic anti-entropy sweep. The soft threshold above is measured in
  # edits (deterministic); this only sets how often the peer checks for due retransmissions.
  @fetch_sweep_interval_ms 100
  # Local edits arriving from the supervisor reference git indices that may not be
  # materialized in this replica yet (the referenced line's insert is still in flight from
  # another peer). Such an edit is re-queued with a small delay — instead of hot-spinning
  # on the peer's own mailbox — and abandoned after a bounded number of retries, the local
  # analogue of the remote path's @dependency_wait_horizon backstop (theo:nostarve).
  @local_edit_retry_limit 2_000
  @local_edit_retry_delay_ms 10
  # Max insertion responses pulled out of the mailbox into one batched apply
  # (process_ack_batch/2). Bounds the latency of a single batch — the peer stays
  # responsive to barrier probes and local edits — while still amortizing the document
  # traversal over the whole queued burst (acks are N-1 per line at every replica, by
  # far the highest-volume message of the system).
  @ack_drain_limit 5_000
  Record.defrecord(:peer,
    peer_id: None,
    document: None,
    pid: None,
    deleted_count: 0,
    deleted_limit: @delete_limit,
    vector_clock: [],
    supervisor_pid: None,
    metadata: Syncordian.Metadata.metadata(),
    edit_count: 0,
    pending: nil,
    # Per-peer monotonic counter for minting operation ids (op_seq), and the bounded set of
    # op_ids already applied, used to reject replays (Syncordian.SeenOps).
    op_seq: 0,
    seen_ops: nil,
    # FIFO of local edits (supervisor git replay) not yet applied. Local edits MUST apply
    # in arrival order: their git indices assume every earlier local edit of the same
    # author already took effect, so an unready head blocks the tail (see
    # drain_local_edits/2).
    local_edits: [],
    # Cached boundary secret {κ⊥, κ⊤} — the sentinels' immutable stored signatures,
    # read once at define-time (see get_boundary_secret/1).
    boundary_secret: nil,
    # Cached broadcast recipient pids. Network membership is static for a run, so the
    # registry is scanned once, lazily on the first broadcast (after every peer has
    # registered), instead of per message (see perform_broadcast_peer/2).
    broadcast_pids: nil,
    # Authored-identity index: op_id -> line_id for every line ever added to the document
    # (the boundary sentinels, local inserts, remote inserts, and re-issued inserts).
    # Entries are never removed, since tombstoned lines stay in the document and keep
    # their stored signature. It is the receiver's identity locator: an incoming insert
    # names its authored parents by op_id and a delete names its target by op_id, and
    # this map resolves each to the local line (see get_line_by_op_id/2).
    op_index: %{},
    # Origin log of this peer's own authored broadcasts (Syncordian.OpLog), keyed by op_id.
    # It lets the peer retransmit any operation it authored, verbatim, when a replica that
    # is missing it asks (the anti-entropy fetch path).
    op_log: nil,
    # Test-only fault injector: the number of inbound insert/delete broadcasts to silently
    # drop before processing, simulating a fair-lossy channel. Always 0 in a real run; set
    # by the recovery tests to force the loss that the fetch path then repairs.
    drop_next_broadcasts: 0
  )

  @type peer ::
          record(:peer,
            peer_id: Syncordian.Basic_Types.peer_id(),
            document: Syncordian.Basic_Types.document(),
            pid: pid(),
            deleted_count: integer(),
            deleted_limit: integer(),
            vector_clock: [integer],
            supervisor_pid: pid(),
            edit_count: integer(),
            pending: Syncordian.PendingOps.t() | nil,
            op_seq: non_neg_integer(),
            seen_ops: Syncordian.SeenOps.t() | nil,
            local_edits: list(),
            boundary_secret:
              {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()} | nil,
            broadcast_pids: [pid()] | nil,
            op_index: %{
              optional(Syncordian.Basic_Types.op_id()) => Syncordian.Basic_Types.line_id()
            },
            op_log: Syncordian.OpLog.t() | nil,
            drop_next_broadcasts: non_neg_integer()
          )

  ############################# Peer Data Structure Interface ############################
  # Getter and setter for the peer structure

  @spec get_edit_count(peer) :: integer()
  def get_edit_count(peer), do: peer(peer, :edit_count)

  @spec tick_edit_count(peer) :: peer
  def tick_edit_count(peer) do
    new_count = get_edit_count(peer) + 1
    peer(peer, edit_count: new_count)
  end

  @spec get_document_byte_size(peer()) :: integer
  def get_document_byte_size(peer) do
    # Size of the document's external term representation. The metadata peer samples
    # this on EVERY applied edit, so it must be cheap: the previous
    # `inspect(limit: :infinity) |> byte_size` built a multi-megabyte string per edit,
    # which alone made that peer lag thousands of messages behind the network.
    :erlang.external_size(get_peer_document(peer))
  end

  @spec get_module_name() :: String.t()
  def get_module_name(), do: "syncordian"

  @spec get_metadata(peer()) :: Syncordian.Metadata.metadata()
  defp get_metadata(peer), do: peer(peer, :metadata)

  @spec update_metadata(Syncordian.Metadata.metadata(), peer()) :: peer()
  defp update_metadata(metadata, peer), do: peer(peer, metadata: metadata)

  @spec get_peer_supervisor_pid(peer()) :: pid()
  defp get_peer_supervisor_pid(peer), do: peer(peer, :supervisor_pid)

  @spec set_peer_supervisor_pid(peer(), pid()) :: peer()
  defp set_peer_supervisor_pid(peer, supervisor_pid),
    do: peer(peer, supervisor_pid: supervisor_pid)

  # This is a private function used to get the pid of the peer.
  @spec get_peer_pid(peer()) :: pid()
  defp get_peer_pid(peer), do: peer(peer, :pid)

  # This is a private function used to get the peer_id of the peer.
  @spec get_peer_id(peer()) :: Syncordian.Basic_Types.peer_id()
  defp get_peer_id(peer), do: peer(peer, :peer_id)

  # This is a private function used to get the document of the peer.
  @spec get_peer_document(peer()) :: Syncordian.Basic_Types.document()
  defp get_peer_document(peer), do: peer(peer, :document)

  # Getter for the current vector clock of the peer
  @spec get_peer_vector_clock(peer()) :: Syncordian.Basic_Types.vector_clock()
  defp get_peer_vector_clock(peer), do: peer(peer, :vector_clock)

  # Getter/setter for the dependency-based delivery buffer (Syncordian.PendingOps).
  @spec get_pending(peer()) :: Syncordian.PendingOps.t()
  defp get_pending(peer), do: peer(peer, :pending)

  @spec update_pending(Syncordian.PendingOps.t(), peer()) :: peer()
  defp update_pending(pending, peer), do: peer(peer, pending: pending)

  # --- Replay protection (Syncordian.SeenOps) ----------------------------------------
  # Allocates the next operation id {peer_id, op_seq} for a locally originated insert or
  # delete, bumping the per-peer sequence counter. The op_id is fixed once here and travels
  # unchanged in the broadcast, so a replayed message carries the same id and is rejected by
  # the receiver's seen-set.
  @spec next_op_id(peer()) :: {Syncordian.Basic_Types.op_id(), peer()}
  defp next_op_id(peer) do
    seq = peer(peer, :op_seq) + 1
    {{get_peer_id(peer), seq}, peer(peer, op_seq: seq)}
  end

  @spec get_seen_ops(peer()) :: SeenOps.t()
  defp get_seen_ops(peer), do: peer(peer, :seen_ops)

  # The document's boundary secret {κ⊥, κ⊤} = {s(lB), s(lE)}: the stored signatures of
  # the document's permanent first and last lines, shared among admitted peers and never
  # put on the wire. It keys the admission authenticator α that every broadcast message
  # (insert, delete, response) carries and that every receiver checks before anything
  # else (Syncordian.Byzantine.create_admission/3). The pair is drawn at random per run
  # by the supervisor and distributed out-of-band to admitted peers
  # (Syncordian.Byzantine.boundary_secret/0), which is how the sentinel signatures were
  # initialized. The sentinels are immutable, so the pair is cached in the peer record
  # at define-time: the previous List.first/List.last lookup walked the whole document
  # on EVERY message sent or received, which dominated large replays.
  @spec get_boundary_secret(peer()) ::
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()}
  defp get_boundary_secret(peer), do: peer(peer, :boundary_secret)

  @spec seen_op?(peer(), Syncordian.Basic_Types.op_id()) :: boolean()
  defp seen_op?(peer, op_id), do: SeenOps.seen?(get_seen_ops(peer), op_id)

  # Records op_id as applied and rotates the bounded seen-set against the current edit count.
  # Called exactly at the point an operation takes effect (insert/delete apply, or local
  # origin), so that an operation that was only suspended — not yet applied — stays
  # processable when its dependency arrives, and a rejected Byzantine copy is never recorded.
  @spec record_seen(peer(), Syncordian.Basic_Types.op_id()) :: peer()
  defp record_seen(peer, op_id) do
    seen =
      get_seen_ops(peer)
      |> SeenOps.record(op_id)
      |> SeenOps.rotate(get_edit_count(peer), @seen_ops_epoch)

    peer(peer, seen_ops: seen)
  end

  # Drops a replayed broadcast: bumps the replay-rejected metadata counter and loops.
  @spec reject_replay(peer()) :: any()
  defp reject_replay(peer) do
    get_metadata(peer)
    |> inc_replay_rejected_counter
    |> update_metadata(peer)
    |> loop()
  end

  # Drops a message that failed admission: its authenticator does not verify against the
  # boundary secret, so it is forged or tampered traffic from a node that does not hold
  # the secret. Per the formal receipt rule the message is neither applied nor buffered;
  # the drop is silent except for the metadata counter.
  @spec reject_admission(peer()) :: any()
  defp reject_admission(peer) do
    get_metadata(peer)
    |> inc_admission_rejected_counter
    |> update_metadata(peer)
    |> loop()
  end

  # Suspends an undeliverable operation against the event it is waiting for, stamping it
  # with the current edit count so the anti-entropy sweep can age it. A suspended operation
  # is never discarded here: a forged operation cannot reach this path (it is rejected at
  # admission), so every suspended entry is a genuine operation whose dependency will
  # arrive by normal delivery or by a retransmission (run_fetch_sweep/1). Returns the
  # updated peer.
  @spec suspend_operation(peer(), term(), Syncordian.PendingOps.dependency()) :: peer()
  defp suspend_operation(peer, payload, dependency) do
    pending =
      get_pending(peer)
      |> PendingOps.suspend(payload, dependency, get_edit_count(peer))

    update_pending(pending, peer)
  end

  # Suspends an admitted insert whose clock gate passed but one authored parent is not
  # present locally yet, keyed by that parent's op_id. It is re-dispatched when a line with
  # that op_id is added (the {:line_added, op_id} event fired on every remote apply). The
  # dependency is on the concrete missing line, regardless of which peer authored it, so an
  # insert whose parents were created by third parties is never admitted early or dropped.
  @spec suspend_insert_on_parent(
          peer(),
          term(),
          Syncordian.Basic_Types.signature(),
          Syncordian.Basic_Types.op_id()
        ) :: any()
  defp suspend_insert_on_parent(peer, insert_payload, alpha, missing_parent_op_id) do
    get_metadata(peer)
    |> inc_requeue_counter
    |> update_metadata(peer)
    |> suspend_operation(
      {:receive_insert_broadcast, insert_payload, alpha},
      {:line, missing_parent_op_id}
    )
    |> loop
  end

  # --- Authored-identity index (op_index) --------------------------------------------
  #
  # The delivery rule, stated once. The progress vector counts *applied inserts* per
  # writer: a writer's own component is its number of authored inserts, and a receiver
  # ticks that component once per insert it applies from the writer. The op_id sequence
  # (op_seq) spans both inserts and deletes but serves only identity and replay, never
  # delivery order. Deliverability is therefore two intrinsic conditions: an insert is
  # deliverable once the writer's preceding insert has been applied (the clock gate) and
  # both of its authored parents are present (the parent gate); a delete is deliverable
  # once its target line is present. Neither gate looks at a clock distance or a stash
  # window; both resolve authored identities through the op_index.

  @spec get_op_index(peer()) :: %{
          optional(Syncordian.Basic_Types.op_id()) => Syncordian.Basic_Types.line_id()
        }
  defp get_op_index(peer), do: peer(peer, :op_index)

  # Records op_id -> line_id for a line just added to the document. Called at every add
  # site (local insert, remote insert, re-issue insert); the sentinels are seeded in
  # define/2. Entries are never removed.
  @spec index_op(peer(), Syncordian.Basic_Types.op_id(), Syncordian.Basic_Types.line_id()) ::
          peer()
  defp index_op(peer, op_id, line_id),
    do: peer(peer, op_index: Map.put(get_op_index(peer), op_id, line_id))

  # Resolves an authored op_id to the local line that carries it, or nil when no such line
  # has been applied here yet (its insert is still in flight). Since op_index entries are
  # never removed and tombstoned lines stay in the document, a hit always resolves to a
  # present line.
  @spec get_line_by_op_id(peer(), Syncordian.Basic_Types.op_id()) ::
          Syncordian.Line_Object.line() | nil
  defp get_line_by_op_id(peer, op_id) do
    case Map.get(get_op_index(peer), op_id) do
      nil -> nil
      line_id -> get_document_line_by_line_id(get_peer_document(peer), line_id)
    end
  end

  # --- Origin log and anti-entropy fetch (Syncordian.OpLog) --------------------------
  #
  # Delivery under a fair-lossy network. A suspended operation is never discarded: a
  # forged operation cannot reach the buffer (it is rejected at admission), so every
  # suspended entry is a genuine operation whose dependency will arrive. When a dependency
  # is delayed past the soft threshold, the waiting replica asks the *origin* of the
  # missing operation to retransmit it. Each peer keeps an origin log of exactly the
  # broadcasts it authored, so it can re-send any of them verbatim; a re-sent copy travels
  # the ordinary receive path, where the replay and duplicate checks make redundancy
  # harmless.

  @spec get_op_log(peer()) :: Syncordian.OpLog.t()
  defp get_op_log(peer), do: peer(peer, :op_log)

  # Records one of this peer's own authored broadcasts in the origin log so it can be
  # retransmitted on request. `message` is the exact broadcast tuple put on the wire.
  @spec record_own_op(peer(), :ins | :del, Syncordian.Basic_Types.op_id(), term()) :: peer()
  defp record_own_op(peer, kind, op_id, message),
    do: peer(peer, op_log: OpLog.put(get_op_log(peer), kind, op_id, message))

  # Periodic anti-entropy sweep. Asks Syncordian.PendingOps which suspended dependencies
  # have waited past the soft threshold, and issues one targeted retransmission request per
  # due dependency to the operation's origin. Runs on a self-scheduled cadence, so it fires
  # even while the peer is only authoring (and not itself suspending) operations.
  @spec run_fetch_sweep(peer()) :: peer()
  defp run_fetch_sweep(peer) do
    {due_deps, pending} =
      PendingOps.sweep(get_pending(peer), get_edit_count(peer), fetch_soft_threshold())

    Enum.reduce(due_deps, update_pending(pending, peer), &issue_fetch(&2, &1))
  end

  # Turns one due dependency into a retransmission request, addressed to the origin peer of
  # the missing operation. A clock gap asks for the writer's inserts of the missing progress
  # ranks; a missing line named by op_id asks for that single operation. A missing line
  # named by position (an acknowledgement waiter) has no known origin, so it is left to
  # normal delivery.
  @spec issue_fetch(peer(), Syncordian.PendingOps.dependency()) :: peer()
  defp issue_fetch(peer, {:clock, writer, needed}) do
    lo = Enum.at(get_peer_vector_clock(peer), writer) + 1
    if lo <= needed, do: send_fetch(peer, writer, {:ops_of, writer, lo, needed}), else: peer
  end

  defp issue_fetch(peer, {:line, {writer, seq}}) when is_integer(writer) and is_integer(seq),
    do: send_fetch(peer, writer, {:op, {writer, seq}})

  defp issue_fetch(peer, {:line, _line_id}), do: peer

  # Sends one admission-authenticated fetch request to the origin `writer` (never to self),
  # and counts it. The request is authenticated exactly like every other message, so a node
  # without the boundary secret cannot ask an origin to retransmit.
  @spec send_fetch(peer(), Syncordian.Basic_Types.peer_id(), term()) :: peer()
  defp send_fetch(peer, writer, want) do
    requester_id = get_peer_id(peer)

    if writer == requester_id do
      peer
    else
      case :global.whereis_name(writer) do
        :undefined ->
          peer

        origin_pid ->
          alpha = create_admission(get_boundary_secret(peer), :fetch, {requester_id, want})
          send(origin_pid, {:fetch_request, requester_id, want, alpha})
          get_metadata(peer) |> inc_fetch_request_sent |> update_metadata(peer)
      end
    end
  end

  # Serves a fetch request from this peer's origin log: the stored broadcasts that answer
  # `want`. Returns the list of verbatim messages to re-send (empty when none are held).
  @spec serve_fetch(peer(), term()) :: [term()]
  defp serve_fetch(peer, {:op, op_id}) do
    case OpLog.get(get_op_log(peer), op_id) do
      nil -> []
      message -> [message]
    end
  end

  defp serve_fetch(peer, {:ops_of, writer, lo, hi}) do
    # The origin only holds its own authored operations, so a well-formed range names this
    # peer as the writer; a mismatched writer is answered with nothing.
    if writer == get_peer_id(peer),
      do: OpLog.range_inserts(get_op_log(peer), lo, hi),
      else: []
  end

  # Test-only fault injector. When armed, silently drops one inbound broadcast (as a lossy
  # channel would) and reports it, so the recovery tests can force the loss the fetch path
  # then repairs. Always disarmed (returns false) in a real run.
  @spec drop_broadcast?(peer()) :: boolean()
  defp drop_broadcast?(peer), do: peer(peer, :drop_next_broadcasts) > 0

  @spec drop_one_broadcast(peer()) :: peer()
  defp drop_one_broadcast(peer),
    do: peer(peer, drop_next_broadcasts: peer(peer, :drop_next_broadcasts) - 1)

  # Releases every operation whose dependency is satisfied by the given apply events and
  # re-dispatches each released payload to the peer's own mailbox. Returns the peer with the
  # trimmed buffer. Called from the apply paths, which are the only points that change
  # deliverability (progress-vector tick and/or document mutation).
  @spec wake_pending(peer(), [Syncordian.PendingOps.event()]) :: peer()
  defp wake_pending(peer, events) do
    peer_pid = get_peer_pid(peer)

    pending =
      Enum.reduce(events, get_pending(peer), fn event, buf ->
        {ready, buf} = PendingOps.release(buf, event)
        Enum.each(ready, &send(peer_pid, &1))
        buf
      end)

    update_pending(pending, peer)
  end

  # This is a private function used to get the number of marked as deleted lines of the
  # document of the peer.
  @spec get_peer_deleted_count(peer()) :: integer
  defp get_peer_deleted_count(peer), do: peer(peer, :deleted_count)

  # This is a private function used whenever an update to the document is needed. It
  # updates the record peer with the new document.
  @spec update_peer_document(Syncordian.Basic_Types.document(), peer()) :: peer()
  defp update_peer_document(document, peer), do: peer(peer, document: document)

  # This is a private function used whenever an update to the pid is needed. It updates
  # the record peer with the new pid.
  @spec update_peer_pid({pid, integer(), Syncordian.Basic_Types.peer_id()}, peer()) :: peer()
  defp update_peer_pid({pid, network_size, peer_id}, peer),
    # TODO: Be careful when using this function the vector clock is always set to 0
    do:
      peer(peer,
        pid: pid,
        vector_clock: List.duplicate(0, network_size),
        peer_id: peer_id
      )

  # This function check is the deleted lines limit has been reached by the peer, in
  # theory this function should trigger the update mechanism of the peer. This feature
  # is not implemented yet. Instead it just prints a message in the console and continues
  # as usual.
  @spec check_deleted_lines_limit(peer()) :: peer()
  defp check_deleted_lines_limit(peer) do
    if get_peer_deleted_count(peer) > @delete_limit do
      # TODO: HERE call the mechanism of broadcast consensus -> update
      IO.puts(" The deleted lines limit has been reached by #{get_peer_id(peer)} ")
    end

    peer
  end

  # This is a private function used to update the deleted count of the peer.
  @spec tick_peer_deleted_count(peer()) :: peer()
  defp tick_peer_deleted_count(peer) do
    new_count = get_peer_deleted_count(peer) + 1

    peer(peer, deleted_count: new_count)
    |> check_deleted_lines_limit
  end

  # This function is used to update the vector clock of the peer, it increments only the
  # value of the peer_id in the vector clock. The tick is done by adding 1 to the value of
  # the peer_id in the vector clock.
  @spec tick_individual_peer_clock(peer()) :: peer()
  defp tick_individual_peer_clock(peer) do
    peer_id = get_peer_id(peer)
    vector_clock = get_peer_vector_clock(peer)
    new_peer_clock_value = Enum.at(vector_clock, peer_id) + 1
    new_vector_clock = update_list_value(vector_clock, peer_id, new_peer_clock_value)
    peer(peer, vector_clock: new_vector_clock)
  end

  # This function is used to update only the specific projection in the vector clock of
  # the local peer, it increments the current projection value by one.
  @spec tick_projection_peer_clock(peer(), integer) :: peer()
  defp tick_projection_peer_clock(peer, projection) do
    local_vector_clock = peer(peer, :vector_clock)
    new_peer_clock_value = Enum.at(local_vector_clock, projection) + 1
    new_vector_clock = update_list_value(local_vector_clock, projection, new_peer_clock_value)
    peer(peer, vector_clock: new_vector_clock)
  end

  # This is a private function used to instance the initial document of the peer within
  # the record peer.
  @spec define(Syncordian.Basic_Types.peer_id(), integer) :: peer()
  defp define(peer_id, network_size) do
    initial_peer_document = [
      create_infimum_line(peer_id, network_size),
      create_supremum_line(peer_id, network_size)
    ]

    peer(
      peer_id: peer_id,
      document: initial_peer_document,
      pending: PendingOps.new(),
      op_log: OpLog.new(),
      seen_ops: SeenOps.new(),
      # Same pair the sentinel lines above were just built from; cached so admission
      # checks never re-walk the document (see get_boundary_secret/1).
      boundary_secret: Syncordian.Byzantine.boundary_secret(),
      # Seed the identity index with the two sentinels ({-1, 0} -> infimum,
      # {-1, 1} -> supremum), so a line authored adjacent to a boundary resolves its
      # boundary parent through the same lookup as any other parent.
      op_index:
        Map.new(initial_peer_document, fn line -> {get_line_op_id(line), get_line_id(line)} end)
    )
  end

  ########################################################################################

  ################################## Peer Loop Interface #################################
  @doc """
    This function prints the whole document as a list of lists by sending a message to the
    loop peer function with the atom :print.
  """
  @spec raw_print(pid) :: any
  def raw_print(pid), do: send(pid, {:print, :document})

  @doc """
    This function prints in console the whole document no matter if the status of the line
    each line of the document is printed in a new line as a string.
  """
  @spec print_content(pid) :: any
  def print_content(pid), do: send(pid, {:print_content, :document})

  @doc """
    This function saves the content of the document of the peer in a file with the name
    document_peer_{peer_id} where peer_id is the id of the peer. The file is saved in the
    debug/documents folder. This function filter the first and last line of the document
    and the lines that are marked as tombstone.
  """
  @spec save_content(pid) :: any
  def save_content(pid), do: send(pid, {:save_content, :document})

  @doc """
    This function is use to delete a line at the given index in the current document of
    the peer by sending a message to the loop peer function. Where:
      - pid: the pid of the peer
      - index_position: the index position of the line to be deleted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.
  """
  @spec delete_line(pid, integer, integer, integer, integer) :: any
  def delete_line(pid, index_position, test_index, global_position, current_delete_ops),
    do:
      send(
        pid,
        {:delete_line, [index_position, test_index, global_position, current_delete_ops]}
      )

  @doc """
    This function inserts a content at the given index and a pid by sending a message to
    the loop peer function. The messages uses the following format:
    {:insert,[content,index, global_position] }
    where:
      - content: the content to be inserted in the peers local document
      - index_position: the index position where the content will be inserted
      - global_position: the global position of the current commit, in other words the
        beginning position of the line in the context lines.

  """
  @spec insert(pid, String.t(), integer, integer, integer, integer) :: any
  def insert(pid, content, index_position, test_index, global_position, current_delete_ops),
    do:
      send(
        pid,
        {:insert, [content, index_position, test_index, global_position, current_delete_ops]}
      )

  @doc """
    This function starts a peer with the given peer_id and registers it in the global
    registry. The returned content is the pid of the peer. The pid is the corresponding
    content of the pid of the spawned process.
  """
  @spec start(Syncordian.Basic_Types.peer_id(), integer) :: pid
  def start(peer_id, network_size) do
    pid = spawn(__MODULE__, :loop, [define(peer_id, network_size)])
    :global.register_name(peer_id, pid)
    save_peer_pid(pid, network_size, peer_id)
    Process.send_after(pid, {:register_supervisor_pid}, 50)
    # First anti-entropy sweep, scheduled after registration so origins are addressable.
    # The handler reschedules itself for the rest of the run.
    Process.send_after(pid, {:fetch_sweep}, 50 + fetch_sweep_interval_ms())
    pid
  end

  # Cadence of the periodic anti-entropy sweep in milliseconds; overridable per run.
  @spec fetch_sweep_interval_ms() :: pos_integer()
  defp fetch_sweep_interval_ms,
    do: Application.get_env(:syncordian, :fetch_sweep_interval_ms, @fetch_sweep_interval_ms)

  # Soft threshold (in applied edits) after which a suspended operation's dependency is
  # (re-)requested from its origin; overridable per run for tests.
  @spec fetch_soft_threshold() :: pos_integer()
  defp fetch_soft_threshold,
    do: Application.get_env(:syncordian, :fetch_soft_threshold, @fetch_soft_threshold)

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer, integer) :: any
  defp save_peer_pid(pid, network_size, peer_id),
    do: send(pid, {:save_pid, {pid, network_size, peer_id}})

  ########################################################################################

  ################################ Peer utility ################################

  # Cadence gate for the metadata peer's per-edit snapshots: sample every Nth applied
  # edit (default 1 = every edit, the historical behavior). At MAINTAINERS scale the
  # per-edit :erlang.external_size(document) plus one file write per edit is real load,
  # so long replays set SYNCORDIAN_EDIT_METADATA_EVERY high (or rely on the
  # supervisor's per-commit collection instead).
  @spec edit_metadata_every() :: pos_integer()
  defp edit_metadata_every do
    case System.get_env("SYNCORDIAN_EDIT_METADATA_EVERY") do
      nil -> 1
      value -> max(String.to_integer(value), 1)
    end
  end

  @spec save_peer_metadata_edit(peer()) :: peer()
  defp save_peer_metadata_edit(peer) do
    if rem(get_edit_count(peer), edit_metadata_every()) == 0 do
      do_save_peer_metadata_edit(peer)
    else
      peer
    end
  end

  @spec do_save_peer_metadata_edit(peer()) :: peer()
  defp do_save_peer_metadata_edit(peer) do
    file_prefix = "edit"
    folder = "syncordian/"
    peer_pid = get_peer_pid(peer)
    current_edit = get_edit_count(peer)
    nodes_size = get_document_byte_size(peer)

    peer_up =
      peer
      |> get_metadata()
      |> update_memory_info(peer_pid, nodes_size)
      |> set_origin_log_bytes(OpLog.byte_size(get_op_log(peer)))
      |> update_metadata(peer)

    # The file write happens off the peer's critical path: this peer saves a metadata
    # snapshot on EVERY edit it applies, and a synchronous write (tens of ms on a synced
    # filesystem) made it lag thousands of messages behind the network — far enough to
    # starve its own local edits out of their retry budget. The record is immutable, so
    # handing it to a throwaway process is safe.
    metadata_snapshot = get_metadata(peer_up)
    spawn(fn -> save_metadata_one_peer(metadata_snapshot, current_edit, folder, file_prefix) end)

    peer_up
  end

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor. This one is define here because here the
  # delay makes sense to be define and then use the broadcast functions of the
  # utilities module.
  #
  # The recipient pid set is resolved once — lazily, on the first broadcast, i.e. after
  # every peer of the run has registered — and cached in the peer record; membership is
  # static per run, and re-scanning the :global registry per message was measurable
  # overhead on the ack storm. Returns the possibly-updated peer: callers must keep it.
  @spec perform_broadcast_peer(peer(), any) :: peer()
  defp perform_broadcast_peer(peer, message) do
    peer = ensure_broadcast_pids(peer)
    # Per-recipient network-jitter range. Defaults to no delay; tests/experiments can widen
    # it (e.g. to force concurrent, same-interval authoring) without a global sleep.
    delay = Application.get_env(:syncordian, :broadcast_delay, 0..0)
    broadcast_to(peer(peer, :broadcast_pids), message, delay)
    peer
  end

  @spec ensure_broadcast_pids(peer()) :: peer()
  defp ensure_broadcast_pids(peer) do
    case peer(peer, :broadcast_pids) do
      nil -> peer(peer, broadcast_pids: broadcast_recipients(get_peer_pid(peer)))
      _ -> peer
    end
  end

  @doc """
    Sends the insertion response (acknowledgement) back to the line's author so it can mark
    the line's response checklist (\ie its \iex{commit_at} projection) for the acknowledging
    peer. The author is located through the global registry by its peer id.

    Like every message, the response carries an admission authenticator keyed by the
    boundary secret, plus a response tag binding the acknowledged line's stored signature
    and the acknowledging peer id (`Syncordian.Byzantine.create_tag_ack/3`). The author
    rejects any response that fails either check, so a distrusted node cannot forge a
    response on behalf of a trusted peer. Responses carry no op_id: their effect is
    idempotent, so a replayed response is harmless by construction.
  """
  @spec send_confirmation_line_insertion(
          author_peer_id :: Syncordian.Basic_Types.peer_id(),
          ack_payload ::
            {Syncordian.Basic_Types.line_id(), Syncordian.Basic_Types.peer_id(),
             Syncordian.Basic_Types.signature()},
          alpha :: Syncordian.Basic_Types.signature()
        ) :: any
  def send_confirmation_line_insertion(author_peer_id, ack_payload, alpha) do
    author_peer_pid = :global.whereis_name(author_peer_id)

    send(
      author_peer_pid,
      {:receive_confirmation_line_insertion, ack_payload, alpha}
    )
  end

  # Pulls every {:receive_confirmation_line_insertion, ...} message already queued in
  # the mailbox (up to `budget`), returning the batch in arrival order. The selective
  # receive leaves every other message untouched and in its original relative order.
  @spec drain_ack_messages(list(), non_neg_integer()) :: list()
  defp drain_ack_messages(acc, 0), do: Enum.reverse(acc)

  defp drain_ack_messages(acc, budget) do
    receive do
      {:receive_confirmation_line_insertion, ack_payload, alpha} ->
        drain_ack_messages([{ack_payload, alpha} | acc], budget - 1)
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Applies a batch of insertion responses with ONE document traversal
  # (Syncordian.Document.apply_acks_to_document/2), preserving the single-response
  # semantics case by case: admission failure → admission_rejected counter (message
  # neither applied nor buffered); target present and tag verifies → acker unioned
  # into the line's checklist, settling iff it became all-true while still :aura
  # (settle counter); target present but tag mismatch → ack_rejected counter; target
  # absent → suspended on {:line, id} for the {:line_added, _} wake, exactly as the
  # single-response path did.
  @spec process_ack_batch(peer(), list()) :: any()
  defp process_ack_batch(peer, acks) do
    secret = get_boundary_secret(peer)

    {admitted_reversed, admission_rejected} =
      Enum.reduce(acks, {[], 0}, fn {payload, alpha}, {admitted, rejected} ->
        if check_admission(alpha, secret, :ack, payload),
          do: {[{payload, alpha} | admitted], rejected},
          else: {admitted, rejected + 1}
      end)

    acks_by_line =
      admitted_reversed
      |> Enum.reverse()
      |> Enum.group_by(fn {{line_id, _acker_peer_id, _ack_tag}, _alpha} -> line_id end)

    {document, %{settled: settled, rejected: tag_rejected, absent: absent}} =
      apply_acks_to_document(get_peer_document(peer), acks_by_line)

    peer =
      get_metadata(peer)
      |> inc_counter_times(admission_rejected, &inc_admission_rejected_counter/1)
      |> inc_counter_times(tag_rejected, &inc_ack_rejected_counter/1)
      |> inc_counter_times(settled, &inc_settle_counter/1)
      |> update_metadata(peer)

    peer = update_peer_document(document, peer)

    absent
    |> Enum.reduce(peer, fn {line_id, entries}, peer_acc ->
      Enum.reduce(entries, peer_acc, fn {payload, alpha}, peer_inner ->
        suspend_operation(
          peer_inner,
          {:receive_confirmation_line_insertion, payload, alpha},
          {:line, line_id}
        )
      end)
    end)
    |> loop()
  end

  @spec inc_counter_times(
          Syncordian.Metadata.metadata(),
          non_neg_integer(),
          (Syncordian.Metadata.metadata() -> Syncordian.Metadata.metadata())
        ) :: Syncordian.Metadata.metadata()
  defp inc_counter_times(metadata, 0, _inc), do: metadata

  defp inc_counter_times(metadata, times, inc),
    do: Enum.reduce(1..times, metadata, fn _, m -> inc.(m) end)

  @spec add_valid_line_to_document_and_loop(
          peer(),
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.peer_id(),
          Syncordian.Basic_Types.op_id()
        ) :: any
  defp add_valid_line_to_document_and_loop(peer, line, incoming_peer_id, op_id) do
    document = get_peer_document(peer)
    peer_id = get_peer_id(peer)

    # This peer now holds the line, so record its own projection in the response checklist
    # before adding it (create_line_from_wire already set the author's projection).
    line = update_line_commit_at(line, peer_id)
    line_id = get_line_id(line)

    case add_line_to_document(line, document) do
      :duplicate ->
        # A redelivery of a line already present (a replay old enough to have been
        # evicted from the bounded seen-set). Per the receipt rule it must be a clean
        # drop: no ack, no clock tick, no edit count, no seen-set record — any of those
        # side effects would perturb the replicas the replay reaches.
        reject_replay(peer)

      {:ok, document} ->
        add_applied_line_and_loop(peer, document, line, line_id, incoming_peer_id, op_id)
    end
  end

  @spec add_applied_line_and_loop(
          peer(),
          Syncordian.Basic_Types.document(),
          Syncordian.Line_Object.line(),
          Syncordian.Basic_Types.line_id(),
          Syncordian.Basic_Types.peer_id(),
          Syncordian.Basic_Types.op_id()
        ) :: any
  defp add_applied_line_and_loop(peer, document, line, line_id, incoming_peer_id, op_id) do
    peer_id = get_peer_id(peer)

    # Acknowledge the insertion to the whole network, not just the author: acks are
    # broadcast so every peer unions this acknowledgement into its own copy's checklist and
    # the line can reach :settled at every replica (the acknowledgement case of def:apply).
    # The response tag binds the line's stored signature — sealed locally, identical to the
    # author's — and our peer id; the admission authenticator proves we hold the boundary
    # secret, so a distrusted node cannot forge a response on our behalf. Broadcast only
    # after the add succeeded, so a duplicate delivery never emits a fresh ack.
    ack_tag = create_tag_ack(get_signature(line), get_line_op_id(line), peer_id)
    ack_payload = {line_id, peer_id, ack_tag}
    ack_alpha = create_admission(get_boundary_secret(peer), :ack, ack_payload)

    peer =
      perform_broadcast_peer(peer, {:receive_confirmation_line_insertion, ack_payload, ack_alpha})

    {document, settled?} = settle_line_if_complete(document, line_id)

    peer =
      document
      |> update_peer_document(peer)
      |> tick_projection_peer_clock(incoming_peer_id)
      |> tick_edit_count()
      |> record_seen(op_id)
      |> index_op(op_id, line_id)

    peer =
      if settled?,
        do: get_metadata(peer) |> inc_settle_counter() |> update_metadata(peer),
        else: peer

    # This apply is the only remote event that can make suspended operations deliverable:
    # the sender's progress-vector component advanced, and a new line is now present. Wake
    # operations waiting on the sender's clock, and on the new line by BOTH its op_id
    # (inserts waiting for this as an authored parent, deletes waiting for this as their
    # target) and its line_id (acknowledgements, which carry no op_id).
    sender_clock_value = Enum.at(get_peer_vector_clock(peer), incoming_peer_id)

    peer =
      wake_pending(peer, [
        {:clock_advanced, incoming_peer_id, sender_clock_value},
        {:line_added, op_id},
        {:line_added, line_id}
      ])

    # This apply may have completed an interleaving between two concurrently authored blocks
    # that share a parent interval. Detection is replica-independent; if this peer is the
    # lower-priority block's writer, it re-issues that block into a disjoint sub-interval
    # (sec:formal-intention, theo:nonint).
    peer = apply_interleaving_replacements(peer)

    peer_ud =
      if peer_id == @peer_metadata_id,
        do: save_peer_metadata_edit(peer),
        else: peer

    loop(peer_ud)
  end

  @spec delete_valid_line_to_document_and_loop(
          peer :: peer(),
          document :: Syncordian.Basic_Types.document(),
          line_deleted_id :: Syncordian.Basic_Types.line_id(),
          op_id :: Syncordian.Basic_Types.op_id()
        ) :: any
  defp delete_valid_line_to_document_and_loop(peer, document, line_deleted_id, op_id) do
    peer_id = get_peer_id(peer)

    # The caller located the target by id in this same document, so the index is present;
    # the nil guard is defense-in-depth against a bad id ever reaching this point — it
    # must not fall through to tombstoning an arbitrary line.
    case get_document_index_by_line_id(document, line_deleted_id) do
      nil ->
        debug_print(
          "delete_valid_line_to_document_and_loop",
          "target line id vanished between lookup and apply"
        )

        loop(peer)

      index_position ->
        do_delete_valid_line(peer, document, index_position, op_id, peer_id)
    end
  end

  @spec do_delete_valid_line(
          peer(),
          Syncordian.Basic_Types.document(),
          integer(),
          Syncordian.Basic_Types.op_id(),
          Syncordian.Basic_Types.peer_id()
        ) :: any
  defp do_delete_valid_line(peer, document, index_position, op_id, peer_id) do
    peer =
      document
      |> update_document_line_status(index_position, :tombstone)
      |> update_document_line_peer_id(index_position, peer_id)
      |> update_peer_document(peer)
      |> tick_edit_count()
      |> record_seen(op_id)

    # A delete adds no line and does not advance the progress vector, so it can make no
    # suspended operation deliverable: nothing to wake. (A delete's own target-presence
    # dependency is satisfied by the target insert's apply, not by another delete.)

    peer_up =
      if peer_id == @peer_metadata_id,
        do: save_peer_metadata_edit(peer),
        else: peer

    tick_peer_deleted_count(peer_up) |> loop()
  end

  # ---- Interleaving re-placement (sec:formal-intention, theo:nonint) -------------------
  # After materializing a remote insert, check whether two distinct-writer blocks now share
  # a parent interval with overlapping positions (def:intention). Detection is
  # replica-independent (a pure function of the converged document), but only the *writer* of
  # the lower-priority block re-issues; every other replica converges through the ordinary
  # inserts and retracting deletes that writer broadcasts. The model's "notify the
  # originator" step is thus realized by each peer detecting locally, with no new message.
  @spec apply_interleaving_replacements(peer()) :: peer()
  defp apply_interleaving_replacements(peer) do
    my_id = get_peer_id(peer)

    get_peer_document(peer)
    |> Interleaving.detect_replacements()
    |> Enum.filter(fn replacement -> replacement.writer == my_id end)
    |> Enum.reduce(peer, fn replacement, peer_acc ->
      reissue_replacement(peer_acc, replacement)
    end)
  end

  # Re-issues the lower-priority block this peer authored as a fresh contiguous chain inside
  # the disjoint sub-interval (gap_left, wall), retracting the superseded lines. The right
  # parent is `wall` — the document line immediately after gap_left, NOT gap_right — so the
  # new chain's positions sort strictly below wall <= gap_right, i.e. left of the
  # higher-priority block, and theo:nonint is unaffected. Each re-issued insert names its
  # authored parents by identity (op_id), which every receiver resolves through its op_index
  # regardless of the parents' current adjacency, so the re-issue is delivered wherever its
  # named parents are present (and suspended on their arrival otherwise). No existing line's
  # position, signature, or identity is rewritten — the new lines are ordinary authored
  # inserts and the retractions ordinary deletes — so the convergence and signature
  # invariants are untouched (the re-placement is operation issuance, not state mutation, in
  # the sense of sec:formal-intention).
  @spec reissue_replacement(peer(), Syncordian.Interleaving.replacement()) :: peer()
  defp reissue_replacement(peer, replacement) do
    %{moving_lines: moving_lines, gap_left: gap_left, wall: wall} = replacement

    peer =
      get_metadata(peer)
      |> inc_conflict_detected_counter()
      |> update_metadata(peer)

    {peer, _last_left} =
      Enum.reduce(moving_lines, {peer, gap_left}, fn old_line, {peer_acc, left_parent} ->
        reissue_one_line(peer_acc, old_line, left_parent, wall)
      end)

    peer
  end

  # Re-issues a single superseded line: (1) a fresh authored insert with the same content
  # between `left_parent` and `right_parent` — new op_id, a new position drawn inside the
  # disjoint gap, and a freshly derived stored signature — broadcast like any insert; (2) a
  # retracting delete of the old line, tombstoned locally and broadcast with its target-bound
  # tag. The new line becomes the left parent of the next link, keeping the re-placed block
  # contiguous.
  @spec reissue_one_line(
          peer(),
          Syncordian.Line_Object.line(),
          Syncordian.Line_Object.line(),
          Syncordian.Line_Object.line()
        ) :: {peer(), Syncordian.Line_Object.line()}
  defp reissue_one_line(peer, old_line, left_parent, right_parent) do
    my_id = get_peer_id(peer)
    content = get_content(old_line)

    # (1) Fresh authored insert in the disjoint sub-interval.
    {op_id, peer} = next_op_id(peer)
    new_line = create_line_between_two_lines(content, left_parent, right_parent, my_id, op_id)

    insert_tag =
      create_tag_insert(
        get_signature(left_parent),
        get_line_op_id(left_parent),
        content,
        get_signature(right_parent),
        get_line_op_id(right_parent),
        my_id,
        op_id,
        get_line_id(new_line)
      )

    # The op_id is fresh, so the add cannot find a duplicate identity; a position-level
    # collision with a distinct line is ordered by the identity tiebreak inside
    # compare_lines/2 and still inserts.
    {:ok, document} = add_line_to_document(new_line, get_peer_document(peer))

    peer =
      document
      |> update_peer_document(peer)
      |> tick_individual_peer_clock()
      |> tick_edit_count()
      |> record_seen(op_id)
      |> index_op(op_id, get_line_id(new_line))

    current_vector_clock = get_peer_vector_clock(peer)

    # The insert names its authored parents by identity: create_line_between_two_lines/5
    # already stored them on new_line (left_parent's and right_parent's op_ids), so
    # receivers locate the same pair and seal the same stored signature.
    send(
      get_peer_pid(peer),
      {:send_insert_broadcast,
       {get_line_id(new_line), content, my_id, insert_tag, current_vector_clock, op_id,
        get_line_parent_left_op_id(new_line), get_line_parent_right_op_id(new_line)}}
    )

    peer =
      get_metadata(peer)
      |> inc_replacement_issued_counter()
      |> update_metadata(peer)

    # (2) Retract the superseded line: tombstone locally, broadcast the target-bound delete.
    {del_op_id, peer} = next_op_id(peer)
    document = get_peer_document(peer)

    delete_tag =
      create_tag_delete(get_signature(old_line), get_line_op_id(old_line), del_op_id)

    peer =
      case get_document_index_by_line_id(document, get_line_id(old_line)) do
        nil ->
          # Defense-in-depth: the superseded line came from this document moments ago;
          # if it is somehow gone there is nothing to retract locally, and broadcasting
          # the delete is still correct (receivers tombstone by target id).
          debug_print("reissue_one_line", "superseded line no longer present")
          peer

        old_index ->
          document
          |> update_document_line_status(old_index, :tombstone)
          |> update_peer_document(peer)
          |> tick_edit_count()
          |> record_seen(del_op_id)
      end

    # The retraction names its target by identity (the superseded line's op_id), with its
    # line_id kept as a position hint.
    send(
      get_peer_pid(peer),
      {:send_delete_broadcast,
       {get_line_op_id(old_line), get_line_id(old_line), delete_tag, del_op_id}}
    )

    {peer, new_line}
  end

  # ---- Local edits (supervisor git replay) ---------------------------------------------
  #
  # Local edits are the replay's ground truth and their git indices are RELATIVE to the
  # author's document after every earlier local edit took effect, so they must apply
  # strictly in arrival order. They therefore go through a per-peer FIFO: only the head
  # is ever attempted, and an unready head (its referenced git index has not materialized
  # locally yet, because earlier commits' remote inserts are still in flight) blocks the
  # tail. A plain per-edit re-queue would let a later edit overtake an unready earlier
  # one — e.g. the insert of a replace pair becomes satisfiable one remote arrival before
  # its delete, inverting the pair and tombstoning a shifted line.
  #
  # Retrying the head uses a *progress-aware* budget: the attempt counter only advances
  # while the peer applies nothing between attempts (tracked through its monotone edit
  # count) and resets whenever the document moved. A slow replica that is still catching
  # up therefore never abandons its own commit; the budget only expires after a fully
  # quiescent window, i.e. the referenced index can never materialize. That stalled case
  # is the local analogue of the remote path's horizon backstop (theo:nostarve): the
  # head is abandoned, counted, and the drain moves on.

  @spec get_local_edits(peer()) :: list()
  defp get_local_edits(peer), do: peer(peer, :local_edits)

  @spec set_local_edits(peer(), list()) :: peer()
  defp set_local_edits(peer, edits), do: peer(peer, local_edits: edits)

  @spec enqueue_local_edit(peer(), tuple()) :: peer()
  defp enqueue_local_edit(peer, edit),
    do: set_local_edits(peer, get_local_edits(peer) ++ [edit])

  # Applies queued local edits head-first until the queue empties or the head is not
  # ready; in the latter case schedules a delayed re-drain carrying the retry state.
  # Returns the peer (callers loop).
  @spec drain_local_edits(peer(), {non_neg_integer(), integer()}) :: peer()
  defp drain_local_edits(peer, retry_state) do
    case get_local_edits(peer) do
      [] ->
        peer

      [edit | rest] ->
        case attempt_local_edit(peer, edit) do
          {:applied, peer} ->
            peer |> set_local_edits(rest) |> drain_local_edits({0, -1})

          :not_ready ->
            retry_or_abandon_head(peer, edit, rest, retry_state)
        end
    end
  end

  @spec retry_or_abandon_head(peer(), tuple(), list(), {non_neg_integer(), integer()}) ::
          peer()
  defp retry_or_abandon_head(peer, edit, rest, {attempts, last_edit_count}) do
    current_edit_count = get_edit_count(peer)
    attempts = if current_edit_count == last_edit_count, do: attempts, else: 0

    if attempts >= @local_edit_retry_limit do
      debug_print(
        "drain_local_edits",
        "abandoning local edit after #{attempts} stalled retries: #{inspect(edit)}"
      )

      drop_counter =
        case edit do
          {:insert, _} -> &inc_insert_request_limit_counter/1
          {:delete_line, _} -> &inc_delete_requeue_limit_counter/1
        end

      get_metadata(peer)
      |> drop_counter.()
      |> update_metadata(peer)
      |> set_local_edits(rest)
      |> drain_local_edits({0, -1})
    else
      Process.send_after(
        get_peer_pid(peer),
        {:drain_local_edits, {attempts + 1, current_edit_count}},
        @local_edit_retry_delay_ms
      )

      peer
    end
  end

  # Attempts one local edit against the current document. Returns {:applied, peer} on
  # success or :not_ready when the referenced git index is not materialized locally yet
  # (never a side effect in that case).
  @spec attempt_local_edit(peer(), tuple()) :: {:applied, peer()} | :not_ready
  defp attempt_local_edit(
         peer,
         {:delete_line, [index_position, test_index, _global_position, _current_delete_ops]}
       ) do
    document = get_peer_document(peer)
    document_len = get_document_length(document)

    git_index_translated =
      if document_len - 1 <= index_position or document_len < 0,
        do: -1,
        else: translate_git_index_to_syncordian_index(document, test_index, 0, 0)

    if git_index_translated == -1 do
      :not_ready
    else
      peer_id = get_peer_id(peer)

      peer =
        document
        |> update_document_line_status(git_index_translated, :tombstone)
        |> update_document_line_peer_id(git_index_translated, peer_id)
        |> update_peer_document(peer)
        |> tick_edit_count()

      peer =
        if peer_id == @peer_metadata_id,
          do: save_peer_metadata_edit(peer),
          else: peer

      line_deleted =
        get_document_line_by_index(document, git_index_translated)

      line_deleted_id = line_deleted |> get_line_id

      # The delete authorization tag binds the target line's stored signature
      # (an intrinsic property of the target), not its neighbors — so receivers
      # validate it by direct lookup, with no windowed search. The message names the
      # target by identity (its op_id), keeping the line_id as a position hint. Deletes
      # carry no vector clock: their deliverability depends only on the target's
      # presence, which transitively inherits the target insert's clock gating.
      # Mint the delete's op_id before building the tag: the tag binds the delete's own
      # identity as well as the target's stored signature and identity.
      {op_id, peer} = next_op_id(peer)
      peer = record_seen(peer, op_id)

      delete_tag =
        create_tag_delete(get_signature(line_deleted), get_line_op_id(line_deleted), op_id)

      send(
        get_peer_pid(peer),
        {:send_delete_broadcast,
         {get_line_op_id(line_deleted), line_deleted_id, delete_tag, op_id}}
      )

      {:applied, tick_peer_deleted_count(peer)}
    end
  end

  defp attempt_local_edit(
         peer,
         {:insert, [content, _index_position, test_index, _global_position, _current_delete_ops]}
       ) do
    document = get_peer_document(peer)
    peer_id = get_peer_id(peer)

    git_index_translated = translate_git_index_to_syncordian_index(document, test_index, 0, 0)

    if git_index_translated == -1 do
      :not_ready
    else
      [left_parent, right_parent] =
        get_parents_by_index(
          document,
          git_index_translated
        )

      # Mint the op_id before creating the line so it records its own authored identity
      # (op_id) and its authored parents' op_ids — the immutable links the interleaving
      # detector walks to reconstruct edit blocks (def:editblock).
      {op_id, peer} = next_op_id(peer)

      new_line =
        create_line_between_two_lines(
          content,
          left_parent,
          right_parent,
          peer_id,
          op_id
        )

      # The line's stored signature never travels: the broadcast carries the insert
      # wire tag instead (same fields, :ins domain), and each receiver re-derives
      # the stored signature locally from the parent pair that verifies the tag.
      insert_tag =
        create_tag_insert(
          get_signature(left_parent),
          get_line_op_id(left_parent),
          content,
          get_signature(right_parent),
          get_line_op_id(right_parent),
          peer_id,
          op_id,
          get_line_id(new_line)
        )

      # The op_id is freshly minted, so the identity-tiebroken add cannot report a
      # duplicate for a local insert.
      {:ok, document} = add_line_to_document(new_line, document)

      peer =
        document
        |> update_peer_document(peer)
        |> tick_individual_peer_clock
        |> tick_edit_count()
        |> record_seen(op_id)
        |> index_op(op_id, get_line_id(new_line))

      current_vector_clock = get_peer_vector_clock(peer)

      # The insert carries its authored parent identities (stored on new_line by
      # create_line_between_two_lines/5), so every receiver locates the same parent pair
      # by identity and seals the same stored signature.
      send(
        get_peer_pid(peer),
        {:send_insert_broadcast,
         {get_line_id(new_line), content, peer_id, insert_tag, current_vector_clock, op_id,
          get_line_parent_left_op_id(new_line), get_line_parent_right_op_id(new_line)}}
      )

      peer =
        if peer_id == @peer_metadata_id,
          do: save_peer_metadata_edit(peer),
          else: peer

      {:applied, peer}
    end
  end

  ########################################################################################

  @doc """
    This function is the main loop of the peer, it receives messages and calls the
    appropriate functions to handle them.
  """
  @spec loop(peer()) :: any
  def loop(peer) do
    receive do
      # ✅ Local edits from the supervisor's git replay enter the per-peer FIFO and are
      # applied strictly in arrival order (see drain_local_edits/2); the drain message is
      # the delayed retry of an unready head, carrying its progress-aware retry state.
      {:delete_line, args} when is_list(args) ->
        peer
        |> enqueue_local_edit({:delete_line, args})
        |> drain_local_edits({0, -1})
        |> loop()

      {:insert, args} when is_list(args) ->
        peer
        |> enqueue_local_edit({:insert, args})
        |> drain_local_edits({0, -1})
        |> loop()

      {:drain_local_edits, retry_state} ->
        peer
        |> drain_local_edits(retry_state)
        |> loop()

      # ✅ Attaches the admission authenticator α, keyed by the boundary secret, over the
      # full insert payload — binding every field it carries, op_id included. The exact
      # broadcast is also recorded in the origin log so this peer can retransmit it verbatim
      # if a replica later reports it missing (op_id is the 6th payload field).
      {:send_insert_broadcast, insert_payload} ->
        alpha = create_admission(get_boundary_secret(peer), :ins, insert_payload)
        message = {:receive_insert_broadcast, insert_payload, alpha}

        peer
        |> record_own_op(:ins, elem(insert_payload, 5), message)
        |> perform_broadcast_peer(message)
        |> loop()

      # ✅ Same admission authenticator, under the :del kind, over the delete payload, and
      # the same origin-log recording (the delete's own op_id is the 4th payload field).
      {:send_delete_broadcast, delete_payload} ->
        alpha = create_admission(get_boundary_secret(peer), :del, delete_payload)
        message = {:receive_delete_broadcast, delete_payload, alpha}

        peer
        |> record_own_op(:del, elem(delete_payload, 3), message)
        |> perform_broadcast_peer(message)
        |> loop()

      # ✅ Periodic anti-entropy sweep: issues a targeted retransmission request for every
      # suspended dependency that has waited past the soft threshold, then reschedules
      # itself. This never discards a suspended operation; it only asks its origin to
      # re-send it.
      {:fetch_sweep} ->
        Process.send_after(get_peer_pid(peer), {:fetch_sweep}, fetch_sweep_interval_ms())

        peer
        |> run_fetch_sweep()
        |> loop()

      # ✅ A retransmission request from a replica that is missing one of this peer's
      # authored operations. Authenticated exactly like every other message: a node without
      # the boundary secret cannot ask an origin to re-send anything. Served copies are the
      # verbatim originals, re-sent point-to-point to the requester, where the replay and
      # duplicate checks absorb any redundancy.
      {:fetch_request, requester_id, want, alpha} ->
        peer =
          if check_admission(alpha, get_boundary_secret(peer), :fetch, {requester_id, want}) do
            messages = serve_fetch(peer, want)

            case :global.whereis_name(requester_id) do
              :undefined -> :ok
              requester_pid -> Enum.each(messages, &send(requester_pid, &1))
            end

            get_metadata(peer)
            |> inc_fetch_served_times(length(messages))
            |> update_metadata(peer)
          else
            get_metadata(peer) |> inc_admission_rejected_counter |> update_metadata(peer)
          end

        loop(peer)

      # ✅ Receipt of a delete, evaluated in the formal order: admission, replay, then the
      # intrinsic verification predicate. The delete names its target by identity
      # (target_op_id), resolved through the op_index; target_line_id is a position hint.
      # The delete tag binds the target line's stored signature — never its neighbors — so
      # a present target either verifies the tag or the message is forged; no windowed
      # search and no wait can change the outcome.
      {:receive_delete_broadcast,
       delete_payload = {target_op_id, _target_line_id, delete_tag, op_id}, alpha} ->
        cond do
          drop_broadcast?(peer) ->
            # Test-only lossy channel: drop this delivery entirely (see drop_broadcast?/1).
            drop_one_broadcast(peer) |> loop()

          not check_admission(alpha, get_boundary_secret(peer), :del, delete_payload) ->
            # Forged or tampered: without the boundary secret no valid authenticator can
            # be produced, so the message is dropped before any further processing —
            # neither applied nor buffered.
            reject_admission(peer)

          seen_op?(peer, op_id) ->
            # Already applied this delete: drop the duplicate (a replay) without effect.
            reject_replay(peer)

          true ->
            target_line = get_line_by_op_id(peer, target_op_id)

            cond do
              target_line == nil ->
                # The target line is not present yet: suspend on its arrival, keyed by the
                # target's authored identity, instead of busy re-queuing. The full admitted
                # message is re-dispatched verbatim once the dependency is satisfied.
                get_metadata(peer)
                |> inc_requeue_counter
                |> update_metadata(peer)
                |> suspend_operation(
                  {:receive_delete_broadcast, delete_payload, alpha},
                  {:line, target_op_id}
                )
                |> loop

              not check_tag_delete(delete_tag, target_line, op_id) ->
                # The target is present but the tag does not verify against its stored
                # signature. The check is intrinsic, so this is a forgery that slipped
                # past admission (unreachable for the modeled outsider), not a
                # reordering: reject rather than wait.
                get_metadata(peer)
                |> inc_delete_rejected_counter
                |> update_metadata(peer)
                |> loop

              is_tombstone?(target_line) ->
                # The target is already tombstoned. A delete is idempotent on line status,
                # so this redelivery (a replay that outlived the seen-set, or a concurrent
                # delete of the same line by another peer) is a strict no-op: record the
                # op_id and drop it, WITHOUT ticking the edit or deleted counters. This
                # closes the post-GC delete-replay asymmetry where a re-applied delete
                # would inflate those counts.
                peer
                |> record_seen(op_id)
                |> then(fn p ->
                  get_metadata(p) |> inc_replay_rejected_counter |> update_metadata(p)
                end)
                |> loop

              true ->
                get_metadata(peer)
                |> inc_delete_valid_counter
                |> update_metadata(peer)
                |> delete_valid_line_to_document_and_loop(
                  get_peer_document(peer),
                  get_line_id(target_line),
                  op_id
                )
            end
        end

      # ✅ Receipt of an insert, evaluated in the formal order: admission, replay, then
      # the two intrinsic deliverability gates. Only public fields travel — position,
      # content, author, the insert wire tag, the sender's progress vector, the op_id, and
      # the op_ids of the two authored parents. The line's stored signature is NOT among
      # them: the receiver locates the authored parent pair by identity through the
      # op_index and re-derives the stored signature from that pair. Up to a hash collision
      # exactly one pair verifies (the authored one), so every replica seals the same
      # stored signature without it ever riding a message.
      {:receive_insert_broadcast,
       insert_payload =
           {line_id, content, incoming_peer_id, insert_tag, incoming_vc, op_id, left_parent_op_id,
            right_parent_op_id}, alpha} ->
        cond do
          drop_broadcast?(peer) ->
            # Test-only lossy channel: drop this delivery entirely (see drop_broadcast?/1).
            drop_one_broadcast(peer) |> loop()

          not check_admission(alpha, get_boundary_secret(peer), :ins, insert_payload) ->
            # Forged or tampered: without the boundary secret no valid authenticator can
            # be produced, so the message is dropped before any further processing —
            # neither applied nor buffered.
            reject_admission(peer)

          seen_op?(peer, op_id) ->
            # Already applied this insert: drop the duplicate (a replay) without effect.
            reject_replay(peer)

          true ->
            local_vector_clock = get_peer_vector_clock(peer)
            incoming_at = Enum.at(incoming_vc, incoming_peer_id)
            local_at = Enum.at(local_vector_clock, incoming_peer_id)

            cond do
              # Clock gate. The sender's own progress-vector component counts the inserts
              # it has authored, and this replica ticks that component once per insert it
              # applies from the sender. The sender's k-th insert (incoming_at == k) is
              # therefore deliverable only once this replica has applied its (k-1)-th
              # (local_at == k-1). If the sender is further ahead, suspend on the arrival
              # of its immediately-preceding insert.
              incoming_at > local_at + 1 ->
                get_metadata(peer)
                |> inc_insert_distance_greater_than_one
                |> update_metadata(peer)
                |> suspend_operation(
                  {:receive_insert_broadcast, insert_payload, alpha},
                  {:clock, incoming_peer_id, incoming_at - 1}
                )
                |> loop

              incoming_at <= local_at ->
                # An insert from this sender at this sequence position has already been
                # applied here: a stale duplicate that outlived the bounded seen-set. Drop
                # it without effect.
                reject_replay(peer)

              true ->
                # Clock gate satisfied (incoming_at == local_at + 1). Parent gate: locate
                # both authored parents by identity. A missing parent is simply not present
                # here yet — its insert (authored by any peer, not only the sender) is still
                # in flight — so suspend on that parent's arrival rather than dropping.
                left_parent = get_line_by_op_id(peer, left_parent_op_id)
                right_parent = get_line_by_op_id(peer, right_parent_op_id)

                cond do
                  left_parent == nil ->
                    suspend_insert_on_parent(peer, insert_payload, alpha, left_parent_op_id)

                  right_parent == nil ->
                    suspend_insert_on_parent(peer, insert_payload, alpha, right_parent_op_id)

                  true ->
                    provisional_line =
                      create_line_from_wire(
                        line_id,
                        content,
                        incoming_peer_id,
                        length(incoming_vc)
                      )

                    if check_tag_insert(
                         left_parent,
                         provisional_line,
                         right_parent,
                         op_id,
                         insert_tag
                       ) do
                      # The wire tag verifies against the located parents. By the
                      # unique-verifier property they are the authored pair, so seal the
                      # stored signature derived from them together with the line's authored
                      # identity (op_id and the two parent op_ids the message carried).
                      sealed_line =
                        seal_line_authored(
                          provisional_line,
                          create_signature_doc(
                            get_signature(left_parent),
                            get_line_op_id(left_parent),
                            content,
                            get_signature(right_parent),
                            get_line_op_id(right_parent),
                            incoming_peer_id,
                            op_id,
                            line_id
                          ),
                          op_id,
                          left_parent_op_id,
                          right_parent_op_id
                        )

                      get_metadata(peer)
                      |> inc_insert_valid_counter
                      |> update_metadata(peer)
                      |> add_valid_line_to_document_and_loop(
                        sealed_line,
                        incoming_peer_id,
                        op_id
                      )
                    else
                      # Both authored parents are present but the wire tag does not verify
                      # against them: a forgery that slipped past admission (unreachable for
                      # the modeled outsider), not a reordering. Reject it. No honest insert
                      # can reach this branch — its parents are located by the very op_ids it
                      # names, and their stored signatures are immutable — so an honest
                      # operation is never dropped here.
                      get_metadata(peer)
                      |> inc_insert_request_counter
                      |> update_metadata(peer)
                      |> loop
                    end
                end
            end
        end

      # ✅ Not needed in Fugue. Receipt of an insertion response: admission first (the
      # response, like every message, is authenticated by the boundary secret), then the
      # response tag is checked against the acknowledged line's stored signature and the
      # claimed acknowledging peer. Responses carry no op_id — their effect is setting
      # one checklist entry, which is idempotent, so a replayed response is harmless.
      #
      # Responses are processed in BATCHES: every response already queued in the mailbox
      # (bounded by @ack_drain_limit) is drained and the burst is applied in a single
      # document traversal (process_ack_batch/2). Responses are the highest-volume
      # message of the system — N-1 per inserted line, at every replica — and a
      # per-message traversal made the response path O(N·D) per line, which froze
      # large-peer-count replays. Batching is protocol-neutral: each response is still
      # admission-checked and tag-verified individually, checklist union is idempotent
      # and commutative so intra-batch order is immaterial, and draining responses ahead
      # of queued non-response messages cannot change any content — a response never
      # edits content, and one whose target insert has not arrived yet is suspended on
      # {:line, id} exactly as before.
      {:receive_confirmation_line_insertion, ack_payload, alpha} ->
        acks = drain_ack_messages([{ack_payload, alpha}], @ack_drain_limit)
        process_ack_batch(peer, acks)

      # ✅
      {:print_content, :document} ->
        print_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      # ✅
      {:save_content, :document} ->
        save_document_content(get_peer_document(peer), peer(peer, :peer_id))
        loop(peer)

      # ✅ Replay barrier probe (supervisor): hash of the materialized document (content
      # of live lines only, tombstones filtered), so the supervisor can hold the next
      # commit until this author's replica byte-matches the git state its edits assumed.
      {:request_content_hash, reply_pid, ref} ->
        hash = :erlang.md5(string_document_content(get_peer_document(peer)))
        send(reply_pid, {:content_hash, ref, hash})
        loop(peer)

      # ✅
      {:request_live_view_document, live_view_pid} ->
        handler_function = fn
          line ->
            Syncordian.Utilities.create_map_live_view_node_document(
              Syncordian.Line_Object.get_content(line),
              Syncordian.Line_Object.get_line_peer_id(line),
              Syncordian.Line_Object.get_line_id(line),
              Syncordian.Line_Object.get_line_status(line),
              Syncordian.Line_Object.get_signature(line),
              Syncordian.Line_Object.get_line_insertion_attempts(line),
              Syncordian.Line_Object.get_commit_at(line)
            )
        end

        send(
          live_view_pid,
          {:receive_live_view_document, get_peer_document(peer), handler_function}
        )

        loop(peer)

      # ✅
      {:save_pid, info} ->
        info
        |> update_peer_pid(peer)
        |> loop

      # ✅
      {:print, _} ->
        IO.inspect(peer)
        loop(peer)

      # ✅
      {:register_supervisor_pid} ->
        supervisor_pid = :global.whereis_name(:supervisor)

        set_peer_supervisor_pid(peer, supervisor_pid)
        |> loop

      # ✅
      {:supervisor_request_metadata} ->
        # THIS IS EXACTLY THE SAME AS IN FUGUE, function?
        peer_pid = get_peer_pid(peer)
        document_size = get_document_byte_size(peer)

        updated_memory_metadata =
          peer
          |> get_metadata()
          |> update_memory_info(peer_pid, document_size)
          |> set_origin_log_bytes(OpLog.byte_size(get_op_log(peer)))

        send(
          get_peer_supervisor_pid(peer),
          {:receive_metadata_from_peer, updated_memory_metadata, peer_pid}
        )

        update_metadata(updated_memory_metadata, peer)
        |> loop()

      # Test-only: arm the lossy-channel fault injector to drop the next `n` inbound
      # broadcasts (see drop_broadcast?/1). Used by the recovery tests.
      {:test_drop_next_broadcasts, n} ->
        peer(peer, drop_next_broadcasts: n) |> loop()

      # Diagnostic snapshot of everything that can wedge a replica: the suspended-op
      # buffer, the local-edit FIFO, and the clock. Written on demand by experiment
      # drivers when the network fails to reach a fixpoint.
      {:write_pending_dump} ->
        File.mkdir_p!("debug/documents/syncordian/pending")

        pending = get_pending(peer)

        summary =
          "peer_id=#{get_peer_id(peer)} edit_count=#{get_edit_count(peer)} " <>
            "pending_ops=#{PendingOps.size(pending)} " <>
            "local_edits=#{length(get_local_edits(peer))}\n"

        dump = %{
          peer_id: get_peer_id(peer),
          vector_clock: get_peer_vector_clock(peer),
          edit_count: get_edit_count(peer),
          local_edits_queue: get_local_edits(peer),
          pending_ops: pending
        }

        # Truncated on purpose: a stalled peer at MAINTAINERS scale holds 10⁴–10⁵
        # suspended ops, and the previous limit: :infinity dump built a
        # multi-hundred-MB string — a wave of those (one per peer) froze the network
        # harder than the stall being diagnosed. The summary line above carries the
        # exact sizes; the truncated inspect shows the oldest entries, which are the
        # diagnostically relevant ones.
        File.write!(
          "debug/documents/syncordian/pending/pending_peer_#{get_peer_id(peer)}",
          summary <> inspect(dump, limit: 1_000, printable_limit: 10_000, pretty: true)
        )

        loop(peer)

      {:write_raw_document} ->
        document = get_peer_document(peer)
        document_str = inspect(document, limit: :infinity, printable_limit: :infinity)
        # |> Enum.map(fn line -> "#{inspect(line)}" end)
        # |> Enum.join("\n")

        file_path = "debug/documents/syncordian/raw/"
        File.write(file_path <> "document", document_str)
        loop(peer)

      test ->
        IO.puts("Wrong message")
        IO.inspect(test)
        loop(peer)
    end
  end
end
