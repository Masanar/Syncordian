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
    seen_ops: nil
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
            seen_ops: Syncordian.SeenOps.t() | nil
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
    document = get_peer_document(peer)

    inspect(document, limit: :infinity, printable_limit: :infinity)
    |> byte_size
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
  # else (Syncordian.Byzantine.create_admission/3). In this simulation the pair is the
  # constant sentinel signatures, standing in for per-document random secrets drawn at
  # inception; lB and lE are always present, so the lookup never fails.
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
  @spec check_deleted_lines_limit(peer()) :: any()
  defp check_deleted_lines_limit(peer) do
    if get_peer_deleted_count(peer) > @delete_limit do
      # TODO: HERE call the mechanism of broadcast consensus -> update
      IO.puts(" The deleted lines limit has been reached by #{get_peer_id(peer)} ")
    end

    loop(peer)
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

    get_metadata(peer_up)
    |> save_metadata_one_peer(current_edit, folder, file_prefix)

    peer_up
  end

  # Function to perform the filtering and broadcast messages to all peers in the network
  # except the current peer. or the supervisor. This one is define here because here the
  # delay makes sense to be define and then use the perform_broadcast function of the
  # utilities module.
  @spec perform_broadcast_peer(peer(), any) :: any
  defp perform_broadcast_peer(peer, message) do
    peer_pid = get_peer_pid(peer)
    # delay = 10..30
    delay = 0..0
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

    # Acknowledge the insertion back to the line's author. The response tag binds the
    # line's stored signature — the value this receiver sealed locally, identical to the
    # author's — and our peer id; the admission authenticator proves we hold the boundary
    # secret, so the author can distinguish this genuine response from a forged one.
    ack_tag = create_tag_ack(get_signature(line), peer_id)
    ack_payload = {get_line_id(line), peer_id, ack_tag}
    ack_alpha = create_admission(get_boundary_secret(peer), :ack, ack_payload)

    send_confirmation_line_insertion(incoming_peer_id, ack_payload, ack_alpha)

    peer =
      add_line_to_document(line, document)
      |> update_peer_document(peer)
      |> tick_projection_peer_clock(incoming_peer_id)
      |> tick_edit_count()
      |> record_seen(op_id)

    # This apply is the only event that can make suspended operations deliverable: the
    # sender's progress-vector component advanced, and a new line is now present. Wake any
    # operations waiting on either, plus the generic progress dependency.
    sender_clock_value = Enum.at(get_peer_vector_clock(peer), incoming_peer_id)

    peer =
      wake_pending(peer, [
        {:clock_advanced, incoming_peer_id, sender_clock_value},
        {:line_added, get_line_id(line)},
        :progress
      ])

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
    index_position = get_document_index_by_line_id(document, line_deleted_id)

    peer =
      document
      |> update_document_line_status(index_position, :tombstone)
      |> update_document_line_peer_id(index_position, peer_id)
      |> update_peer_document(peer)
      |> tick_edit_count()
      |> record_seen(op_id)

    # A delete applied: re-evaluate operations suspended on the generic progress
    # dependency (inserts whose projection distance was too large — a delete apply ticks
    # the edit count, so their deliverability may have changed). Deletes themselves only
    # ever wait on their target line's arrival, never on progress: their verification is
    # intrinsic to the target.
    peer = wake_pending(peer, [:progress])

    peer_up =
      if peer_id == @peer_metadata_id,
        do: save_peer_metadata_edit(peer),
        else: peer

    tick_peer_deleted_count(peer_up)
  end

  ########################################################################################

  # TODO: I think that all the functions defined above could be moved into a different
  # modules, the peer module should only contain the loop function and the functions that
  # are used to interact with the loop function. But I am not sure about this.

  @doc """
    This function is the main loop of the peer, it receives messages and calls the
    appropriate functions to handle them.
  """
  @spec loop(peer()) :: any
  def loop(peer) do
    receive do
      # ✅
      {:delete_line, [index_position, test_index, _global_position, _current_delete_ops]} ->
        document = get_peer_document(peer)
        document_len = get_document_length(document)

        case document_len - 1 <= index_position or document_len < 0 do
          true ->
            IO.puts("The to delete line does not exist! ")
            IO.puts("Index position: #{index_position} ")
            IO.puts("Document length: #{document_len}")
            loop(peer)

          _ ->
            peer_id = get_peer_id(peer)

            git_index_translated =
              translate_git_index_to_syncordian_index(document, test_index, 0, 0)

            if git_index_translated == -1 do
              # Due byzantine peers or network issues the line was not inserted in the
              # document of the peer, need to requeue the local delete operation.
              # IO.puts("Line delete line was not found in the document with index: #{test_index}")
              get_peer_pid(peer) |> send({:delete_line, [index_position, test_index, 0, 0]})
              loop(peer)
            else
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

              tick_peer_deleted_count(peer)
            end
        end

      # TODO: Delete the test_index, the global_position and current_delete_ops
      # ✅
      {:insert, [content, _index_position, test_index, _global_position, _current_delete_ops]} ->
        document = get_peer_document(peer)
        peer_id = get_peer_id(peer)

        git_index_translated = translate_git_index_to_syncordian_index(document, test_index, 0, 0)

        if git_index_translated == -1 do
          # Due byzantine peers or network issues the line was not inserted in the
          # document of the peer, need to requeue the local delete operation.
          IO.puts(
            "Un insert llego al peer #{peer_id} con el indice: #{test_index} pero el indice trad es #{git_index_translated}"
          )

          get_peer_pid(peer) |> send({:insert, [content, 0, test_index, 0, 0]})

          loop(peer)
        else
          [left_parent, right_parent] =
            get_parents_by_index(
              document,
              git_index_translated
            )

          new_line =
            create_line_between_two_lines(
              content,
              left_parent,
              right_parent,
              peer_id
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

          peer =
            new_line
            |> add_line_to_document(document)
            |> update_peer_document(peer)
            |> tick_individual_peer_clock
            |> tick_edit_count()

          {op_id, peer} = next_op_id(peer)
          peer = record_seen(peer, op_id)
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

          loop(peer)
        end

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
                    # is behind on other peers' edits (projection distance > 1):
                    # re-evaluate on the next local apply.
                    :progress
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

                [left_parent, right_parent] = get_parents_by_index(document, line_index)

                case order_vc do
                  # local_vc ≤ incoming_vc — deliver
                  true ->
                    valid_line? =
                      check_tag_insert(left_parent, provisional_line, right_parent, insert_tag)

                    case valid_line? do
                      true ->
                        # The wire tag verified against these parents: seal the stored
                        # signature computed from the same pair (:doc domain).
                        sealed_line =
                          seal_line_signature(
                            provisional_line,
                            create_signature_doc(
                              get_signature(left_parent),
                              content,
                              get_signature(right_parent),
                              incoming_peer_id
                            )
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
                        # Deliverable by the progress vector but the wire tag does not
                        # verify against the local neighbors. This is a rejection, not a
                        # wait: under the partial order the relevant predecessors are
                        # already present, so the mismatch indicates a forged/garbled
                        # edit rather than reordering.
                        get_metadata(peer)
                        |> inc_insert_request_counter
                        |> update_metadata(peer)
                        |> loop
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
                        sealed_line =
                          seal_line_signature(
                            provisional_line,
                            create_signature_doc(
                              get_signature(stash_left_parent),
                              content,
                              get_signature(stash_right_parent),
                              incoming_peer_id
                            )
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
                        get_metadata(peer)
                        |> inc_insert_stash_fail_counter
                        |> update_metadata(peer)
                        |> loop
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
          acked_line = get_document_line_by_line_id(document, inserted_line_id)

          authentic? =
            acked_line != nil and
              check_tag_ack(ack_tag, get_signature(acked_line), acker_peer_id)

          if authentic? do
            document
            |> update_document_line_commit_at(inserted_line_id, acker_peer_id)
            |> update_peer_document(peer)
            |> loop
          else
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
