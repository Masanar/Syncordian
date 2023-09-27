# defmodule BasicCRDT do

#   def loop(state) do
#     receive do
#       {:update, element} ->
#         loop(MapSet.put(state,element))
#       {:query, element} ->
#         query = MapSet.member?(state,element)
#         IO.puts query
#         loop(state)
#       {:compare, other_state} ->
#         query = MapSet.subset?(state,other_state)
#         IO.puts query
#         loop(state)
#       {:merge, other_state} ->
#         loop(MapSet.union(state,other_state))
#       :show ->
#         IO.puts inspect(state)
#         loop(state)
#       :stop ->
#           IO.puts "Bye!"
#       msg ->
#         IO.puts "Unkown message type: #{inspect(msg)}"
#         loop(state)
#     end
#   end

#   def start(name) do
#       pid = spawn(__MODULE__, :loop,  [MapSet.new()])
#       :global.register_name(name, pid)
#       IO.puts "#{inspect(name)} registered at #{inspect(pid)}"
#   end

# end
