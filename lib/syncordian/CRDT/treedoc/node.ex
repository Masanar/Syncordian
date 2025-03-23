defmodule Syncordian.CRDT.Treedoc.Node do
  defstruct [:data, :left, :right]
  @type t :: %__MODULE__{
          data: Syncordian.Basic_Types.content(),
          left: t() | nil,
          right: t() | nil
        }
end
