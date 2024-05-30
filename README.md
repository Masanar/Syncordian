# Syncordian

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

## Testing

We provided a test scenario for Syncordian based on the git log of the edit for the
README.md for the git project of [OhMyZsh](https://github.com/ohmyzsh/ohmyzsh). To
replicate the test run

```
  ▶ iex -S mix
  Erlang/OTP 26 [erts-14.2.5] [source] [64-bit] [smp:20:20] [ds:20:20:10] [async-threads:1] [jit:ns]

  Interactive Elixir (1.16.2) - press Ctrl+C to exit (type h() ENTER for help)
  iex(1)> Test.init()
```

This will create a folder /debug with the resulting document for each of the peer (authors)
that had participated in the document.
