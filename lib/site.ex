defmodule Logoot.Site do
    import Logoot.Structures
    import Logoot.Info
    # TODO: Probably the site_id for the min and max position is always the same 0 and 1
    # respectively
    require Record
    Record.defrecord(:site, id: None, clock: 1, document: None)
    @min_int 130
    @max_int 32767

    def loop(site) do
        receive do
            {:info, _} ->
                site(site, :document)
                |> print_document_info
                loop(site)
            {:insert,[value,pos]} ->
                document = site(site, :document)
                [previous,next] = get_position_index(document,pos)
                current_clock = site(site, :clock)
                site_new_clock = tick_site_clock(site,current_clock+1)
                sequence = site
                |> site(:id)
                |> create_atom_identifier_between_two_sequence(current_clock, previous, next)
                |> create_sequence_atom(value)
                # TODO: This sequence needs to be catch and broadcast
                sequence
                |> add_sequence_to_document(document)
                |> update_site_document(site_new_clock)
                |> loop
                # todo: broadcast!!
            {:print,_} -> IO.inspect(site)
            loop(site)
            {_,_} -> 
                IO.puts "Wrong message"
                loop(site)
        end
    end
    def insert(pid,value,index),do: send(pid,{:insert,[value,index]})
    def info(pid),do: send(pid,{:info,:document})
    def start(site_id) do
        pid = spawn(__MODULE__, :loop,  [define(site_id)])
        :global.register_name(site_id, pid)
        IO.puts "#{inspect(site_id)} registered at #{inspect(pid)}"
        pid
    end

    defp update_site_document(document, site) ,do: site(site, document: document) 

    defp get_position_index(document,0) ,do: [Enum.at(document,0),Enum.at(document,1)]
    defp get_position_index(document,pos_index) do
        len = length(document)
        case {Enum.at(document,pos_index),Enum.at(document,pos_index-1)} do
           {nil,_} -> [Enum.at(document,len-2),Enum.at(document,len-1)]
           {next, previous} -> [previous,next] 
        end 
    end

    defp tick_site_clock(site,new_clock_value) do
        site(site, clock: new_clock_value) 
    end
    
    defp define(site_id) do
        initial_site_document = [[[[[@min_int, site_id]], 0], ""], [[[[@max_int, site_id]], 1], ""]]
        site(id: site_id, document: initial_site_document)
    end
end