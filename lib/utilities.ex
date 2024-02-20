defmodule Syncordian.Utilities do
  @moduledoc """
      This module provides utility functions used in the Syncordian implementation, that
      do not fit on the main modules.
  """

  @doc """
    Given a list, a index of the list, and a value, this function updates the value of the
    list at the given index with the given value.
  """
  @spec update_list_value([any()], integer, any, integer) :: [any()]
  def update_list_value([head | tail], index, value, acc = 0) do
    case index == acc do
      true  -> [value | tail]
      false -> [head  | update_list_value(tail, index, value, acc + 1)]
    end
  end
end
