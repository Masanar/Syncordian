defmodule Logoot.Info do
    def print_document_info(document) do
        [document_str, document_len] = document |> show_document_str 
        IO.puts "The current document is: "
        IO.puts document_str
        IO.puts "The length of the document is #{inspect(document_len)} "
    end
    def document_length(document), do: document |> length |> Kernel.-(2)
    defp show_document_str(document), do: Enum.reduce(document, ["",0], fn [_,value], [str,count] -> [str <> value,count+1] end)
#   defp show_document_map(document) do 
#     document 
#     |> Enum.reduce([%{},0], fn [_,value],[map,count] -> [Map.put(map,count,value) ,count+1] end)
#   end
end