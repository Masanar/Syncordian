defmodule Logoot.Byzantine do
    @moduledoc """
    """
    require Record
    Record.defrecord(:dag, head: [], predecessors: %{})
    def new_dag() ,do: dag()
    def add_element(element,current_dag) do
        element_hash = :crypto.hash(:sha256, element) |> Base.encode16  
        head = dag(current_dag, :head)
        predecessors = dag(current_dag, :predecessors)
        element_hash
        |> update_predecessors_by_head(head,predecessors)
    end
    defp update_predecessors_by_head(element_hash,  [],  %{}) do
        dag(head: [element_hash], predecessors: %{element_hash => []} )
    end
    defp update_predecessors_by_head(element_hash, dag_head, dag_predecessors) do
        dag(head: [element_hash], predecessors: Map.put(dag_predecessors,element_hash,dag_head) )
    end
end
# :crypto.hash(:sha256, [3, "things", "!"]) |> Base.encode16
