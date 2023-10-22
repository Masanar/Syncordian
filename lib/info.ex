defmodule Logoot.Info do
    def print_document_info(document) do
        [document_str, document_len] = document |> show_document_str 
        IO.puts "\n ------------------"
        IO.puts "The current document is: "
        IO.puts document_str
        IO.puts "The length of the document is #{inspect(document_len)} "
        IO.puts "------------------ \n"
    end
    def document_length(document), do: document |> length |> Kernel.-(2)
    defp show_document_str(document), do: Enum.reduce(document, ["",0], fn [_,value], [str,count] -> [str <> value,count+1] end)
end