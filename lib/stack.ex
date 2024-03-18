defmodule Stack do
  @type element :: any()
  @type stack :: %Stack{elements: [element]}

  defstruct elements: []

  @spec new() :: stack
  def new, do: %Stack{}

  @spec push(stack :: stack, element :: element) :: stack
  def push(stack, element), do: %{stack | elements: [element | stack.elements]}

  @spec pop(stack :: stack) :: {element, stack}
  def pop(%Stack{elements: [head | tail]}), do: {head, %Stack{elements: tail}}
end
