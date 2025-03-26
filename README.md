# Syncordian

Collaborative editing, as observed in projects such as Google Docs, often relies on costly
central services. While many CRDT exists to solve this problem, to date none have
mechanisms to support Byzantine faults and the presence of interleavings. We present the
Syncordian CRDT, which guarantees strong eventual consistency and intention preservation
between nodes as a consequence of the Byzantine faults-free algorithm implemented for
insertions, deletions, and update operations in share documents. Our scheme withstands
Byzantine nodes, providing immunity against Sybil attacks and ensuring strong eventual
consistency. Moreover, the presented algorithm naturally avoids interleavings when
synchronizing nodes. To evaluate Syncordian we use collaborative editing document taken
from github with over 930 concurrent edit operations contributed by 30 network peers. With
this evaluation we validate Syncordian is effective in maintaining document consistency
across all peers, even in the presence of Byzantine nodes. Moreover, we evaluate the
performance of the Syncordian with respect to memory consumption, network load, and
execution, demonstrating its usability in real world scenarios.

## Additional Results
### Interleaving evaluation results

The table below shows the results for the percentage of interleavings that occur while building the shared document for the Oh my zsh readme file. In the table we shows the average percentage of interleavings, together with the final document for each peer, and the number of interleavings in each file

| Implementation    | Average % of interleaving lines | peer 1 | peer 2 | peer 3 | peer 4 | peer 5 | peer 6 | peer 7 | peer 8 | peer 9 | peer 10 | peer 11 | peer 12 | peer 13 | peer 14 | peer 15 | peer 16 | peer 17 | peer 18 | peer 19 | peer 20 | peer 21 | peer 22 | peer 23 | peer 24 | peer 25 | peer 26 | peer 27 | peer 28 | peer 29 | peer 30 |
| -------- | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: | :-------: 
| Logoot | 66% | [peer 1](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_1) <br> 63 interleavings | [peer 2](https://github.com/Masanar/Syncordian/tree/main/debug/documents/documents/document_2) <br> 62 interleavings | [peer 3](https://github.com/Masanar/Syncordian/tree/main/debug/documents/documents/document_3) <br> 61 interleavings | [peer 4](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_4) <br> 61 interleavings | [peer 5](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_5) <br> 62 interleavings | [peer 6](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_6) <br> 62 interleavings | [peer 7](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_7) <br> 61 interleavings | [peer 8](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_8) <br> 61 interleavings | [peer 9](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_9) <br> 61 interleavings | [peer 10](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_10) <br> 61 interleavings| [peer 11](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_11) <br> 61 interleavings | [peer 12](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_12) <br> 60 interleavings | [peer 13](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_13) <br> 63 interleavings | [peer 14](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_14) <br> 61 interleavings | [peer 15](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_15) <br> 63 interleavings | [peer 16](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_16) <br> 62 interleavings| peer [peer 17](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_17) <br> 62 interleavings | [peer 18](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_18) <br> 60 interleavings | [peer 19](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_19) <br> 62 interleavings | [peer 20](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_20) <br> 61 interleavings | [peer 21](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_21) <br> 61 interleavings | [peer 22](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_22) <br> 61 interleavings | [peer 23](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_23) <br> 62 interleavings | [peer 24](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_24) <br> 60 interleavings | [peer 25](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_25) <br> 61 interleavings | [peer 26](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_26) <br> 61 interleavings | [peer 27](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_27) <br> 62 interleavings | [peer 28](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_28) <br> 61 interleavings | [peer 29](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_29) <br> 62 interleavings | [peer 30](https://github.com/Masanar/Syncordian/tree/main/debug/documents/logoot/document_30) <br> 63 interleavings |
| Fugue | 0% | [peer 1](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_1) <br> 0 interleavings | [peer 2](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_2) <br> 0 interleavings | [peer 3](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_3) <br> 0 interleavings | [peer 4](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_4) <br> 0 interleavings | [peer 5](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_5) <br> 0 interleavings | [peer 6](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_6) <br> 0 interleavings | [peer 7](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_7) <br> 0 interleavings | [peer 8](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_8) <br> 0 interleavings | [peer 9](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_9) <br> 0 interleavings | [peer 10](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_10) <br> 0 interleavings| [peer 11](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_11) <br> 0 interleavings | [peer 12](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_12) <br> 0 interleavings | [peer 13](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_13) <br> 0 interleavings | [peer 14](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_14) <br> 0 interleavings | [peer 15](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_15) <br> 0 interleavings | [peer 16](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_16) <br> 0 interleavings| peer [peer 17](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_17) <br> 0 interleavings | [peer 18](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_18) <br> 0 interleavings | [peer 19](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_19) <br> 0 interleavings | [peer 20](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_20) <br> 0 interleavings | [peer 21](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_21) <br> 0 interleavings | [peer 22](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_22) <br> 0 interleavings | [peer 23](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_23) <br> 0 interleavings | [peer 24](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_24) <br> 0 interleavings | [peer 25](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_25) <br> 0 interleavings | [peer 26](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_26) <br> 0 interleavings | [peer 27](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_27) <br> 0 interleavings | [peer 28](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_28) <br> 0 interleavings | [peer 29](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_29) <br> 0 interleavings | [peer 30](https://github.com/Masanar/Syncordian/tree/main/debug/documents/fugue/tree_peer_30) <br> 0 interleavings |
| Syncordian | 0% | [peer 1](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_1) <br> 0 interleavings | [peer 2](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_2) <br> 0 interleavings | [peer 3](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_3) <br> 0 interleavings | [peer 4](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_4) <br> 0 interleavings | [peer 5](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_5) <br> 0 interleavings | [peer 6](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_6) <br> 0 interleavings | [peer 7](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_7) <br> 0 interleavings | [peer 8](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_8) <br> 0 interleavings | [peer 9](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_9) <br> 0 interleavings | [peer 10](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_10) <br> 0 interleavings| [peer 11](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_11) <br> 0 interleavings | [peer 12](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_12) <br> 0 interleavings | [peer 13](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_13) <br> 0 interleavings | [peer 14](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_14) <br> 0 interleavings | [peer 15](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_15) <br> 0 interleavings | [peer 16](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_16) <br> 0 interleavings| peer [peer 17](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_17) <br> 0 interleavings | [peer 18](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_18) <br> 0 interleavings | [peer 19](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_19) <br> 0 interleavings | [peer 20](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_20) <br> 0 interleavings | [peer 21](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_21) <br> 0 interleavings | [peer 22](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_22) <br> 0 interleavings | [peer 23](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_23) <br> 0 interleavings | [peer 24](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_24) <br> 0 interleavings | [peer 25](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_25) <br> 0 interleavings | [peer 26](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_26) <br> 0 interleavings | [peer 27](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_27) <br> 0 interleavings | [peer 28](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_28) <br> 0 interleavings | [peer 29](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_29) <br> 0 interleavings | [peer 30](https://github.com/Masanar/Syncordian/tree/main/debug/documents/syncordian/document_peer_30) <br> 0 interleavings |

## Prerequisites

Before running the project, make sure you have the following installed:

- Erlang:  [Erlang/OTP 27](https://www.erlang.org/downloads/27)
- Elixir: [Install Elixir v.17.0](https://elixir-lang.org/install.html)

## Installation

1. Clone the repository:

```bash
git clone git@github.com:Masanar/Syncordian.git 
cd syncordian
mkdir -p debug/documents
```

2. Install the project dependencies:

```bash
mix phx.server
```

Once the server starts, you can visit your application at <http://localhost:4000>.

## Features

Syncordian is designed to be a peer-to-peer collaborative editing tool that uses CRDT to
ensure strong eventual consistency across nodes, even in the presence of Byzantine faults.

## Project Structure

- lib/: This folder contains the Elixir modules, including the CRDT logic.
- lib/syncordian/: This folder contains the backend implementation of the CRDT logic for
  Syncordian
- lib/syncordian_web/: This folder contains the Phoenix LiveView pages and components.

## LiveView Pages

[Syncordian web page](http://localhost:4000) includes several LiveView pages:

- /node: Displays the raw content (including tombstones) of the local document of any
  node.
- /supervisor: Interacts with the supervisor and its controlled processes. This page
allows to start the supervisor, run commits one by one, send all commits automatically or
write the current document (no tombstones) of all nodes as text files to the directory
/debug/documents. Once you write the document you may want to compere them against the
actual version of the document, the directory /debug/README_versions contains all the 71
documents versions for all the 71 commits.
- /readmelog: Provides the logs of the 71 commits for the text, just a visual tool to
check each the behavior of each commit.
- /about: An short about page with some information about the project.

## Credits

- Mateo Sanabria Ardila (m.sanabriaa_at_uniandes_dot_edu_dot_co)
- Nicolás Cardozo (n.cardozo_at_uniandes_dot_edu_co)

## License

The MIT License (MIT)

Copyright (c) 2015 Chris Kibble

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
