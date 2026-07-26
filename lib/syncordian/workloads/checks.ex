defmodule Syncordian.Workloads.Checks do
  @moduledoc """
  The properties a controlled workload has to satisfy, each defined once.

  A property that is written twice is a property that can be asserted in one place and quietly
  weakened in another, so the scripts and the test suite call the same functions here. Each one
  answers `:ok` or `{:error, reason}`, and the reason carries the witness rather than a message,
  so a failing run says which line was wrong and not only that something was.

  ## What these check, and what they cannot

  `converged/1` compares the text of every replica byte for byte. It is the weakest property in
  the set and the easiest to satisfy by accident, because replicas that all made the same mistake
  agree with each other. `complete/3` is what stops that: it compares the surviving text against
  the operations the workload actually issued, so a run that converged on a document missing a
  line fails.

  `exercised/1` is the one that keeps the whole suite honest. Its subject is not the document but
  the counters, and it demands that the workload really did construct the interleaving it is named
  after. The reason it exists is that the git replay passes every other property in this module
  while never once running the repair protocol, and a suite that could do the same would report
  soundness it had not tested.
  """

  alias Syncordian.Interleaving
  alias Syncordian.Line_Object
  alias Syncordian.PathId

  @doc """
  A line that is part of the document a reader sees: neither a boundary line nor a tombstone.
  """
  @spec live?(tuple()) :: boolean()
  def live?(line) do
    not PathId.sentinel?(Line_Object.get_line_id(line)) and
      Line_Object.get_line_status(line) != :tombstone
  end

  @doc """
  Every replica holds the same text, byte for byte.

  Answers the shared text, because most of the other properties are statements about it and
  recomputing it per property would allow two of them to disagree about what converged.
  """
  @spec converged(%{optional(term()) => String.t()}) :: {:ok, String.t()} | {:error, term()}
  def converged(contents) when map_size(contents) == 0, do: {:error, :no_replicas}

  def converged(contents) do
    [{reference_peer, reference} | rest] = Enum.sort(contents)

    case Enum.find(rest, fn {_peer, text} -> text != reference end) do
      nil ->
        {:ok, reference}

      {peer, text} ->
        {:error,
         {:diverged, reference_peer, peer, first_difference(lines(reference), lines(text))}}
    end
  end

  @doc """
  The surviving text is exactly what was authored, less what was deleted, counting repeats.

  Counted as a multiset rather than a set, and that is the point of it. A workload in which every
  writer authors the same content can only be checked this way: if three writers each wrote the
  same three lines, the document has to hold nine lines, and a check that compared sets would be
  satisfied by three.
  """
  @spec complete(String.t(), [String.t()], non_neg_integer()) :: :ok | {:error, term()}
  def complete(text, authored, delete_count) do
    expected = tally(authored)
    actual = tally(lines(text))

    extra = difference(actual, expected)
    missing = difference(expected, actual)
    removed = missing |> Map.values() |> Enum.sum()

    cond do
      extra != %{} ->
        {:error, {:unauthored_content, extra}}

      removed != delete_count ->
        {:error,
         {:wrong_number_removed, %{expected: delete_count, removed: removed, which: missing}}}

      true ->
        :ok
    end
  end

  @doc """
  Which authored content is no longer live, worked out from the converged document.

  A deletion in these workloads names a position, not a line, and it is issued while other writers
  are still inserting, so which line it removes is decided when the replica applies it. The harness
  cannot know beforehand: an earlier version read the document just before issuing the delete and
  recorded what it saw, and at eight writers the answer was wrong often enough to fail runs in which
  the protocol had done nothing wrong.

  So the deleted line is derived afterwards rather than predicted. What `complete/3` asserts is
  therefore a count and a containment: every live line was authored by somebody, and exactly as many
  lines are gone as there were deletions. A resurrection or a lost line changes that count.
  """
  @spec removed(String.t(), [String.t()]) :: [String.t()]
  def removed(text, authored) do
    difference(tally(authored), tally(lines(text)))
    |> Enum.flat_map(fn {content, count} -> List.duplicate(content, count) end)
  end

  @doc """
  Each writer's live lines form one unbroken run in the document.

  This is intention preservation as the document can show it: a reader of the converged text sees
  each writer's block whole rather than shuffled through another's.

  It does not hold in the presence of a delete inside a block, and the workloads that delete do
  not assert it. A deletion in the middle of a block leaves the lines after the tombstone anchored
  on a line that is no longer live, so they no longer share an authored interval with the lines
  before it, and the remnant is a second block by the same writer. That is the repair rule working
  as specified, not a violation, so those workloads report contiguity instead of asserting it.
  """
  @spec contiguous(list()) :: :ok | {:error, term()}
  def contiguous(document) do
    runs =
      document
      |> Enum.filter(&Interleaving.live_block_line?/1)
      |> Enum.map(&Line_Object.get_line_peer_id/1)
      |> Enum.chunk_by(& &1)
      |> Enum.map(&hd/1)

    case runs -- Enum.uniq(runs) do
      [] -> :ok
      repeated -> {:error, {:interleaved_writers, Enum.uniq(repeated), runs}}
    end
  end

  @doc "The writers whose lines form more than one run, with the run order, for reporting."
  @spec contiguity_report(list()) :: %{order: [term()], split: [term()]}
  def contiguity_report(document) do
    runs =
      document
      |> Enum.filter(&Interleaving.live_block_line?/1)
      |> Enum.map(&Line_Object.get_line_peer_id/1)
      |> Enum.chunk_by(& &1)
      |> Enum.map(&hd/1)

    %{order: runs, split: Enum.uniq(runs -- Enum.uniq(runs))}
  end

  @doc """
  Nothing that was deleted is live anywhere.

  Checked at every replica rather than on the converged text, because a resurrection that only one
  replica performed is still a resurrection, and it would show up as divergence rather than under
  its own name.
  """
  @spec no_resurrection(%{optional(term()) => String.t()}, [String.t()]) :: :ok | {:error, term()}
  def no_resurrection(contents, deleted) do
    revived =
      for {peer, text} <- contents,
          content <- Enum.uniq(deleted),
          content in lines(text),
          do: {peer, content}

    case revived do
      [] -> :ok
      found -> {:error, {:resurrected, found}}
    end
  end

  @doc """
  No line is still waiting to be acknowledged.

  A line at `:aura` has not been acknowledged by every peer. After the network has gone quiet
  there is nothing left to deliver, so a line still at `:aura` is an acknowledgement that was
  lost rather than one that is late.
  """
  @spec no_aura_residue(list()) :: :ok | {:error, term()}
  def no_aura_residue(document) do
    document
    |> Enum.filter(&(Line_Object.get_line_status(&1) == :aura))
    |> case do
      [] -> :ok
      lines -> {:error, {:aura_residue, Enum.map(lines, &Line_Object.get_content/1)}}
    end
  end

  @doc """
  No repair is still owed on this document.

  The detector is a pure function of the document, so a replica that still sees a re-placement to
  make has not finished repairing. Asserted after the network is quiet, where it means the repair
  reached a fixed point rather than that it has not started.
  """
  @spec no_repair_pending(list()) :: :ok | {:error, term()}
  def no_repair_pending(document) do
    case Interleaving.detect_replacements(document) do
      [] -> :ok
      replacements -> {:error, {:repair_pending, length(replacements)}}
    end
  end

  @doc """
  No line is live in two copies at once.

  A move is one operation carrying a link to what it supersedes, not a delete followed by an
  insert, so no replica should ever hold both the old and the new copy of a moved line. The peers
  record the largest number of such pairs they ever saw at one time, and the answer has to be
  none.
  """
  @spec no_live_duplicates(map()) :: :ok | {:error, term()}
  def no_live_duplicates(metadata) do
    case counter(metadata, "live_duplicates_max") do
      0 -> :ok
      n -> {:error, {:live_duplicates, n}}
    end
  end

  @doc """
  The workload constructed the interleaving it is named after, and the repair ran.

  Without this the suite would be able to pass while building nothing. A workload whose writers
  never actually met would converge, would keep every writer's lines contiguous, and would leave
  no line unacknowledged, and it would have tested none of the machinery it claims to. The git
  replay is precisely that case, which is why this check exists.
  """
  @spec exercised(map()) :: :ok | {:error, term()}
  def exercised(metadata) do
    conflicts = counter(metadata, "conflicts_observed")
    replacements = counter(metadata, "replacement_issued_counter")

    if conflicts > 0 and replacements > 0 do
      :ok
    else
      {:error, {:no_conflict_constructed, %{conflicts: conflicts, replacements: replacements}}}
    end
  end

  @doc """
  The replayed messages actually arrived, and the replicas recognised them.

  The counterpart of `exercised/1`, for the one workload whose subject is the environment rather
  than the document. A replay is performed by a distrusted node, and a run configured with an
  adversary profile but no adversary process to carry it out produces no replays at all. Every
  other property of that workload then passes over an execution in which nothing was replayed,
  which would read as evidence that replays are harmless.

  The witness is the honest peers' own count of replayed broadcasts they refused. It rises on both
  paths a replay can take: one that arrives while the operation is still remembered is refused by
  the applied-operation set, and one that arrives after that set has rotated is refused because its
  progress is not ahead of what the replica already holds.
  """
  @spec replayed(map()) :: :ok | {:error, term()}
  def replayed(metadata) do
    case counter(metadata, "replay_rejected_counter") do
      0 -> {:error, :no_replay_observed}
      _ -> :ok
    end
  end

  @doc """
  A replica that fell behind asked for what it had missed, and was answered.

  The workload that needs this suppresses delivery and rebroadcasts nothing, so a replica that
  ends up holding the missing operations can only have asked their origin for them. Without the
  check, a run in which nothing was actually lost would pass and would look like evidence that
  recovery works.
  """
  @spec recovered(map()) :: :ok | {:error, term()}
  def recovered(metadata) do
    asked = counter(metadata, "fetch_request_sent")
    served = counter(metadata, "fetch_served")

    if asked > 0 and served > 0 do
      :ok
    else
      {:error, {:no_recovery, %{requested: asked, served: served}}}
    end
  end

  @doc """
  Runs the properties a plan declares, and answers the ones that failed.

  The plan says which properties it asserts, so the driver and the test suite cannot disagree
  about what a workload is supposed to establish. Convergence is checked for every workload and is
  therefore not part of the declared list.
  """
  @spec run(map(), map()) :: %{optional(atom()) => :ok | {:error, term()}}
  def run(plan, observation) do
    %{contents: contents, documents: documents, metadata: metadata} = observation
    reference_document = documents |> Enum.sort() |> hd() |> elem(1)

    converged = converged(contents)

    text =
      case converged do
        {:ok, value} -> value
        _ -> ""
      end

    declared =
      Map.new(plan.asserts, fn property ->
        {property,
         check(property, %{
           text: text,
           contents: contents,
           document: reference_document,
           metadata: metadata,
           authored: observation.authored,
           deleted: observation.deleted,
           peers: plan.peers
         })}
      end)

    Map.put(declared, :converged, drop_value(converged))
  end

  defp check(:complete, ctx), do: complete(ctx.text, ctx.authored, length(ctx.deleted))
  defp check(:contiguous, ctx), do: contiguous(ctx.document)

  defp check(:no_resurrection, ctx),
    do: no_resurrection(ctx.contents, removed(ctx.text, ctx.authored))

  defp check(:no_aura_residue, ctx), do: no_aura_residue(ctx.document)
  defp check(:no_repair_pending, ctx), do: no_repair_pending(ctx.document)
  defp check(:no_live_duplicates, ctx), do: no_live_duplicates(ctx.metadata)
  defp check(:exercised, ctx), do: exercised(ctx.metadata)
  defp check(:recovered, ctx), do: recovered(ctx.metadata)
  defp check(:replayed, ctx), do: replayed(ctx.metadata)

  @doc """
  How far each replica got with settling, and which lines it is still waiting on.

  Reported rather than asserted, because there is one execution in which it legitimately differs
  between replicas. A replica returning from an outage recovers the operations it missed, since
  those are held in their author's origin log and can be asked for, but not the acknowledgements
  broadcast while it was away, since acknowledgements are not logged and so cannot be asked for.
  Those lines stay at `:aura` at that replica alone, and the checklist says which peer's
  acknowledgement is the one that never arrived.

  The document still converges: every replica shows the same text. What does not converge is the
  settlement state, and a report that quietly averaged the two would be describing a system nobody
  is running.
  """
  @spec settlement_report(%{optional(term()) => list()}) :: %{optional(term()) => map()}
  def settlement_report(documents) do
    Map.new(documents, fn {peer, document} ->
      waiting =
        document
        |> Enum.filter(&(Line_Object.get_line_status(&1) == :aura))
        |> Enum.map(&{Line_Object.get_content(&1), Line_Object.get_commit_at(&1)})

      {peer, %{aura: length(waiting), waiting_on: waiting}}
    end)
  end

  @doc "The failures in a result set, or an empty list when every property held."
  @spec failures(%{optional(atom()) => :ok | {:error, term()}}) :: [{atom(), term()}]
  def failures(results) do
    for {property, {:error, reason}} <- results, do: {property, reason}
  end

  ##########################################################################################
  # Helpers
  ##########################################################################################

  defp drop_value({:ok, _value}), do: :ok
  defp drop_value(other), do: other

  defp lines(text), do: String.split(text, "\n", trim: true)

  defp tally(contents), do: Enum.frequencies(contents)

  # The entries of `left` that `right` does not account for, with the shortfall as the count.
  defp difference(left, right) do
    left
    |> Enum.map(fn {key, count} -> {key, count - Map.get(right, key, 0)} end)
    |> Enum.filter(fn {_key, shortfall} -> shortfall > 0 end)
    |> Map.new()
  end

  defp counter(metadata, field), do: Map.get(metadata, field, 0)

  # The first position at which two replicas' texts part company, which is far more useful in a
  # failure than the two whole documents.
  defp first_difference(left, right) do
    index =
      Enum.find_index(Enum.zip(left, right), fn {a, b} -> a != b end) ||
        min(length(left), length(right))

    %{
      at: index,
      left: Enum.at(left, index),
      right: Enum.at(right, index),
      left_length: length(left),
      right_length: length(right)
    }
  end
end
