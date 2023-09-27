defmodule Logoot.Site do
    import Logoot.Structures
    # TODO: Probably the site_id for the min and max position is always the same 0 and 1
    # respectively
    require Record
    @min_int 0
    @max_int 32767
    Record.defrecord(:site, id: None, clock: 1, state: None)
    # def loop(document) do
    #     receive do
    #         {:update, elment} -> loop()
            
    #     end
    # end
    def define(site_id) do
        initial_site_document = [[[[[@min_int, site_id]], 0], None], [[[[@max_int, site_id]], 1], None]]
        site(id: site_id, state: initial_site_document)
    end
    def start(site_id) do
        pid = spawn(__MODULE__, :loop,  [define(site_id)])
        :global.register_name(site_id, pid)
        IO.puts "#{inspect(site_id)} registered at #{inspect(pid)}"
    end
end