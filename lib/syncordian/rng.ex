defmodule Syncordian.Rng do
  @moduledoc """
  The run's randomness, in two forms, because the experiment needs two different kinds of
  determinism.

  ## Seeded process streams

  `seed_process!/2` gives a process a generator that depends only on the run's seed and the
  process's role and identity. Every spawned process seeds itself from the first message it
  receives, which arrives before any other traffic, so no draw is ever made from an unseeded
  generator. This is the right form for a choice that belongs to one process and advances
  with it: the digit a writer picks for a new position, or the peer the supervisor picks to
  compare against the ground truth.

  It is the wrong form for a choice about a message. A process stream advances once per
  draw, so the value a sender assigns to the message it is sending depends on how many
  messages it has sent already, and that depends on the order in which its own inbox
  happened to fill. Two runs of the same seed would then disagree about the network purely
  because the scheduler disagreed with itself.

  ## Derived values

  `derive/2` and its wrappers compute a value from the seed and an arbitrary term, with no
  state at all. The delay of a message becomes a function of the run's seed, the sender, the
  recipient, and the message, so the network a seed describes is the same network every
  time, on a runtime whose scheduling is not repeatable. This is what lets the evaluation
  claim a reproducible experiment without claiming a reproducible scheduler.

  ## Where the two meet

  One decision deliberately uses the process stream rather than derivation: whether the
  environment suppresses a message. A suppression derived from the message alone would
  suppress every retransmission of that message too, since a retransmission is the same
  term, and a link that drops one operation forever is a permanent partition rather than a
  lossy link. Drawing suppression from the sender's stream makes each attempt independent,
  so an operation asked for often enough eventually arrives, which is the condition the
  recovery path is judged under.
  """

  @doc """
  Seeds the calling process's generator from the run's seed, its role, and its identity.

  A no-op for an unseeded run, where the runtime's own seeding applies. Roles are separated
  so that two processes sharing an identifier, a peer and the adversary that shadows it for
  instance, do not draw the same sequence.
  """
  @spec seed_process!(atom(), term()) :: :ok
  def seed_process!(role, id) do
    case Syncordian.Run.seed() do
      nil ->
        :ok

      seed ->
        :rand.seed(:exsss, {seed, :erlang.phash2(role), :erlang.phash2(id)})
        :ok
    end
  end

  @doc """
  A deterministic integer in `0..range-1` from the run's seed and `term`.

  Unseeded runs mix in the virtual machine's start time, so an unseeded run is still varied
  from one launch to the next while remaining self-consistent within a run.
  """
  @spec derive(term(), pos_integer()) :: non_neg_integer()
  def derive(term, range) when range > 0, do: :erlang.phash2({salt(), term}, range)

  @doc "A deterministic integer in `low..high`, inclusive, from the run's seed and `term`."
  @spec uniform(term(), integer(), integer()) :: integer()
  def uniform(_term, low, high) when low >= high, do: low
  def uniform(term, low, high), do: low + derive(term, high - low + 1)

  @doc """
  A deterministic decision at probability `p`, from the run's seed and `term`.

  Resolution is one part in ten thousand, which is finer than any rate the evaluation
  states.
  """
  @spec chance?(term(), float()) :: boolean()
  def chance?(_term, p) when p <= 0.0, do: false
  def chance?(_term, p) when p >= 1.0, do: true
  def chance?(term, p), do: derive(term, 10_000) < round(p * 10_000)

  @doc """
  A decision at probability `p` drawn from the calling process's stream.

  Use this, rather than `chance?/2`, when the same term may be offered more than once and
  the repeated offers have to be independent. Suppression is the only such decision.
  """
  @spec roll?(float()) :: boolean()
  def roll?(p) when p <= 0.0, do: false
  def roll?(p) when p >= 1.0, do: true
  def roll?(p), do: :rand.uniform() < p

  @doc """
  A deterministic hexadecimal token of `length` characters from the run's seed and `term`.

  The adversary's forged tags come from here. They have to be unpredictable to an honest
  peer and reproducible to the experimenter, and they must never be drawn from anything
  that holds the boundary secret.
  """
  @spec token(term(), pos_integer()) :: String.t()
  def token(term, length \\ 10) do
    :crypto.hash(:sha256, :erlang.term_to_binary({salt(), term}))
    |> Base.encode16()
    |> binary_part(0, length)
  end

  defp salt do
    Syncordian.Run.seed() || :erlang.phash2(:erlang.system_info(:start_time))
  end
end
