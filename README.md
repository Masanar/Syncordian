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
from github with over 700 concurrent edit operations contributed by 30 network peers. With
this evaluation we validate Syncordian is effective in maintaining document consistency
across all peers, even in the presence of Byzantine nodes. Moreover, we evaluate the
performance of the Syncordian with respect to memory consumption, network load, and
execution, demonstrating its usability in real world scenarios.

## Prerequisites

The project pins Elixir `~> 1.18.3` in `mix.exs`. The verified, working
toolchain is:

- **Erlang/OTP 28** (e.g. `28.5`)
- **Elixir 1.18.4** (built for OTP 28, i.e. `1.18.4-otp-28`)

>
> A newer default Elixir (e.g. 1.19.x) does **not** satisfy the `~> 1.18.3`
> constraint and `mix` will refuse to compile. If your machine defaults to a
> newer version (or you manage versions with `asdf`/`mise`), switch your
> default rather than prefixing every command, e.g.:
>
> ```bash
> asdf local elixir 1.18.4-otp-28 erlang 28.5
> # or: mise use elixir@1.18.4-otp-28 erlang@28.5
> ```
>
> Check what you have with `elixir --version`. There is no `.tool-versions` file
> in the repo, so the version is governed solely by the `mix.exs` constraint.
> The commands throughout this README assume `elixir`/`mix` on `PATH` already
> resolve to the pinned toolchain.

All Elixir dependencies are vendored in `deps/` and pre-compiled in `_build/`,
and the esbuild/tailwind binaries are cached under `_build/`, so the project
builds and runs **fully offline** — no `mix deps.get` or network access required.

## Installation & setup

```bash
# First time only: fetch deps and build the JS/CSS assets.
mix setup            # = deps.get + assets.setup + assets.build

# The experiment scripts write here; create it once.
mkdir -p debug/documents
```

## What a run is

Everything below produces or checks a **run**. A run is one execution of the
system under one setting. A run is described by four things.

| Part | What it means | Default |
| ---- | ------------- | ------- |
| **seed** | One number that fixes every random choice the system makes. Two runs with the same seed do the same thing. | none, so the run cannot be repeated |
| **delay** | How long each message waits before it arrives. Written as `uniform:5:50`, meaning every message waits a random time between 5 and 50 milliseconds. | `none`, no delay at all |
| **scenario** | What goes wrong during the run. One of `baseline`, `reorder_storm`, `offline_window`, `post_collection_replay`, `bounded_loss`. The last four are explained under Live tests. | `baseline`, nothing goes wrong |
| **adversaries** | How many distrusted nodes join the network and attack it. | `0` |

A run writes everything it did into one folder. That folder holds:

- `manifest.json`, the four things above plus the machine and the versions used.
  If you want to know how a number was produced, read this file.
- `documents/`, the final document of every peer.
- `metadata/`, counters taken during the run.
- `result.json`, whether the run converged and how long it took.

The default folder is `debug/`. You can point a run somewhere else with `--out`.

The seed matters more than it looks. With a seed, two runs produce the same
document, the same identifiers, and the same signatures. Without one, they do
not. The seed does not control the order in which Erlang schedules the peers, and
nothing can, so the timing of a run still varies. That is why results are
reported over many runs instead of one.

## Testing

There are two kinds of test. Both are ordinary ExUnit tests, run with `mix test`.

### Fast tests

These do not start peers and do not need a git clone. They take about ten
seconds.

```bash
mix test                                       # every fast test
mix test test/syncordian/path_id_test.exs      # one file
mix test test/syncordian/path_id_test.exs:42   # one test, by line number
```

| File | What it checks |
| ---- | -------------- |
| `path_id_test.exs` | Picking a position identifier between two existing lines. |
| `document_test.exs` | Inserting and deleting lines in a document. |
| `interleaving_test.exs` | The rule that keeps each author's block of lines together. |
| `reissue_alias_test.exs` | What happens when a line is moved and deleted at the same time. |
| `vector_clock_test.exs` | Deciding which edit happened before which. |
| `progress_semantics_test.exs` | When an edit is allowed to be applied. |
| `pending_ops_test.exs` | The buffer that holds an edit until the edit it depends on arrives. |
| `seen_ops_test.exs` | Remembering which edits were already applied, so a repeat is ignored. |
| `op_log_test.exs` | The log a peer keeps so it can send an edit again if someone lost it. |
| `wire_signature_test.exs` | The tags that travel with a message. |
| `ack_signature_test.exs` | The tags on acknowledgements. |
| `boundary_secret_test.exs` | The shared secret that decides who is allowed in. |
| `insider_scope_test.exs` | Writes down what the system does not protect against, on purpose. |
| `instrumentation_test.exs` | The counters that measure cost. |
| `run_config_test.exs` | Seeds, the delay setting, and the description of a run. |
| `network_test.exs` | The simulated network, and what an attacker can do to a message. |
| `workloads_test.exs` | **New.** The workload generator: that a seed fixes an execution, and that the writers really are set up to collide. |
| `supervisor/gitparser_test.exs` | Turning a git log into edits. |
| `supervisor/gitlog_test.exs` | Reading the git log from a real clone. |

### Live tests

These start real peer processes and let them talk to each other. They take about
fifty seconds, so they are skipped unless you ask for them.

```bash
mix test --include live          # the fast tests plus the live ones
```

| File | What it checks |
| ---- | -------------- |
| `live/recovery_test.exs` | A peer that missed an edit asks for it again and gets it. |
| `live/difficult_executions_test.exs` | The four hard situations below. |
| `live/workloads_test.exs` | **New.** The seven controlled workloads, described further down. |

The four hard situations are the interesting part, so here is what each one does.

| Situation | Name to pass to `--scenario` | What happens | What must still be true |
| --------- | ---------------------------- | ------------ | ----------------------- |
| **Reorder storm** | `reorder_storm` | Messages are delayed, sent twice, and mixed up, while an attacker sends fake ones. Almost nothing arrives in the order it was sent. | Every peer ends with the same document, no fake message is accepted, and no line is left unfinished. |
| **Offline window** | `offline_window` | One peer is cut off, misses edits, and is later reconnected. Nobody resends anything to it. | It asks for what it missed and catches up. |
| **Post-collection replay** | `post_collection_replay` | An attacker records real messages and sends them again much later, after the peers have stopped remembering them. These messages are genuine, so they pass every security check. | The document does not change. No line appears twice, and a deleted line does not come back. |
| **Bounded loss** | `bounded_loss` | Messages are thrown away at random on every link for a while, and then the network heals. | The peers ask for what was lost and end up with the same document. |

The third one is the important one. Those messages are real, so checking
signatures cannot stop them. What stops them is that every edit carries an
identity, and that a deleted line stays deleted.

### Smoke scripts

These are not ExUnit tests. They are small programs that set up one situation and
print `PASS` or `FAIL`. Use them for a quick check after changing the CRDT,
without waiting for a full replay.

```bash
mix run --no-start scripts/three_peer_smoke.exs    # three peers, a few edits
mix run --no-start scripts/interleaving_smoke.exs  # two peers writing at the same spot
mix run --no-start scripts/cascade_smoke.exs       # three peers, and a delete during a repair
```

Use `--no-start` so Mix does not boot the web app, which a script does not need.

Code is formatted with `mix format`.

## Running one experiment

An experiment replays a real git history. Each contributor becomes one peer, and
each commit becomes a set of edits. At the end, every peer's document must match
the file as git holds it.

```bash
mix run --no-start scripts/run_full_experiment.exs
```

Some useful options:

```bash
# A repeatable run under a real delay.
mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50

# Five distrusted nodes attacking during the replay.
mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50 --adversaries 5

# One of the hard situations, over the whole history.
mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50 \
  --scenario reorder_storm --adversaries 5

# Write somewhere other than debug/.
mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50 --out /tmp/run1
```

The script first prints the repository, the tracked file, the number of peers,
the number of commits, and the hash of the last commit. It then replays
everything, waits for the network to go quiet, and checks two things. First, that
all peers agree with each other. Second, that they agree with
`git show <hash>:<file>`. Agreement on its own is not enough, because peers that
all made the same mistake still agree with each other.

Add `--observer` to open the Erlang observer window and watch the peers while
they work. It needs a graphical display. If it cannot start, the run continues
without it.

To choose which repository and file to replay, set these before the command:

```bash
SYNCORDIAN_REPO_PATH=../../ohmyzsh \
SYNCORDIAN_TRACKED_FILE=README.md \
SYNCORDIAN_MAX_COMMITS=20 \
mix run --no-start scripts/run_full_experiment.exs --seed 1 --delay uniform:5:50
```

`SYNCORDIAN_MAX_COMMITS` is useful while trying things out, because a short
history finishes in seconds instead of minutes.

There is also a Mix task that does a simpler version of the same thing:

```bash
mix syncordian.eval --crdt syncordian --byzantine 0
```

And a separate checker you can run after any experiment:

```bash
mix run --no-start scripts/verify_convergence.exs
```

It checks that all peer documents are identical, that they match the file in git,
and that no line was left unfinished.

## Running many experiments

One run tells you very little. The timing of a concurrent system changes from run
to run, so a single number is one observation and not a property of the system.
Each setting is therefore run ten times, with ten different seeds, and reported as
an average with a confidence interval.

```bash
mix run --no-start scripts/run_repetitions.exs \
  --reps 10 --seed-base 1 --delay uniform:5:50 \
  --scenarios baseline,reorder_storm --adversaries 5 --root debug/runs
```

Each repetition runs as its own operating system process. This matters, because
two runs inside one Erlang node would share state, and then the runs would not be
independent.

The sweep can be stopped and started again. A repetition that already has a
`result.json` is skipped, so no work is repeated.

Two things the driver refuses to do, on purpose.

- It refuses `--delay none`. The paper says peers exchange messages under a
  delay, so a run whose numbers are reported has to apply one.
- It refuses `offline_window` and `bounded_loss` over a git history. In those two
  situations a peer can fall behind with nothing to tell it so, and the replay
  then waits for that peer forever instead of failing. Both are checked by the
  live tests instead. Pass `--allow-stalling-scenarios` to try anyway.

### Reading the numbers

```bash
pip install -r scripts/requirements.txt     # matplotlib and numpy

python3 scripts/aggregate_runs.py --runs debug/runs --out debug/aggregate
python3 scripts/data_visualization.py
python3 scripts/heap_size_visualization.py
```

`aggregate_runs.py` reads every run folder and writes one table,
`debug/aggregate/summary.csv`, plus the same data as JSON. Each row is one
measurement at one point, with the number of runs behind it, the average, the
spread, and a 95% confidence interval. Two rules keep those numbers honest.

- **One run is one sample.** Each run is reduced to a single value first, and the
  interval is taken over those ten values. Pouring every message of every run
  into one pile would give a much narrower interval, for a reason that has
  nothing to do with how repeatable the experiment is.
- **Some quantities cannot vary.** Under the same workload the number of edits,
  and the bytes they take, are the same every time. Those are marked and drawn
  without a band, because a band there would suggest a doubt that does not exist.

The two plotting scripts read that table and draw the average, the confidence
band, and the individual runs behind it. They write PDFs into `figures/`.

One note on `heap_size_visualization.py`. Only one peer records the size of its
document after every edit, so the plot needs a run with enough peers for that one
to exist. A short history with only three or four peers produces no data for it,
and the script says so instead of drawing an empty figure.

## Controlled concurrent workloads

Everything above replays a real git history. That is the right test of
convergence, and it is a poor test of everything else, for one reason worth being
clear about.

The replay holds each commit until its author has built the state that commit was
written against. Authoring is therefore serialized: two people never write to the
same place in the document at the same moment. Only the delivery is concurrent.
You can see this in the numbers. Over both histories we replay, the counters that
record an interleaving and its repair stay at zero from the first commit to the
last. The repair machinery is never asked to run, so a passing replay says nothing
about it.

The workloads in this section are the missing half. Each one puts several writers
in the same place at the same time on purpose, and then checks what must be true
afterwards. They are cheap, they take seconds, and they are the only place the
repair protocol is exercised at all.

### The seven workloads

| Name | What it constructs | What it must show, beyond every replica holding the same text |
| ---- | ------------------ | ------------------------------------------------------------- |
| `same_position_inserts` | Every writer inserts one line at the same position. | Every line survives, in one order, with none left unfinished. |
| `overlapping_blocks` | Several writers each append a block in the same place. | Each writer's lines end up together, a repair actually happened, and none is still owed. |
| `identical_content_blocks` | The same, with every writer authoring identical text. | Every copy survives. Nine lines from three writers of three lines, not three. |
| `delete_insert_races` | A delete aimed at a line while a repair is moving it. | The line stays deleted, and no replica ever held two copies of it. |
| `long_offline` | One writer cut off in both directions, then reconnected. | It asks for what it missed and is answered. Nothing is resent to it. |
| `post_gc_replay` | Real messages captured and sent again much later. | The document does not change, no line appears twice, a deleted line stays deleted. |
| `three_way_cascade` | Writers arranged so repairing one conflict creates the next. | The chain of repairs stops, and stops within the bound the rule gives it. |

Two things about that table are deliberate.

The first is the phrase *a repair actually happened*. Every workload checks it
where it applies, by looking at the counters and not at the document. Without that
check a workload could pass while building no conflict at all, which is exactly
the state the git replay is in, and every other property would have been checked
over an execution that tested nothing.

The second is what `long_offline` does **not** claim. A replica that returns from
an outage recovers the edits it missed, because those are kept by their author and
can be asked for. It does not recover the acknowledgements sent while it was away,
because acknowledgements are not kept and there is nothing to ask for. Those lines
stay unfinished at that one replica forever, while every other replica has them
finished. So the text converges and the bookkeeping does not. The run reports this
rather than asserting it away. Closing it would mean making acknowledgements
recoverable, which is a change to the protocol.

### Running them

As tests, which is the short way:

```bash
mix test --include live test/syncordian/live/workloads_test.exs
```

That runs all seven at fixed seeds in about twenty seconds. There is also a fast
test file, `test/syncordian/workloads_test.exs`, which checks the workload
generator itself without starting any peers.

As a run that writes a folder you can inspect:

```bash
# Three writers contending in one place.
mix run --no-start scripts/synthetic_workload.exs \
  --workload overlapping_blocks --peers 4 --seed 1 --delay uniform:5:50

# The replay workload, which needs someone to do the replaying.
mix run --no-start scripts/synthetic_workload.exs \
  --workload post_gc_replay --peers 3 --seed 1 --delay uniform:5:50 --adversaries 1

# Somewhere other than debug/.
mix run --no-start scripts/synthetic_workload.exs \
  --workload three_way_cascade --peers 5 --seed 2 --delay uniform:5:50 --out /tmp/one
```

Options are `--workload`, `--peers`, `--ops-per-peer`, `--conflict-rate`,
`--seed`, `--delay`, `--scenario`, `--adversaries`, and `--out`. The script prints
what it is about to do, then every property with `ok` or `FAIL` beside it, then
the interleaving and traffic counters. It exits 0 only if every property held, so
it works in a script.

It writes the same folder shape as a git run: `manifest.json`, `result.json`,
`documents/`, and `metadata/`. The one difference is `metadata/workload.json`,
which holds the whole run's counters in one file. A git replay has commits to
report against and a synthetic workload does not, so its numbers describe the
whole execution rather than a series through it.

Two refusals, both on purpose.

- It refuses `--delay none`, for the same reason the repetition driver does: a run
  whose numbers get reported has to apply a delay. `--allow-no-delay` if you are
  debugging.
- It refuses `post_gc_replay` with `--adversaries 0`. That workload is about a
  message an attacker records and sends again, so with no attacker there is
  nothing to record, and the run would pass every check having tested nothing.

A note on the seed. A seed fixes when each writer issues each edit, so the same
seed sets up the same collision. It does not fix the order the virtual machine
schedules the peers in, so two runs of one seed can repair the same conflict in a
different order and still end up in the same place. That is the point of the
properties: they hold for every order, not for one.

## The scalability sweep

This is the experiment that answers what the costs do as the number of replicas
grows. The git replay cannot answer it. A replay has as many replicas as the file
had authors, so the number of peers is not something you can set. In the synthetic
workload it is.

**This one is expensive. Run it on a machine you are willing to give up for a
while.** The full command is:

```bash
mix run --no-start scripts/scalability_sweep.exs \
  --peers 8,16,32,64,128 --reps 30 --ops-per-peer 8 \
  --delay uniform:5:50 --root debug/sweep
```

Those are also the defaults, so `mix run --no-start scripts/scalability_sweep.exs`
does the same thing. That is 5 network sizes at 30 seeds each, 150 runs, each its
own operating system process for the same reason repetitions are: two runs in one
virtual machine would share the registry, the shared secret, and the timing
tables, and would not be independent samples of anything.

Before you commit a machine to it, check it works:

```bash
mix run --no-start scripts/scalability_sweep.exs --quick --root debug/sweep
```

`--quick` is two network sizes at two seeds, four short runs, about ten seconds.
It exercises the same path end to end, so if it works the full sweep will too.

### Why it costs what it costs

Every insert makes each of the other replicas acknowledge it, and every
acknowledgement is broadcast to all the others. So one insert costs about
`(n - 1)²` acknowledgement messages, and a run of `M` inserts costs `M(n - 1)²`.
With 8 edits per peer that is:

| Replicas | Inserts | Acknowledgement messages |
| -------- | ------- | ------------------------ |
| 8 | 64 | about 3 thousand |
| 16 | 128 | about 29 thousand |
| 32 | 256 | about 246 thousand |
| 64 | 512 | about 2 million |
| 128 | 1024 | about 16 million |

The top of that ladder is most of the cost of the sweep. That growth is not a
quirk of the harness. It is the thing being measured, and it is the reviewer's
concern about scalability turned into a number.

Three things follow, and all three are built into the script.

- **It goes smallest first.** If 128 replicas turn out to be more than the machine
  can do, stop it. Every smaller size is already finished and there is a trend
  through them.
- **It can be stopped and started again.** A run that already has a `result.json`
  is skipped, so restarting continues instead of beginning again.
- **It says what it did not finish.** At the end it prints how many runs stand
  behind each network size, and marks any that are short. Two runs and thirty runs
  are not the same evidence, and a figure drawn from both without saying so invites
  the reader to treat them as if they were.

`--ops-per-peer` is the knob to turn if the sweep is too slow, since the cost is
linear in it. `--conflict-rate` sets what fraction of the writers contend for the
same place; it defaults to 0.5, and the sweep holds it fixed so that the only
thing changing along the ladder is the number of replicas.

Because it is long, run it detached:

```bash
nohup mix run --no-start scripts/scalability_sweep.exs \
  --peers 8,16,32,64,128 --reps 30 --ops-per-peer 8 \
  --delay uniform:5:50 --root debug/sweep > sweep.log 2>&1 &
```

While it runs, `debug/sweep/index.json` lists every run attempted and what
happened to it, and each run folder keeps its own `console.log`.

### Turning the sweep into figures

```bash
python3 scripts/aggregate_runs.py --runs debug/sweep --out debug/sweep-aggregate
python3 scripts/scaling_visualization.py --aggregate debug/sweep-aggregate/summary.json
```

The first is the same aggregation the git runs use, so the averages and intervals
are computed the same way and the run is the unit of replication here too. The
second draws the figures into `figures/`, seven of them:

| Figure | What it shows |
| ------ | ------------- |
| `scaling_bytes_per_operation_*` | Bytes per message, by kind. Roughly flat: the per-message cost is not where the growth is. |
| `scaling_acknowledgement_traffic_*` | Total bytes, with acknowledgements separated from the edits they follow. This is where the growth is. |
| `scaling_acks_per_insert_*` | Acknowledgements per insert, measured, drawn on top of the predicted `n - 1`. |
| `scaling_settle_latency_*` | How long a line takes to be acknowledged by everyone, at the median, 95th, and 99th percentile. |
| `scaling_memory_per_line_*` | Bytes per line at one replica. Each line carries one entry per peer, so this grows with the network. |
| `scaling_queue_depth_*` | The deepest mailbox seen, and the deepest position identifier. |
| `scaling_replacement_amplification_*` | How many conflicts happened and how many lines each one cost to repair. |

The one to look at first is `scaling_acks_per_insert_*`. It draws the measurement
on top of `n - 1` rather than asserting the relationship, so a reader can check it
instead of taking it on faith. On the quick sweep the two lines already sit exactly
on top of each other: 3 acknowledgements per insert at 4 replicas, 7 at 8.

`scaling_memory_per_line_*` is worth a second look for a subtler reason. It divides
the recorded size twice, once by the number of lines and once by the number of
replicas. The recorded figure is a sum over all the replicas, so dividing only by
the line count would show a per-line cost that grows with the network for the
trivial reason that the sum has more terms in it. Divided properly, it still grows,
and that growth is the real one: the per-line list of who has acknowledged the line
has one entry per peer.

## Web UI (optional)

The web app is not needed for anything above. It is a control panel for running
an experiment by hand.

```bash
mix phx.server
```

Then open <http://localhost:4000>.

| Route | What it does |
| ----- | ------------ |
| `/` | About page. |
| `/supervisor` | Pick a CRDT and a number of distrusted nodes, launch the network, replay commits, dump documents. |
| `/node` | The raw document of one peer, including deleted lines. |
| `/readmelog` | The git commit log that drives the experiment. |

## Other helpers

`scripts/analyze-commits.sh` lists the files a repository changes most often, and
`scripts/number-of-commits.sh <path>` counts the commits touching one file. They
help you pick a history to replay. Neither is part of the evaluation.

`test/git_log/` holds two captured git logs. Some tests still read them. Real
runs read the log live from a clone instead.

## API documentation

Browsable HTML docs are generated with [ExDoc](https://hexdocs.pm/ex_doc):

```bash
mix docs           # regenerates the site under doc/
```

Open `doc/index.html` in a browser — the site is self-contained and works
offline. Modules are grouped by sub-system (Syncordian core, Fugue, Logoot,
Treedoc, shared infrastructure, experiment driver, web).

## Architecture & module dependencies

The four CRDT peer modules (`Syncordian.Peer`, `Syncordian.CRDT.Fugue.Peer`,
`Syncordian.CRDT.Logoot.Peer`, `Syncordian.CRDT.Treedoc.Peer`) share the same
callable contract so `Syncordian.Supervisor` can drive them polymorphically:

```text
start(peer_id, network_size) :: pid
insert(pid, content, index, test_index, global_position, current_delete_ops)
delete_line(pid, index, test_index, global_position, current_delete_ops)
save_content(pid)
get_module_name() :: String.t()
```

Project layout:

- `lib/syncordian/` — CRDT backend and the experiment driver.
  - `CRDT/syncordian/` — the Syncordian CRDT (peer, document, line, path id,
    signatures, interleaving handling, pending/seen-op buffers, origin log).
  - `CRDT/fugue/`, `CRDT/logoot/`, `CRDT/treedoc/` — the comparison CRDTs.
  - `CRDT/{utilities,metadata,vector_clock,instrument,op_times,types}.ex` —
    shared infrastructure and the cost measurements.
  - `run.ex`, `rng.ex`, `network.ex` — the description of a run, the randomness a
    seed fixes, and the simulated network every message crosses.
  - `workloads.ex`, `workloads/checks.ex` — the controlled concurrent workloads
    and the properties each one has to satisfy.
  - `supervisor/` — `Syncordian.Supervisor` (hand-rolled receive loop) and the
    `Syncordian.GitParser` that turns commit logs into edits.
- `lib/syncordian_web/` — Phoenix LiveView UI.
- `scripts/` — one run (`run_full_experiment.exs`), many runs
  (`run_repetitions.exs`), one controlled workload
  (`synthetic_workload.exs`), the peer-count sweep
  (`scalability_sweep.exs`), the post-hoc check (`verify_convergence.exs`), the
  smoke programs, and the Python aggregation and plotting.

### Module dependency graph

A directed edge `A → B` means *module A depends on module B*. A rendered version
(`docs/dependency_graph.svg` / `.png`, regenerate with
`dot -Tsvg docs/dependency_graph.dot -o docs/dependency_graph.svg`) shows the same
graph grouped by sub-system. Note the intentional `Peer ↔ Utilities` cycle:
`Utilities` is both a helper library and the CRDT-agnostic dispatcher that routes
to every peer implementation.

```mermaid
flowchart LR
  subgraph Entry["Entry points"]
    App[Syncordian.Application]
    Eval[Mix.Tasks.Syncordian.Eval]
    WSup[SyncordianWeb.Supervisor]
    WNode[SyncordianWeb.Node]
  end
  subgraph Driver["Experiment driver"]
    Sup[Syncordian.Supervisor]
    GP[Syncordian.GitParser]
  end
  subgraph Core["Syncordian CRDT"]
    Peer[Syncordian.Peer]
    Doc[Syncordian.Document]
    Line[Syncordian.Line]
    LObj[Syncordian.Line_Object]
    PathId[Syncordian.PathId]
    Byz[Syncordian.Byzantine]
    BPeer[Syncordian.ByzantinePeer]
    Intl[Syncordian.Interleaving]
    Pend[Syncordian.PendingOps]
    Seen[Syncordian.SeenOps]
    OpLog[Syncordian.OpLog]
    Info[Syncordian.Info]
  end
  subgraph Infra["Shared infrastructure"]
    Util[Syncordian.Utilities]
    Meta[Syncordian.Metadata]
    VC[Syncordian.Vector_Clock]
    Types[Syncordian.Basic_Types]
    Instr[Syncordian.Instrument]
    OpT[Syncordian.OpTimes]
  end
  subgraph RunCfg["A run and its network"]
    RunM[Syncordian.Run]
    RngM[Syncordian.Rng]
    Net[Syncordian.Network]
  end
  subgraph Fugue["Fugue"]
    FP[Fugue.Peer] --> FT[Fugue.Tree] --> FN[Fugue.Node]
    FP --> FI[Fugue.Info]
  end
  subgraph Logoot["Logoot"]
    LP[Logoot.Peer] --> LS[Logoot.Sequence]
    LP --> LA[Logoot.Agent]
    LP --> LI[Logoot.Info]
  end
  subgraph Treedoc["Treedoc (stub)"]
    TP[Treedoc.Peer] --> TB[Treedoc.Bst] --> TN[Treedoc.Node]
  end

  App --> Sup
  Eval --> Sup
  WSup --> Sup
  WNode --> LObj
  Sup --> Meta & GP & Util & BPeer & Peer & RunM & Net & RngM
  Peer --> Meta & Info & Line & Doc & Byz & LObj & Util & VC & Pend & Seen & Intl
  Peer --> Net & RngM & OpLog & OpT
  BPeer --> Net & RngM & RunM
  Net --> RunM & RngM & Instr
  RngM --> RunM
  Byz --> RunM & Instr
  Doc --> LObj & Line & VC & Byz & PathId
  Line --> Byz & PathId & Pend
  Byz --> LObj
  Intl --> LObj & PathId
  Util --> Peer & FP & LP & TP & Types
  Meta --> Util & Byz & Intl & Seen
  FP --> Util & Meta
  LP --> Util & Meta
  TP --> Util & Meta
```

## Credits

- Mateo Sanabria Ardila (m.sanabriaa_at_uniandes_dot_edu_dot_co)
- Nicolás Cardozo (n.cardozo_at_uniandes_dot_edu_co)

## License

The MIT License (MIT)

Copyright (c) Mateo Sanabria Ardila, Nicolás Cardozo

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
