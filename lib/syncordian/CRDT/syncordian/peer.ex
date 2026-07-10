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
  import Syncordian.Vector_Clock
  alias Syncordian.PendingOps
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
  # Local edits arriving from the supervisor reference git indices that may not be
  # materialized in this replica yet (the referenced line's insert is still in flight from
  # another peer). Such an edit is re-queued with a small delay — instead of hot-spinning
  # on the peer's own mailbox — and abandoned after a bounded number of retries, the local
  # analogue of the remote path's @dependency_wait_horizon backstop (theo:nostarve).
  @local_edit_retry_limit 2_000
  @local_edit_retry_delay_ms 10
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
    local_edits: []
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
            local_edits: list()
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
  # initialized; lB and lE are always present, so the lookup never fails.
  @spec get_boundary_secret(peer()) ::
          {Syncordian.Basic_Types.signature(), Syncordian.Basic_Types.signature()}
  defp get_boundary_secret(peer) do
    document = get_peer_document(peer)
    {get_signature(List.first(document)), get_signature(List.last(document))}
  end

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
  # with the current edit count for staleness reclamation, then reclaims any entry that has
  # exceeded @dependency_wait_horizon edits. Each reclaimed (abandoned) entry bumps the
  # given metadata counter, so the evaluation plots that previously counted
  # counter-exhausted retries now count horizon-abandoned operations instead. Returns the
  # updated peer.
  @spec suspend_operation(
          peer(),
          term(),
          Syncordian.PendingOps.dependency(),
          (Syncordian.Metadata.metadata() -> Syncordian.Metadata.metadata())
        ) :: peer()
  defp suspend_operation(peer, payload, dependency, drop_counter) do
    edit_count = get_edit_count(peer)

    {dropped, pending} =
      get_pending(peer)
      |> PendingOps.suspend(payload, dependency, edit_count)
      |> PendingOps.gc(edit_count, @dependency_wait_horizon)

    metadata =
      Enum.reduce(1..dropped//1, get_metadata(peer), fn _, m -> drop_counter.(m) end)

    peer
    |> then(&update_metadata(metadata, &1))
    |> then(&update_pending(pending, &1))
  end

  # True when the sender's progress vector records edits (from peers other than the
  # sender itself) that this replica has not applied yet — i.e. the sender's causal
  # context is not fully present here, so verification failures may be mere reordering.
  @spec missing_causal_context?(list(), list(), Syncordian.Basic_Types.peer_id()) ::
          boolean()
  defp missing_causal_context?(local_vc, incoming_vc, sender_id) do
    incoming_vc
    |> Enum.with_index()
    |> Enum.any?(fn {incoming_at, j} ->
      j != sender_id and incoming_at > Enum.at(local_vc, j)
    end)
  end

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
      seen_ops: SeenOps.new()
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
    pid
  end

  # This is a private function used to save the pid of the peer in the record.
  @spec save_peer_pid(pid, integer, integer) :: any
  defp save_peer_pid(pid, network_size, peer_id),
    do: send(pid, {:save_pid, {pid, network_size, peer_id}})

  ########################################################################################

  ################################ Peer utility ################################

  @spec save_peer_metadata_edit(peer()) :: peer()
  defp save_peer_metadata_edit(peer) do
    file_prefix = "edit"
    folder = "syncordian/"
    peer_pid = get_peer_pid(peer)
    current_edit = get_edit_count(peer)
    nodes_size = get_document_byte_size(peer)

    peer_up =
      peer
      |> get_metadata()
      |> update_memory_info(peer_pid, nodes_size)
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
  # delay makes sense to be define and then use the perform_broadcast function of the
  # utilities module.
  @spec perform_broadcast_peer(peer(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    # Per-recipient network-jitter range. Defaults to no delay; tests/experiments can widen
    # it (e.g. to force concurrent, same-interval authoring) without a global sleep.
    delay = Application.get_env(:syncordian, :broadcast_delay, 0..0)
    perform_broadcast(peer_pid, message, delay)
  end

  @doc """
    Sends the insertion response (acknowledgement) back to the line's author so it can mark
    the line's response checklist (\ie its \iex{commit_at} projection) for the acknowledging
    peer. The author is located through the global registry by its peer id.

    Like every message, the response carries an admission authenticator keyed by the
    boundary secret, plus a response tag binding the acknowledged line's stored signature
    and the acknowledging peer id (`Syncordian.Byzantine.create_tag_ack/2`). The author
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
    ack_tag = create_tag_ack(get_signature(line), peer_id)
    ack_payload = {line_id, peer_id, ack_tag}
    ack_alpha = create_admission(get_boundary_secret(peer), :ack, ack_payload)
    perform_broadcast_peer(peer, {:receive_confirmation_line_insertion, ack_payload, ack_alpha})

    {document, settled?} = settle_line_if_complete(document, line_id)

    peer =
      document
      |> update_peer_document(peer)
      |> tick_projection_peer_clock(incoming_peer_id)
      |> tick_edit_count()
      |> record_seen(op_id)

    peer =
      if settled?,
        do: get_metadata(peer) |> inc_settle_counter() |> update_metadata(peer),
        else: peer

    # This apply is the only event that can make suspended operations deliverable: the
    # sender's progress-vector component advanced, and a new line is now present. Wake any
    # operations waiting on either, plus the generic progress dependency.
    sender_clock_value = Enum.at(get_peer_vector_clock(peer), incoming_peer_id)

    peer =
      wake_pending(peer, [
        {:clock_advanced, incoming_peer_id, sender_clock_value},
        {:line_added, get_line_id(line)},
        {:clock_now, get_peer_vector_clock(peer)}
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

    # A delete applied: deletes do not advance the vector clock, but re-check the
    # clock-gated waiters anyway (cheap in-buffer comparisons) in case an earlier release
    # was missed. Deletes themselves only ever wait on their target line's arrival: their
    # verification is intrinsic to the target.
    peer = wake_pending(peer, [{:clock_now, get_peer_vector_clock(peer)}])

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
  # parent is `wall` — the document line immediately after gap_left, NOT gap_right: the
  # interval (gap_left, wall) is empty at authoring time, so every authored parent pair of
  # the chain is *adjacent* in this replica's document. Receivers locate an insert's parents
  # by adjacency (direct path) or an L1-clock-bounded window (stash path); authoring against
  # the non-adjacent (gap_left, gap_right) pair — with the still-present superseded lines
  # between them — puts the authored pair beyond both locators and gets the replacement
  # inserts rejected at every other replica while the retraction deletes still apply.
  # Everything still sorts strictly below wall <= gap_right, i.e. left of the
  # higher-priority block, so theo:nonint is unaffected. No existing line's position,
  # signature, or identity is rewritten — the new lines are ordinary authored inserts and
  # the retractions ordinary deletes — so the convergence and signature invariants are
  # untouched (the re-placement is operation issuance, not state mutation, in the sense of
  # sec:formal-intention).
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
        content,
        get_signature(right_parent),
        my_id
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

    current_vector_clock = get_peer_vector_clock(peer)

    send(
      get_peer_pid(peer),
      {:send_insert_broadcast,
       {get_line_id(new_line), content, my_id, insert_tag, current_vector_clock, op_id}}
    )

    peer =
      get_metadata(peer)
      |> inc_replacement_issued_counter()
      |> update_metadata(peer)

    # (2) Retract the superseded line: tombstone locally, broadcast the target-bound delete.
    {del_op_id, peer} = next_op_id(peer)
    document = get_peer_document(peer)
    delete_tag = create_tag_delete(get_signature(old_line))

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

    send(
      get_peer_pid(peer),
      {:send_delete_broadcast, {get_line_id(old_line), delete_tag, del_op_id}}
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
      # validate it by direct lookup, with no windowed search. Deletes carry no
      # vector clock: their deliverability depends only on the target's
      # presence, which transitively inherits the target insert's clock gating.
      delete_tag = create_tag_delete(get_signature(line_deleted))
      {op_id, peer} = next_op_id(peer)
      peer = record_seen(peer, op_id)

      send(
        get_peer_pid(peer),
        {:send_delete_broadcast, {line_deleted_id, delete_tag, op_id}}
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
          content,
          get_signature(right_parent),
          peer_id
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

      current_vector_clock = get_peer_vector_clock(peer)

      send(
        get_peer_pid(peer),
        {:send_insert_broadcast,
         {get_line_id(new_line), content, peer_id, insert_tag, current_vector_clock, op_id}}
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
      # full insert payload — binding every field it carries, op_id included.
      {:send_insert_broadcast, insert_payload} ->
        alpha = create_admission(get_boundary_secret(peer), :ins, insert_payload)
        perform_broadcast_peer(peer, {:receive_insert_broadcast, insert_payload, alpha})
        loop(peer)

      # ✅ Same admission authenticator, under the :del kind, over the delete payload.
      {:send_delete_broadcast, delete_payload} ->
        alpha = create_admission(get_boundary_secret(peer), :del, delete_payload)
        perform_broadcast_peer(peer, {:receive_delete_broadcast, delete_payload, alpha})
        loop(peer)

      # ✅ Receipt of a delete, evaluated in the formal order: admission, replay, then the
      # intrinsic verification predicate. The delete tag binds the target line's stored
      # signature — never its neighbors — so a present target either verifies the tag or
      # the message is forged; no windowed search and no wait can change the outcome.
      {:receive_delete_broadcast, delete_payload = {line_deleted_id, delete_tag, op_id}, alpha} ->
        cond do
          not check_admission(alpha, get_boundary_secret(peer), :del, delete_payload) ->
            # Forged or tampered: without the boundary secret no valid authenticator can
            # be produced, so the message is dropped before any further processing —
            # neither applied nor buffered.
            reject_admission(peer)

          seen_op?(peer, op_id) ->
            # Already applied this delete: drop the duplicate (a replay) without effect.
            reject_replay(peer)

          true ->
            document = get_peer_document(peer)
            target_line = get_document_line_by_line_id(document, line_deleted_id)

            cond do
              target_line == nil ->
                # The target line is not in the document yet: suspend until its insert
                # arrives, instead of busy re-queuing. The full admitted message is
                # re-dispatched verbatim once the dependency is satisfied.
                get_metadata(peer)
                |> inc_requeue_counter
                |> update_metadata(peer)
                |> suspend_operation(
                  {:receive_delete_broadcast, delete_payload, alpha},
                  {:line, line_deleted_id},
                  &inc_delete_requeue_limit_counter/1
                )
                |> loop

              check_tag_delete(delete_tag, target_line) ->
                get_metadata(peer)
                |> inc_delete_valid_counter
                |> update_metadata(peer)
                |> delete_valid_line_to_document_and_loop(document, line_deleted_id, op_id)

              true ->
                # The target is present but the tag does not verify against its stored
                # signature. The check is intrinsic, so this is a forgery that slipped
                # past admission (unreachable for the modeled outsider), not a
                # reordering: reject rather than wait.
                get_metadata(peer)
                |> inc_delete_rejected_counter
                |> update_metadata(peer)
                |> loop
            end
        end

      # ✅ Receipt of an insert, evaluated in the formal order: admission first, then the
      # replay check, then deliverability. Only public fields travel — position, content,
      # author, the insert wire tag, the sender's progress vector, and the op_id. The
      # line's stored signature is NOT among them: each receiver re-derives it locally
      # from the parent pair that verifies the wire tag. Up to a hash collision exactly
      # one pair verifies (the authored one), so every replica — direct path or any
      # window offset — seals the same stored signature without it ever riding a message.
      {:receive_insert_broadcast,
       insert_payload = {line_id, content, incoming_peer_id, insert_tag, incoming_vc, op_id},
       alpha} ->
        cond do
          not check_admission(alpha, get_boundary_secret(peer), :ins, insert_payload) ->
            # Forged or tampered: without the boundary secret no valid authenticator can
            # be produced, so the message is dropped before any further processing —
            # neither applied nor buffered.
            reject_admission(peer)

          seen_op?(peer, op_id) ->
            # Already applied this insert: drop the duplicate (a replay) without effect.
            reject_replay(peer)

          true ->
            # Local reconstruction of the line from the wire fields, with a placeholder
            # stored signature: the placeholder is never stored — both accept paths seal
            # the locally computed signature before the line enters the document.
            provisional_line =
              create_line_from_wire(line_id, content, incoming_peer_id, length(incoming_vc))

            local_vector_clock = get_peer_vector_clock(peer)

            clock_distance_usual =
              distance_between_vector_clocks(
                local_vector_clock,
                incoming_vc,
                incoming_peer_id
              )

            clock_distance =
              if clock_distance_usual == 0 do
                projection_distance(local_vector_clock, incoming_vc)
              else
                clock_distance_usual
              end

            case {clock_distance > 1, clock_distance == 1} do
              {true, _} ->
                # The insert is not deliverable yet (progress-vector distance > 1). Rather
                # than busy re-queuing it to ourselves until a fixed counter expires,
                # suspend it against the event that would make it deliverable. The full
                # admitted message is re-dispatched verbatim once that event is observed.
                incoming_at = Enum.at(incoming_vc, incoming_peer_id)
                local_at = Enum.at(local_vector_clock, incoming_peer_id)

                dependency =
                  if incoming_at > local_at + 1 do
                    # The sender is genuinely ahead on its own component: wait until we
                    # have applied the sender's immediately-preceding edit.
                    {:clock, incoming_peer_id, incoming_at - 1}
                  else
                    # The sender's component matches/precedes ours, but the local replica
                    # is behind on other peers' edits (projection distance > 1): wait,
                    # in-buffer, until the local clock dominates the sender's recorded
                    # view. (A blanket re-dispatch-on-every-apply here floods a lagging
                    # peer's mailbox quadratically — each round re-runs the admission
                    # check just to re-suspend.)
                    {:vc_ready, incoming_vc, incoming_peer_id}
                  end

                get_metadata(peer)
                |> inc_insert_distance_greater_than_one
                |> update_metadata(peer)
                |> suspend_operation(
                  {:receive_insert_broadcast, insert_payload, alpha},
                  dependency,
                  &inc_insert_request_limit_counter/1
                )
                |> loop

              {_, true} ->
                # Component-wise vector-clock partial order.
                # True ⇒ local ≤ incoming: incoming is in our future, deliver directly.
                # False ⇒ incoming < local OR concurrent: route to stash so the edit-block
                # protection logic decides how to merge. The previous sum-based comparison
                # misclassified concurrent pairs (e.g. [2,0] vs [0,2]) as ordered.
                order_vc =
                  happens_before_or_equal?(
                    local_vector_clock,
                    incoming_vc
                  )

                document = get_peer_document(peer)

                line_index =
                  get_document_new_index_by_incoming_line_id(provisional_line, document)

                # line_index is a SPLICE index (the right neighbor's position), so the
                # candidate parents are the pair around it — not get_parents_by_index/2,
                # whose git-calibrated append case returns the wrong pair when the right
                # neighbor is the second-to-last line. This matches the stash path, whose
                # nearest candidate pair is exactly this adjacent pair.
                [left_parent, right_parent] = get_splice_parents(document, line_index)

                case order_vc do
                  # local_vc ≤ incoming_vc — deliver
                  true ->
                    valid_line? =
                      check_tag_insert(left_parent, provisional_line, right_parent, insert_tag)

                    case valid_line? do
                      true ->
                        # The wire tag verified against these parents: seal the stored
                        # signature computed from the same pair (:doc domain).
                        # The wire tag verified against this pair, so by the unique-verifier
                        # property it is the authored parent pair: seal the locally computed
                        # stored signature together with the line's op_id and its parents'
                        # op_ids, reconstructable identically at every replica.
                        sealed_line =
                          seal_line_authored(
                            provisional_line,
                            create_signature_doc(
                              get_signature(left_parent),
                              content,
                              get_signature(right_parent),
                              incoming_peer_id
                            ),
                            op_id,
                            get_line_op_id(left_parent),
                            get_line_op_id(right_parent)
                          )

                        get_metadata(peer)
                        |> inc_insert_valid_counter
                        |> update_metadata(peer)
                        |> add_valid_line_to_document_and_loop(
                          sealed_line,
                          incoming_peer_id,
                          op_id
                        )

                      false ->
                        # The wire tag does not verify against the current local
                        # neighbors. local ≤ incoming does NOT mean the authored parents
                        # are present here — it means the SENDER's causal past contains
                        # ours, so the sender may have authored against lines we have not
                        # applied yet. Rejecting in that state permanently stalls the
                        # sender's clock at this replica (head-of-line blocking every
                        # later insert from it). Only when we hold the sender's full
                        # causal context (incoming ≤ local on every other component) is a
                        # mismatch a definite forged/garbled edit; otherwise suspend and
                        # re-evaluate as local applies land, horizon-bounded.
                        if missing_causal_context?(
                             local_vector_clock,
                             incoming_vc,
                             incoming_peer_id
                           ) do
                          suspend_operation(
                            peer,
                            {:receive_insert_broadcast, insert_payload, alpha},
                            {:vc_ready, incoming_vc, incoming_peer_id},
                            &inc_insert_request_limit_counter/1
                          )
                          |> loop
                        else
                          # Terminal drop of an admitted insert: this gaps the sender's
                          # sequence at this replica forever (every later op of that
                          # sender head-of-line blocks on the missing clock tick), so it
                          # must be loud.
                          debug_print(
                            "insert TERMINAL DROP (direct path)",
                            %{
                              op_id: op_id,
                              local_vc: local_vector_clock,
                              incoming_vc: incoming_vc,
                              line_index: line_index
                            }
                          )

                          get_metadata(peer)
                          |> inc_insert_request_counter
                          |> update_metadata(peer)
                          |> loop
                        end
                    end

                  # local_vc > incoming_vc
                  false ->
                    {valid_line?, {stash_left_parent, stash_right_parent}} =
                      stash_document_lines_insert(
                        document,
                        provisional_line,
                        local_vector_clock,
                        incoming_vc,
                        insert_tag
                      )

                    case valid_line? do
                      true ->
                        # The windowed search located the authored parent pair: seal the
                        # stored signature from it, exactly as on the direct path.
                        # Same seal as the direct path: the windowed search located the
                        # authored pair (unique verifier), so its op_ids are this line's
                        # authored parents.
                        sealed_line =
                          seal_line_authored(
                            provisional_line,
                            create_signature_doc(
                              get_signature(stash_left_parent),
                              content,
                              get_signature(stash_right_parent),
                              incoming_peer_id
                            ),
                            op_id,
                            get_line_op_id(stash_left_parent),
                            get_line_op_id(stash_right_parent)
                          )

                        get_metadata(peer)
                        |> inc_insert_stash_counter
                        |> update_metadata(peer)
                        |> add_valid_line_to_document_and_loop(
                          sealed_line,
                          incoming_peer_id,
                          op_id
                        )

                      false ->
                        # Same reasoning as the direct-path mismatch: if the clocks are
                        # concurrent the sender saw lines we still lack, so the windowed
                        # search may simply be missing the authored parents — suspend and
                        # retry on progress. Only a strictly-dominated incoming clock
                        # (we hold everything the sender saw) makes the failure definite.
                        if missing_causal_context?(
                             local_vector_clock,
                             incoming_vc,
                             incoming_peer_id
                           ) do
                          suspend_operation(
                            peer,
                            {:receive_insert_broadcast, insert_payload, alpha},
                            {:vc_ready, incoming_vc, incoming_peer_id},
                            &inc_insert_request_limit_counter/1
                          )
                          |> loop
                        else
                          # Terminal drop of an admitted insert (see the direct-path
                          # drop above): must be loud.
                          debug_print(
                            "insert TERMINAL DROP (stash path)",
                            %{
                              op_id: op_id,
                              local_vc: local_vector_clock,
                              incoming_vc: incoming_vc,
                              window: projection_distance(local_vector_clock, incoming_vc)
                            }
                          )

                          get_metadata(peer)
                          |> inc_insert_stash_fail_counter
                          |> update_metadata(peer)
                          |> loop
                        end
                    end
                end

              {_, _} ->
                IO.puts("Something happen")
                loop(peer)
            end
        end

      # ✅ Not needed in Fugue. Receipt of an insertion response: admission first (the
      # response, like every message, is authenticated by the boundary secret), then the
      # response tag is checked against the acknowledged line's stored signature and the
      # claimed acknowledging peer. Responses carry no op_id — their effect is setting
      # one checklist entry, which is idempotent, so a replayed response is harmless.
      {:receive_confirmation_line_insertion,
       ack_payload = {inserted_line_id, acker_peer_id, ack_tag}, alpha} ->
        if not check_admission(alpha, get_boundary_secret(peer), :ack, ack_payload) do
          # A distrusted node cannot produce a valid authenticator without the boundary
          # secret, so it cannot advance any line's response checklist (the
          # premature-settle attack discussed in the paper).
          reject_admission(peer)
        else
          document = get_peer_document(peer)
          verify = fn line -> check_tag_ack(ack_tag, get_signature(line), acker_peer_id) end

          case apply_ack_to_document(document, inserted_line_id, acker_peer_id, verify) do
            :absent ->
              # Acks are broadcast, so one can outrun the insert it acknowledges. The target
              # line is not present here yet: suspend on its arrival rather than drop, so the
              # checklist still fills once the insert is delivered (the ack deliverability
              # rule of def:deliverable). Released by the {:line_added, _} wake on apply.
              peer
              |> suspend_operation(
                {:receive_confirmation_line_insertion, ack_payload, alpha},
                {:line, inserted_line_id},
                &inc_requeue_counter/1
              )
              |> loop

            {:ok, document, settled?} ->
              # Genuine response: the acking peer is unioned into the line's checklist, and
              # the line settled if every trusted peer has now acknowledged it — one
              # document traversal for the whole step (see apply_ack_to_document/4).
              peer = update_peer_document(document, peer)

              peer =
                if settled?,
                  do: get_metadata(peer) |> inc_settle_counter() |> update_metadata(peer),
                  else: peer

              loop(peer)

            :rejected ->
              # Admitted but stale or mismatched: the tag is bound to a different line or
              # peer (defense in depth behind admission); drop without advancing the
              # checklist.
              get_metadata(peer)
              |> inc_ack_rejected_counter
              |> update_metadata(peer)
              |> loop
          end
        end

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

        send(
          get_peer_supervisor_pid(peer),
          {:receive_metadata_from_peer, updated_memory_metadata, peer_pid}
        )

        update_metadata(updated_memory_metadata, peer)
        |> loop()

      # Diagnostic snapshot of everything that can wedge a replica: the suspended-op
      # buffer, the local-edit FIFO, and the clock. Written on demand by experiment
      # drivers when the network fails to reach a fixpoint.
      {:write_pending_dump} ->
        File.mkdir_p!("debug/documents/syncordian/pending")

        dump = %{
          peer_id: get_peer_id(peer),
          vector_clock: get_peer_vector_clock(peer),
          edit_count: get_edit_count(peer),
          local_edits_queue: get_local_edits(peer),
          pending_ops: get_pending(peer)
        }

        File.write!(
          "debug/documents/syncordian/pending/pending_peer_#{get_peer_id(peer)}",
          inspect(dump, limit: :infinity, printable_limit: :infinity, pretty: true)
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
