#!/usr/bin/env python3
"""Aggregate repeated runs into means with confidence intervals.

A single run of a concurrent system is one observation. This script turns a directory of
runs into the summary the evaluation reports: for every metric, at every point on the
horizontal axis, the number of runs behind the point, their mean, their standard deviation,
and a 95% confidence interval.

Two rules decide how the numbers are computed, and both matter more than they look.

**The unit of replication is the run.** Each run is first reduced to one value per metric
per point, and only then are the runs combined. A percentile is computed inside the run and
the interval is taken over the per-run percentiles. Pooling every message of every run into
one sample would give an interval computed from tens of thousands of observations that are
neither independent nor identically distributed, and it would be narrow for a reason that
has nothing to do with how repeatable the experiment is.

**A quantity that cannot vary is not given an interval.** Under a fixed workload the number
of operations, and the bytes they occupy, are the same in every run. Their variance across
runs is exactly zero, and drawing a band around them would invent an uncertainty that does
not exist. Such metrics are marked deterministic and reported as a point value.

Runs that did not converge are excluded from the means and reported separately. Averaging a
failed run into a result would hide the failure inside a number.

Usage, from ``Code/``::

    python scripts/aggregate_runs.py                       # reads debug/runs
    python scripts/aggregate_runs.py --runs debug/runs --out debug/aggregate

Output, under ``--out``:

  ``summary.csv``   one row per configuration, metric, and point. The long format the
                    plotting scripts read.
  ``summary.json``  the same, plus the per-run values behind every point, so a reported
                    number can be traced back to the runs that produced it.
  ``runs.csv``      one row per run: its configuration, its verdict, and its wall clock.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
from collections import defaultdict

# Two-sided 95% Student t quantiles by degrees of freedom. Tabulated rather than pulled from
# scipy so that the aggregation has no dependency the plotting scripts do not already have.
T_95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
    8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
    15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
    21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060, 26: 2.056,
    27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042, 40: 2.021, 60: 2.000,
    120: 1.980,
}

COMMIT_FILE = re.compile(r"^(?:byzantine_nodes_\d+_)?commit_(\d+)\.json$")
EDIT_FILE = re.compile(r"^(?:byzantine_nodes_\d+_)?edit_(\d+)\.json$")

# The configuration a run belongs to. Runs that agree on all of these and differ only in
# their seed are repetitions of one another; anything else is a different experiment.
#
# "workload" says which kind of experiment produced the run, a git replay or one of the named
# synthetic workloads, and "peer_count" is the size of the network. The peer count belongs to the
# key because the scalability sweep varies it: two points of that sweep are different experiments,
# and averaging them would report a mean over an experiment nobody ran. It is spelled "peer_count"
# rather than "peers" because a run-level metric already carries the latter name.
CONFIG_KEYS = (
    "crdt",
    "workload",
    "tracked_file",
    "max_commits",
    "peer_count",
    "scenario",
    "adversaries",
    "delay",
)

PERCENTILES = (50, 95, 99)


def t_quantile(degrees_of_freedom: int) -> float:
    """The two-sided 95% t quantile, taking the nearest tabulated value from below.

    Reading the table conservatively keeps an interval from being reported narrower than it
    is when the degrees of freedom fall between two entries.
    """
    if degrees_of_freedom < 1:
        return float("nan")
    candidates = [d for d in sorted(T_95) if d <= degrees_of_freedom]
    return T_95[candidates[-1]] if candidates else T_95[1]


def summarize(values: list[float]) -> dict:
    """Mean, spread, and a 95% interval over the per-run values behind one point."""
    n = len(values)
    mean = sum(values) / n

    if n == 1:
        return {
            "n": 1, "mean": mean, "sd": 0.0,
            "ci_low": mean, "ci_high": mean,
            "min": mean, "max": mean, "deterministic": True,
        }

    variance = sum((v - mean) ** 2 for v in values) / (n - 1)
    sd = math.sqrt(variance)

    # Exactly zero spread means the quantity does not vary across runs. Reported as a point
    # value; see the module docstring.
    if sd == 0.0:
        return {
            "n": n, "mean": mean, "sd": 0.0,
            "ci_low": mean, "ci_high": mean,
            "min": mean, "max": mean, "deterministic": True,
        }

    half_width = t_quantile(n - 1) * sd / math.sqrt(n)

    return {
        "n": n, "mean": mean, "sd": sd,
        "ci_low": mean - half_width, "ci_high": mean + half_width,
        "min": min(values), "max": max(values), "deterministic": False,
    }


def percentile(sorted_values: list[float], p: float) -> float:
    """Linear-interpolated percentile of an already sorted, non-empty list."""
    if len(sorted_values) == 1:
        return sorted_values[0]

    position = (len(sorted_values) - 1) * p / 100.0
    low = math.floor(position)
    high = math.ceil(position)

    if low == high:
        return sorted_values[low]

    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


########################################################################################
# Reading one run
########################################################################################


def read_json(path: str):
    with open(path) as handle:
        return json.load(handle)


def config_of(manifest: dict) -> tuple:
    workload = manifest.get("workload", {})
    adversary = manifest.get("adversary", {})

    # A git replay is identified by the file it tracked and the commit cap: two runs over
    # different truncations of the same history are different experiments. A synthetic workload is
    # identified by its name and the size of its network, and it tracks no file at all. A manifest
    # written before this distinction existed has no "kind", and is a git replay.
    if workload.get("kind") == "synthetic":
        label = "synthetic:%s" % workload.get("name", "unknown")
        tracked_file = ""
        max_commits = 0
        peer_count = workload.get("peers") or 0
    else:
        label = "git"
        tracked_file = workload.get("tracked_file", "unknown")
        max_commits = workload.get("max_commits") or 0
        peer_count = workload.get("max_peers") or 0

    return (
        workload.get("crdt", "syncordian"),
        label,
        tracked_file,
        max_commits,
        peer_count,
        manifest.get("scenario", "baseline"),
        adversary.get("count", 0),
        manifest.get("delay", "none"),
    )


def numeric_fields(snapshot: dict) -> dict:
    """The plottable fields of a snapshot: the numbers, and nothing else.

    The run block, the timestamp, and the list-valued samples are skipped. The lists are not
    dropped from the artifact, only from the per-point aggregation: they are distributions
    whose summary belongs to the run that produced them.
    """
    return {
        key: value
        for key, value in snapshot.items()
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    }


# The counters the per-commit figure is built from. They are network-wide cumulative totals,
# so a snapshot whose value fell below an earlier one is an incomplete collection rather than
# a network that undid work, and the longest non-decreasing chain through them is the
# maximal mutually consistent set of snapshots.
CUMULATIVE_ANCHORS = (
    "insert_valid_counter",
    "delete_valid_counter",
    "insert_distance_greater_than_one",
    "settle_counter",
)


def consistent_chain(points: list[int], series: dict[int, dict]) -> list[int]:
    """The longest run of snapshots along which the anchor counters never decrease.

    The supervisor collects peer metadata while the network is still moving, so a snapshot
    can miss a peer's report and sum to less than the one before it. Differencing across such
    a snapshot would report a commit at which the network processed a negative number of
    messages.
    """
    anchors = [a for a in CUMULATIVE_ANCHORS if any(a in series[p] for p in points)]

    if not anchors or len(points) < 2:
        return points

    vectors = [[series[p].get(a, 0) for a in anchors] for p in points]
    n = len(vectors)
    best, previous = [1] * n, [-1] * n

    for i in range(n):
        for j in range(i):
            if best[j] + 1 > best[i] and all(a <= b for a, b in zip(vectors[j], vectors[i])):
                best[i], previous[i] = best[j] + 1, j

    index = max(range(n), key=lambda k: best[k])
    chain = []

    while index != -1:
        chain.append(points[index])
        index = previous[index]

    chain.reverse()
    return chain


def with_deltas(series: dict[int, dict]) -> dict[int, dict]:
    """Adds a per-commit delta for every field that accumulates over the run.

    The counters a peer reports are cumulative over its life, so the work done at one commit
    is the difference between consecutive snapshots. The difference is taken *inside* the
    run, before anything is averaged. Differencing the means instead would give a series
    whose interval is not the interval of anything the experiment measured.

    A field is treated as cumulative when it never decreases along the consistent chain.
    Gauges such as the heap size or the queue depth do decrease, and are left alone.
    """
    points = sorted(series)
    if not points:
        return series

    chain = consistent_chain(points, series)
    if len(chain) < 2:
        return series

    fields = set()
    for point in chain:
        fields.update(series[point])

    cumulative = [
        field
        for field in fields
        if all(
            series[before].get(field, 0) <= series[after].get(field, 0)
            for before, after in zip(chain, chain[1:])
        )
    ]

    for position, point in enumerate(chain):
        previous = series[chain[position - 1]] if position else {}

        for field in cumulative:
            series[point][f"{field}_delta"] = series[point].get(field, 0) - previous.get(field, 0)

    return series


def read_run(directory: str) -> dict | None:
    """Everything one run contributes: its configuration, its verdict, and its series."""
    manifest_path = os.path.join(directory, "manifest.json")
    if not os.path.exists(manifest_path):
        return None

    manifest = read_json(manifest_path)

    result_path = os.path.join(directory, "result.json")
    result = read_json(result_path) if os.path.exists(result_path) else {}

    run = {
        "directory": directory,
        "manifest": manifest,
        "config": config_of(manifest),
        "seed": manifest.get("seed"),
        "status": result.get("status", "unknown"),
        "elapsed_ms": result.get("elapsed_ms"),
        "peers": result.get("peers"),
        "ground_truth": result.get("ground_truth"),
        "commits": with_deltas(read_series(directory, "metadata/supervisor", COMMIT_FILE)),
        "edits": read_series(directory, "metadata/individual_peer", EDIT_FILE),
        "latency": read_latency(directory),
        "workload": read_workload(directory),
    }

    return run


def read_workload(directory: str) -> dict:
    """A synthetic run's own snapshot, taken once at the end rather than per commit.

    A git replay reports a series, because it has commits to report against. A synthetic workload
    has no such axis: it is one execution, and its numbers describe the whole of it. They are
    therefore aggregated at the run level, where the peer count is a configuration column and the
    sweep can be read straight off it.
    """
    path = os.path.join(directory, "metadata", "workload.json")
    if not os.path.exists(path):
        return {}

    snapshot = read_json(path)
    fields = numeric_fields(snapshot)

    # Memory per line at one replica, which is what makes the per-line response checklist visible.
    # Two divisions, and both are needed. The document size is a total, so the network-wide figure is
    # the sum over the replicas and has to be divided by how many there are to describe one of them;
    # dividing only by the line count would report a per-line cost that grows with the network for
    # the trivial reason that the sum has more terms in it. The ratio is formed inside the run
    # because the mean of a ratio over runs is not the ratio of the means.
    lines = snapshot.get("live_lines") or 0
    replicas = snapshot.get("peer_count") or 0

    if lines and replicas and "heap_size" in fields:
        fields["bytes_per_line"] = fields["heap_size"] / (lines * replicas)
        fields["document_bytes"] = fields["heap_size"] / replicas

    # How many acknowledgements each insert cost. The interesting comparison is against n - 1, and
    # forming it here keeps the figure from having to know how the two counters relate.
    inserts = fields.get("msgs_insert") or 0
    if inserts:
        fields["acks_per_insert"] = (fields.get("msgs_ack") or 0) / inserts

    # The distributions the transient-interleaving results are built from. Each is a list of
    # observations rather than a counter, so it is summarized inside the run and the interval is
    # taken over the per-run summaries afterwards. This is the same rule the latency samples follow,
    # and for the same reason: a run is one sample, however many observations it contains.
    #
    # How many lines one conflict cost to repair is the amplification, and how long a repair took is
    # reported twice, in edits and in milliseconds, because the two answer different questions. Edits
    # say how much work passed before the document was clean again; milliseconds say how long a
    # reader would have seen it unclean.
    for field, label in (
        ("reissued_lines_per_conflict", "reissued_lines"),
        ("repair_latency_edits", "repair_latency_edits"),
        ("repair_latency_ms", "repair_latency_ms"),
    ):
        values = sorted(snapshot.get(field) or [])
        if not values:
            continue

        fields[f"{label}_mean"] = sum(values) / len(values)
        fields[f"{label}_max"] = values[-1]
        fields[f"{label}_count"] = len(values)

        for p in PERCENTILES:
            fields[f"{label}_p{p}"] = percentile(values, p)

    return fields


def read_series(directory: str, relative: str, pattern: re.Pattern) -> dict:
    """The per-point snapshots of one run, keyed by the point they were taken at."""
    root = os.path.join(directory, relative)
    series: dict[int, dict] = {}

    if not os.path.isdir(root):
        return series

    for current, _directories, files in os.walk(root):
        for name in files:
            match = pattern.match(name)
            if not match:
                continue

            point = int(match.group(1))
            snapshot = read_json(os.path.join(current, name))

            # A point already seen is kept at its later snapshot: the supervisor writes a
            # final post-settle snapshot over the same index, and that is the settled one.
            series[point] = numeric_fields(snapshot)

    return series


def read_latency(directory: str) -> dict:
    """The run's latency percentiles, computed inside the run.

    This is where the unit of replication is enforced for latency: the run is reduced to a
    handful of percentiles here, and the interval is taken over runs afterwards.
    """
    root = os.path.join(directory, "metadata")
    if not os.path.isdir(root):
        return {}

    summary: dict[str, float] = {}

    for name in sorted(os.listdir(root)):
        if not name.startswith("latency_") or not name.endswith(".json"):
            continue

        samples = read_json(os.path.join(root, name))

        for field, label in (("apply_latency_us", "apply"), ("settle_latency_us", "settle")):
            values = sorted(samples.get(field, []))
            if not values:
                continue

            for p in PERCENTILES:
                summary[f"{label}_latency_us_p{p}"] = percentile(values, p)

            summary[f"{label}_latency_us_mean"] = sum(values) / len(values)

        for field in ("operations", "applies", "settles"):
            if field in samples:
                summary[f"latency_{field}"] = samples[field]

    return summary


########################################################################################
# Aggregating across runs
########################################################################################


def aggregate(runs: list[dict]) -> list[dict]:
    """One row per configuration, metric, and point, over the runs that converged."""
    by_config: dict[tuple, list[dict]] = defaultdict(list)
    for run in runs:
        by_config[run["config"]].append(run)

    rows = []

    for config, group in sorted(by_config.items(), key=lambda item: str(item[0])):
        usable = [run for run in group if run["status"] == "ok"]

        if not usable:
            print(f"  no converged run for {config}; excluded from the summary")
            continue

        if len(usable) < len(group):
            print(f"  {len(group) - len(usable)} run(s) excluded from {config}: did not converge")

        rows.extend(aggregate_series(config, usable, "commits", "commit"))
        rows.extend(aggregate_series(config, usable, "edits", "edit"))
        rows.extend(aggregate_run_level(config, usable))

    return rows


def aggregate_series(config: tuple, runs: list[dict], series: str, axis: str) -> list[dict]:
    """Aggregate a per-point series across runs."""
    values: dict[tuple[str, int], list[float]] = defaultdict(list)

    for run in runs:
        for point, snapshot in run[series].items():
            for metric, value in snapshot.items():
                values[(metric, point)].append(value)

    rows = []

    for (metric, point), observations in sorted(values.items()):
        # A point that only some runs reached is reported at the number of runs that reached
        # it, which the n column makes visible rather than hiding behind a mean.
        row = dict(zip(CONFIG_KEYS, config))
        row.update({"axis": axis, "point": point, "metric": metric})
        row.update(summarize(observations))
        row["values"] = observations
        rows.append(row)

    return rows


def aggregate_run_level(config: tuple, runs: list[dict]) -> list[dict]:
    """Aggregate the quantities that belong to a whole run rather than to a point."""
    values: dict[str, list[float]] = defaultdict(list)

    for run in runs:
        for metric, value in run["latency"].items():
            values[metric].append(value)

        for metric, value in run["workload"].items():
            values[metric].append(value)

        if run["elapsed_ms"] is not None:
            values["wall_clock_ms"].append(run["elapsed_ms"])

        if run["peers"] is not None:
            values["peers"].append(run["peers"])

    rows = []

    for metric, observations in sorted(values.items()):
        row = dict(zip(CONFIG_KEYS, config))
        row.update({"axis": "run", "point": 0, "metric": metric})
        row.update(summarize(observations))
        row["values"] = observations
        rows.append(row)

    return rows


########################################################################################
# Writing
########################################################################################

COLUMNS = list(CONFIG_KEYS) + [
    "axis", "point", "metric", "n", "mean", "sd", "ci_low", "ci_high",
    "min", "max", "deterministic",
]


def write_outputs(rows: list[dict], runs: list[dict], out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)

    with open(os.path.join(out_dir, "summary.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    with open(os.path.join(out_dir, "summary.json"), "w") as handle:
        json.dump(rows, handle, indent=2)

    with open(os.path.join(out_dir, "runs.csv"), "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(list(CONFIG_KEYS) + ["seed", "status", "ground_truth", "elapsed_ms",
                                             "peers", "directory"])

        for run in sorted(runs, key=lambda r: (str(r["config"]), r["seed"] or 0)):
            writer.writerow(
                list(run["config"])
                + [run["seed"], run["status"], run["ground_truth"], run["elapsed_ms"],
                   run["peers"], run["directory"]]
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", default="debug/runs", help="directory holding the runs")
    parser.add_argument("--out", default="debug/aggregate", help="where to write the summary")
    arguments = parser.parse_args()

    if not os.path.isdir(arguments.runs):
        raise SystemExit(f"no run directory at {arguments.runs}")

    runs = []
    for name in sorted(os.listdir(arguments.runs)):
        directory = os.path.join(arguments.runs, name)
        if not os.path.isdir(directory):
            continue

        run = read_run(directory)
        if run is not None:
            runs.append(run)

    if not runs:
        raise SystemExit(f"no run with a manifest under {arguments.runs}")

    print(f"Read {len(runs)} run(s) from {arguments.runs}")

    rows = aggregate(runs)
    write_outputs(rows, runs, arguments.out)

    configurations = {run["config"] for run in runs}
    varying = sum(1 for row in rows if not row["deterministic"])

    print(f"Wrote {len(rows)} rows over {len(configurations)} configuration(s) to {arguments.out}")
    print(f"  {varying} vary across runs and carry an interval; "
          f"{len(rows) - varying} are the same in every run and do not")


if __name__ == "__main__":
    main()
