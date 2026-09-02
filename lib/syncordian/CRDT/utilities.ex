defmodule Syncordian.Utilities do
  @moduledoc """
  Utility functions for processing commit sizes and metadata.
  """
  alias Syncordian.Basic_Types
  @debug true
  @type live_view_node_document :: %{
          content: String.t(),
          peer_id: Basic_Types.peer_id(),
          line_id: any(),
          signature: String.t(),
          status: Basic_Types.status(),
          insertion_attempts: integer(),
          commit_at: Basic_Types.commit_list()
        }

  @spec debug_print(String.t(), any()) :: any
  def debug_print(message, content) do
    case @debug do
      true ->
        IO.puts("")
        IO.puts("**********")
        IO.puts("DEBUG----> #{message}")
        IO.inspect(content)
        IO.puts("**********")
        IO.puts("")

      false ->
        :ok
    end
  end

  @doc """
  Function to perform the filtering and broadcast messages to all peers in the network
  except the current peer. or the supervisor.
  """
  @spec perform_broadcast(pid(), any, any) :: any
  def perform_broadcast(pid, message, range) do
    pid
    |> broadcast_recipients()
    |> broadcast_to(message, range)
  end

  @doc """
  Recipient pid list for a broadcast from `sender_pid`: every globally registered
  process except the sender, the supervisor, and the Swoosh mailbox. Network
  membership is static for a whole experiment run (peers register at launch, before
  the first commit is dispatched), so hot senders may resolve this once and reuse it
  with `broadcast_to/3` instead of re-scanning the registry per message
  (`Syncordian.Peer` caches it in its peer record).
  """
  @spec broadcast_recipients(pid()) :: [pid()]
  def broadcast_recipients(sender_pid) do
    supervisor_pid = :global.whereis_name(:supervisor)
    swoosh_pid = :global.whereis_name(Swoosh.Adapters.Local.Storage.Memory)

    :global.registered_names()
    |> Enum.map(&:global.whereis_name/1)
    |> Enum.filter(fn pid ->
      is_pid(pid) and pid != sender_pid and pid != supervisor_pid and pid != swoosh_pid
    end)
  end

  @doc """
  Recipients of a broadcast paired with the identity each one is registered under.

  `Syncordian.Network` decides a message's delivery from the run's seed together with the
  sender, the recipient, and the message, so it needs a name for the recipient that is the
  same in every run. A process identifier is not one: it is assigned by the virtual machine
  and differs between two runs of the same seed. The registry name is the peer's own
  identifier, which is stable, so the pair is resolved once per peer here and kept.
  """
  @spec broadcast_targets(pid()) :: [{pid(), term()}]
  def broadcast_targets(sender_pid) do
    supervisor_pid = :global.whereis_name(:supervisor)
    swoosh_pid = :global.whereis_name(Swoosh.Adapters.Local.Storage.Memory)

    :global.registered_names()
    |> Enum.map(fn name -> {:global.whereis_name(name), name} end)
    |> Enum.filter(fn {pid, _name} ->
      is_pid(pid) and pid != sender_pid and pid != supervisor_pid and pid != swoosh_pid
    end)
  end

  @doc """
  Sends `message` to every pid with an independent per-recipient delay drawn from
  `range` — the network-jitter model. The degenerate `0..0` range short-circuits to a
  plain `send`: `Process.send_after/3` with delay 0 has the same delivery semantics
  but pays timer bookkeeping on every message, which is pure overhead on the ack/insert
  storm paths.

  Every delivery is accounted to the sending process's wire counters
  (`Syncordian.Instrument`), one message per recipient. A broadcast to `n` peers is `n`
  messages on the wire, so the network load a run reports is the load a real deployment
  would carry rather than the number of times the peer called this function. The message is
  serialized once for the measurement, not once per recipient, because every recipient
  receives the same term.
  """
  @spec broadcast_to([pid()], any, any) :: any
  def broadcast_to(pids, message, range) do
    account_broadcast(pids, message)

    case range do
      %Range{first: 0, last: 0} ->
        Enum.each(pids, fn pid -> send(pid, message) end)

      _ ->
        Enum.each(pids, fn pid -> Process.send_after(pid, message, Enum.random(range)) end)
    end
  end

  @spec account_broadcast([pid()], any) :: :ok
  defp account_broadcast([], _message), do: :ok

  defp account_broadcast(pids, message) do
    kind = Syncordian.Instrument.wire_kind(message)
    bytes = :erlang.external_size(message)
    recipients = length(pids)

    Syncordian.Instrument.record_message(kind, bytes * recipients, recipients)
  end

  @spec update_list_value([any()], integer, any) :: [any()]
  def update_list_value([head | tail], index, value),
    do: update_list_value([head | tail], index, value, 0)

  @spec update_list_value([any()], integer, any, integer) :: [any()]
  defp update_list_value([head | tail], index, value, acc) do
    case index == acc do
      true -> [value | tail]
      false -> [head | update_list_value(tail, index, value, acc + 1)]
    end
  end

  def add_element_list_in_given_index(list, 0, new_element),
    do: [hd(list) | [new_element | tl(list)]]

  def add_element_list_in_given_index([head | tail], index, new_element) when index > 0 do
    [head | add_element_list_in_given_index(tail, index - 1, new_element)]
  end

  # def add_element_list_in_given_index(list, index, new_element) do
  #   Enum.concat(Enum.take(list, index + 1), [new_element | Enum.drop(list, index + 1)])
  # end

  def remove_first_and_last([_head | []]), do: []
  def remove_first_and_last([_head | tail]), do: remove_last(tail)

  def remove_last([]), do: []
  def remove_last([_head | []]), do: []
  def remove_last([head | tail]), do: [head | remove_last(tail)]

  def delete_contents(directory) do
    directory
    |> Path.expand()
    |> File.ls!()
    |> Enum.each(fn entry ->
      path = Path.join(directory, entry)

      case File.stat!(path) do
        %File.Stat{type: :directory} ->
          # Recursively call delete_contents for subdirectories
          delete_contents(path)

        %File.Stat{type: :regular} ->
          # Delete the file if it is not a .txt file
          unless String.ends_with?(entry, ".txt") do
            File.rm!(path)
          end
      end
    end)
  end

  @doc """
    Terminates all the processes.

    The caller (the supervisor) is killed LAST: it is itself in the registry, and
    exiting mid-enumeration aborted the sweep, leaving every peer after it alive —
    surviving Byzantine peers then kept broadcasting on their timers forever.
  """
  def kill do
    :global.registered_names()
    |> Enum.sort_by(&(&1 == :supervisor))
    |> Enum.each(fn name ->
      case :global.whereis_name(name) do
        :undefined -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end)
  end

  @doc """
    Function to get the process memory information returns given a list of process names.
    Returns a list of tuples with the total heap size and the message queue length.
    Overloaded function to get the memory information of a single process.
  """
  def process_memory_info(process_info = [_head | _tail]) do
    process_info
    |> Enum.map(fn x ->
      [memory: s, message_queue_len: m] =
        Process.info(x, [:memory, :message_queue_len])

      [s, m]
    end)
  end

  def process_memory_info(single_process_name) do
    [memory: s, message_queue_len: m] =
      Process.info(single_process_name, [:memory, :message_queue_len])

    [s, m]
  end

  @doc """
  Recursive helper to translate a Git index into the corresponding document/tree index,
  accounting for tombstones elements.

  This function traverses a list of elements (e.g., document lines or tree nodes) and skips
  elements based on the provided predicate `is_tombstone?`. The `target` represents the number
  of non-tombstones elements to skip. As the function traverses the list, it decrements `target`
  and increments the tombstone counter when a tombstone element is encountered. When `target` reaches
  zero, if the current element is not a tombstone it returns the current index; otherwise, it continues
  traversing. If the list is exhausted without finding a valid element, it returns -1.

  Parameters:
    - list: The list of elements to traverse.
    - target: The number of non-tombstones elements to skip.
    - tombstones: The count of tombstones elements encountered so far.
    - index: The current traversal index.
    - is_tombstone?: A function that accepts an element and returns `true` if it is considered tombstone.

  Returns:
    The computed index corresponding to the Git index or -1 if no valid position is found.
  """
  def do_translate_index([], 0, 0, index, _is_tombstone?), do: index - 1
  def do_translate_index([], _target, _tombstones, _index, _is_tombstone?), do: -1

  def do_translate_index([h | t], 0, 0, index, is_tombstone?) do
    if is_tombstone?.(h) do
      do_translate_index(t, 0, 0, index + 1, is_tombstone?)
    else
      index
    end
  end

  def do_translate_index([h | t], target, tombstones, index, is_tombstone?) do
    if is_tombstone?.(h) do
      do_translate_index(t, target - 1, tombstones + 1, index + 1, is_tombstone?)
    else
      do_translate_index(t, target - 1, tombstones, index + 1, is_tombstone?)
    end
  end

  @crdt_ids [:syncordian, :fugue, :treedoc, :logoot]

  @spec identify_peer_module(Syncordian.Basic_Types.crdt_id()) :: module
  def identify_peer_module(crdt_id) do
    case crdt_id do
      :syncordian -> Syncordian.Peer
      :fugue -> Syncordian.CRDT.Fugue.Peer
      :treedoc -> Syncordian.CRDT.Treedoc.Peer
      :logoot -> Syncordian.CRDT.Logoot.Peer
      _ -> Syncordian.Peer
    end
  end

  @doc "The implementations a run may be asked for."
  @spec crdt_ids() :: [Syncordian.Basic_Types.crdt_id()]
  def crdt_ids, do: @crdt_ids

  @doc """
  Reads an implementation name given on a command line.

  `String.to_existing_atom/1` is the wrong tool here and was the cause of a real defect: the atom
  naming an implementation exists only once something has referred to that module, so a driver
  started with `--crdt fugue` failed before it ran, and every baseline comparison was unreachable
  from the command line. Matching against the known list instead both fixes that and refuses an
  unknown name loudly, rather than falling through to Syncordian under someone else's label.
  """
  @spec parse_crdt_id(String.t()) :: Syncordian.Basic_Types.crdt_id()
  def parse_crdt_id(name) when is_binary(name) do
    case Enum.find(@crdt_ids, &(Atom.to_string(&1) == name)) do
      nil ->
        raise ArgumentError,
              "unknown CRDT #{inspect(name)}, expected one of " <>
                Enum.map_join(@crdt_ids, ", ", &Atom.to_string/1)

      crdt_id ->
        crdt_id
    end
  end

  @spec create_map_live_view_node_document(
          String.t(),
          Basic_Types.peer_id(),
          any(),
          Basic_Types.status(),
          String.t(),
          integer(),
          Basic_Types.commit_list()
        ) :: live_view_node_document()
  def create_map_live_view_node_document(
        content,
        peer_id,
        line_id \\ "",
        status \\ nil,
        signature \\ "",
        insertion_attempts \\ 142_857,
        commit_at \\ []
      ) do
    %{
      line_id: line_id,
      content: content,
      signature: signature,
      peer_id: peer_id,
      status: status,
      insertion_attempts: insertion_attempts,
      commit_at: commit_at
    }
  end
end
