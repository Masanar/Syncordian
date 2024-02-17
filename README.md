# Bizantine Syncordian

Collaborative editing, as observed in projects such as Google Docs, often relies on costly
central services. While many Conflict-Free Replicated Data Types ( CRDTs) exists to solve
this problem, to date none have mechanisms to support Byzantine faults and the presence of
interleavings. We present the Syncordian CRDT, which guarantees consistency and intention
preservation between nodes as a consequence of the Byzantine faults-free algorithm
implemented for insertions, deletions, and update operations in share documents. Our
scheme withstands Byzantine nodes, providing immunity against Sybil attacks and ensuring
eventual consistency. Moreover, the presented algorithm naturally avoids insertion or
update interleavings when synchronizing nodes. To evaluate Syncordian we use the
comprehensive corpus of Wikipedia edits. We evaluate the corpus against state-of-the-art
CRDTs demonstrating the effectiveness of our approach in ensuring reliability and
consistency in the challenging context of Byzantine faults within peer-to-peer
collaborative editing environments without introducing any interleaving anomalies.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `bizantine_crdt` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:Syncordian, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/bizantine_crdt](https://hexdocs.pm/bizantine_crdt).

