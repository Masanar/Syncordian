defmodule Syncordian.CRDT.Logoot.Peer do

    import Syncordian.Metadata
    alias Syncordian.CRDT.Logoot.{Agent, Metadata}

    defstruct  agent: [], metadata: Syncordian.Metadata.metadata()

end
