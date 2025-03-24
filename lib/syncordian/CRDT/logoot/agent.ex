defmodule Syncordian.CRDT.Logoot.Agent do
  @moduledoc """
  A simplified structure for Logoot Agent, focusing only on setters and getters.
  Concurrency will be handled externally, similar to the Fugue implementation.
  """

  alias Syncordian.CRDT.Logoot.Sequence
  alias Syncordian.Basic_Types

  defstruct id: nil, clock: 0, sequence: Sequence.empty_sequence()

  @type t :: %__MODULE__{
          id: Basic_Types.peer_id(),
          clock: non_neg_integer(),
          sequence: Sequence.t()
        }

  @spec new() :: t()
  def new(), do: %__MODULE__{}
  @spec new(Basic_Types.peer_id()) :: t()
  def new(id), do: %__MODULE__{id: id}
  # Getters

  @doc """
  Get the current state of the agent.
  """
  @spec get_state(t()) :: t()
  def get_state(agent), do: agent

  @doc """
  Get the current clock value of the agent.
  """
  @spec get_clock(t()) :: non_neg_integer()
  def get_clock(%__MODULE__{clock: clock}), do: clock

  @doc """
  Get the sequence stored in the agent.
  """
  @spec get_sequence(t()) :: Sequence.t()
  def get_sequence(%__MODULE__{sequence: sequence}), do: sequence

  @doc """
  Get the ID of the agent.
  """
  @spec get_id(t()) :: Basic_Types.peer_id()
  def get_id(%__MODULE__{id: id}), do: id

  # Setters

  @doc """
  Increment the agent's clock by 1.
  """
  @spec tick_clock(t()) :: t()
  def tick_clock(%__MODULE__{} = agent) do
    %{agent | clock: agent.clock + 1}
  end

  @doc """
  Update the sequence stored in the agent.
  """
  @spec update_sequence(t(), Sequence.t()) :: t()
  def update_sequence(%__MODULE__{} = agent, sequence) do
    %{agent | sequence: sequence}
  end

  @doc """
  Update the ID of the agent.
  """
  @spec update_id(t(), Basic_Types.peer_id()) :: t()
  def update_id(%__MODULE__{} = agent, id) do
    %{agent | id: id}
  end
end
