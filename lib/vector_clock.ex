defmodule Syncordian.Vector_Clock do
  @moduledoc """
    This module contains the vector clock implementation/definition for the Syncordian
    project.
  """

  @doc """
    We define the projection distance to be the difference in the number of events that
    each peer has seen. To do so, we calculate the sum of the projections and find the
    difference.
    ## Examples
      iex> projection_distance([1, 2, 3], [1, 2, 3])
      0
      iex> projection_distance([1, 2, 0], [1, 2, 3])
      3
      iex> projection_distance([1, 2, 0], [10, 3, 0])
      10
  """
  @spec projection_distance(
          local_vc :: Syncordian.Basic_Types.vector_clock(),
          incoming_vc :: Syncordian.Basic_Types.vector_clock()
        ) :: integer
  def projection_distance(local_vc, incoming_vc) do
    projection_distance? =
      Enum.zip_reduce(local_vc, incoming_vc, 0, fn local_vc_projection,
                                                   incoming_vc_projection,
                                                   acc ->
        acc + abs(local_vc_projection - incoming_vc_projection)
      end)
    case projection_distance? do
      # TODO: Be sure about this solution! This was before the change of definition!!
      # I think that with this new definition this is not needed anymore.
      # Case: Local[1,1] incoming[2,0] without this we get 0 and the stash window is 0 thus
      # the stash process never starts. I THINK this is the correct behavior! THINK!
      0 -> Enum.sum(local_vc)
      _ -> projection_distance?
    end
  end

  @doc """
    Given two vector clocks, local_vc and incoming_vc, this function returns the distance
    between then. This distance is the distance between the local_vc and the incoming_vc
    in the incoming_vc vector clock peer position.

    ## Examples
      iex> distance_between_vector_clocks([1, 2, 3], [1, 2, 3], 0) 0 iex>
      distance_between_vector_clocks([1, 2, 0], [1, 2, 3], 2) 3 iex>
      distance_between_vector_clocks([1, 2, 0], [0, 3, 0], 1) 1
  """
  @spec distance_between_vector_clocks(
          local_vc :: Syncordinan.Basic_Types.vector_clock(),
          incoming_vc :: Syncordian.Basic_Types.vector_clock(),
          incoming_peer_position :: integer
        ) :: integer
  def distance_between_vector_clocks(local_vc, incoming_vc, incoming_peer_position),
    do:
      abs(
        Enum.at(local_vc, incoming_peer_position) - Enum.at(incoming_vc, incoming_peer_position)
      )

  @doc """
    Return true when the local_vc is less than the incoming_vc.

    The order is defined by adding all the projections of both vectors and comparing both
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
          local_vc :: Syncordian.Basic_Types.vector_clock(),
          incoming_vc :: Syncordian.Basic_Types.vector_clock()
        ) :: boolean
  def order_vector_clocks_definition(local_vc, incoming_vc) do
    # TODO: Rethink the definition when equal
    local_vc_sum = Enum.sum(local_vc)
    incoming_vc_sum = Enum.sum(incoming_vc)

    case {local_vc_sum < incoming_vc_sum, local_vc_sum == incoming_vc_sum} do
      {true, false} -> true
      {false, false} -> false
      # Revisar la proyeccion del local when equal
      {_, true} -> false
    end
  end
end
