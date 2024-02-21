defmodule Syncordian.Vector_Clock do
  @moduledoc """
    This module contains the vector clock implementation/definition for the Syncordian
    project.
  """


  @doc """
    Given two vector clocks, local_vc and incoming_vc, this function returns the distance
    between then. The distance is the distance between the local_vc and the incoming_vc in the
    incoming_vc vector clock peer position.
  """
  @spec distance_between_vector_clocks(
          local_vc :: list[integer],
          incoming_vc :: list[integer],
          incoming_peer_position :: integer
        ) :: integer
  def distance_between_vector_clocks(local_vc, incoming_vc, incoming_peer_position) do
    abs(local_vc[incoming_peer_position] - incoming_vc[incoming_peer_position])
  end

  @doc """
    Return true when the local_vc is less than the incoming_vc.

    The order is defined by adding the projections of both vectors and comparing both
    numbers. If the local_vc is less than the incoming_vc, it returns true, otherwise, it
    returns false. If both vector clocks are equal, it returns true.

    ## Examples
      iex> order_vector_clocks_definition([1, 2, 3], [1, 2, 3])
      true
      iex> order_vector_clocks_definition([1, 2, 0], [1, 2, 3])
      false
      iex> order_vector_clocks_definition([1, 2, 0], [0, 2, 0])
      true

  """
  @spec order_vector_clocks_definition(
          local_vc :: list[integer],
          incoming_vc :: list[integer]
        ) :: boolean
  def order_vector_clocks_definition(local_vc, incoming_vc) do
    local_vc_sum = Enum.sum(local_vc)
    incoming_vc_sum = Enum.sum(local_vc)
    case {local_vc_sum < incoming_vc_sum, local_vc_sum == incoming_vc_sum} do
      {true, _}  -> true
      {false, _} -> false
      {_, true}  -> true
    end
  end
end
