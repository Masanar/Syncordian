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
from github with over 700 concurrent edit operations contributed by 25 network peers. With
this evaluation we validate Syncordian is effective in maintaining document consistency
across all peers, even in the presence of Byzantine nodes. Moreover, we evaluate the
performance of the Syncordian with respect to memory consumption, network load, and
execution, demonstrating its usability in real world scenarios.

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
