"""Prints the numbers the evaluation rewrite quotes, grouped the way it quotes them.

The aggregate that ``aggregate_runs.py`` writes is a long table of every metric at every point, and
it is the right shape for plotting and the wrong shape for writing a paragraph. This script reads it
and prints only the quantities the evaluation section states in prose, each with the interval and
the number of runs behind it, so a sentence can be checked against a run rather than against a
memory of one.

It computes nothing. Every value here is read from the aggregate exactly as the aggregation formed
it, so a number in the paper, a number in a figure, and a number printed here cannot disagree.

Usage, with whichever aggregates exist::

    python3 scripts/ws9_numbers.py \\
      --git debug/git-aggregate/summary.json \\
      --workloads debug/workloads-aggregate/summary.json \\
      --sweep debug/sweep-aggregate/summary.json

A value is printed as ``mean [low, high] (R runs)``. A quantity that does not vary between runs is
printed as ``mean (fixed, R runs)`` and carries no interval, because under a fixed workload the
number of operations and the bytes they occupy are the same every time.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

BAR = "=" * 88


def load(path: str) -> list[dict]:
    with open(path) as handle:
        return json.load(handle)


def fmt(row: dict | None, scale: float = 1.0, unit: str = "") -> str:
    """One value, with its interval and the number of runs behind it."""
    if row is None:
        return "not measured"

    mean = row["mean"] / scale
    suffix = f" {unit}" if unit else ""

    if row["deterministic"]:
        return f"{mean:,.2f}{suffix} (fixed, {row['n']} runs)"

    low = row["ci_low"] / scale
    high = row["ci_high"] / scale
    return f"{mean:,.2f}{suffix} [{low:,.2f}, {high:,.2f}] ({row['n']} runs)"


def at_run(rows: list[dict], metric: str) -> dict | None:
    """A run-level value: latency percentiles, and everything a synthetic workload reports."""
    for row in rows:
        if row["axis"] == "run" and row["metric"] == metric:
            return row
    return None


def at_end(rows: list[dict], metric: str) -> dict | None:
    """A counter's value at the last commit, which for a cumulative counter is the run total."""
    points = [row for row in rows if row["axis"] == "commit" and row["metric"] == metric]
    return max(points, key=lambda row: row["point"]) if points else None


def total(rows: list[dict], metric: str) -> dict | None:
    """Wherever the metric lives. Git runs report counters per commit, synthetic runs per run."""
    return at_end(rows, metric) or at_run(rows, metric)


def group(rows: list[dict], keys) -> dict[tuple, list[dict]]:
    grouped = defaultdict(list)
    for row in rows:
        grouped[tuple(row[key] for key in keys)].append(row)
    return grouped


def label_of(workload: str, tracked_file: str) -> str:
    if str(workload).startswith("synthetic:"):
        return workload.split(":", 1)[1]
    return os.path.basename(tracked_file) or "unknown"


########################################################################################
# 1. Complexity, with a measured absolute beside each asymptotic term
########################################################################################


def complexity(rows: list[dict]) -> None:
    print(f"\n{BAR}\n1. COMPLEXITY: the measured absolute beside each asymptotic term\n{BAR}")

    for (crdt, workload, tracked_file, scenario, adversaries), group_rows in sorted(
        group(rows, ("crdt", "workload", "tracked_file", "scenario", "adversaries")).items()
    ):
        if crdt != "syncordian" or scenario != "baseline" or adversaries != 0:
            continue

        print(f"\n  {label_of(workload, tracked_file)}  ({workload})")

        print("    per-message size")
        for metric, name in (
            ("bytes_per_insert", "insert"),
            ("bytes_per_delete", "delete"),
            ("bytes_per_ack", "acknowledgement"),
        ):
            print(f"      {name:<18} {fmt(total(group_rows, metric), unit='B')}")

        print("    message counts, and the O(n^2) term")
        for metric, name in (
            ("msgs_insert", "inserts"),
            ("msgs_delete", "deletes"),
            ("msgs_ack", "acknowledgements"),
            ("msgs_fetch", "fetches"),
        ):
            print(f"      {name:<18} {fmt(total(group_rows, metric))}")

        acks = total(group_rows, "msgs_ack")
        inserts = total(group_rows, "msgs_insert")
        if acks and inserts and inserts["mean"]:
            print(f"      {'acks per insert':<18} {acks['mean'] / inserts['mean']:,.2f}  (predicted n - 1)")

        print("    traffic, total against operations only")
        by_kind = {
            kind: total(group_rows, f"bytes_{kind}") for kind in ("insert", "delete", "ack", "fetch")
        }
        whole = total(group_rows, "bytes_total")
        operations = sum(
            by_kind[kind]["mean"] for kind in ("insert", "delete") if by_kind[kind]
        )

        print(f"      {'all traffic':<18} {fmt(whole, scale=1024, unit='kB')}")
        print(f"      {'operations only':<18} {operations / 1024:,.2f} kB")
        if whole and whole["mean"]:
            print(f"      {'acknowledgements':<18} {fmt(by_kind['ack'], scale=1024, unit='kB')}"
                  f"  = {100 * by_kind['ack']['mean'] / whole['mean']:.1f}% of all bytes")

        print("    authenticator cost")
        for metric, name in (("mac_median_us", "median"), ("mac_mean_us", "mean")):
            print(f"      {name:<18} {fmt(total(group_rows, metric), unit='us')}")

        print("    position identifier depth")
        for metric, name in (("pid_depth_mean", "mean"), ("pid_depth_max", "deepest")):
            print(f"      {name:<18} {fmt(total(group_rows, metric))}")

        print("    latency, microseconds")
        for metric, name in (
            ("apply_latency_us_p50", "apply p50"),
            ("apply_latency_us_p99", "apply p99"),
            ("settle_latency_us_p50", "settle p50"),
            ("settle_latency_us_p95", "settle p95"),
            ("settle_latency_us_p99", "settle p99"),
        ):
            print(f"      {name:<18} {fmt(at_run(group_rows, metric))}")

        print("    memory and queues")
        for metric, name in (
            ("heap_size", "document bytes"),
            ("bytes_per_line", "bytes per line"),
            ("origin_log_bytes", "origin log bytes"),
            ("message_queue_length", "deepest mailbox"),
        ):
            print(f"      {name:<18} {fmt(total(group_rows, metric))}")


########################################################################################
# 2. Transient interleaving
########################################################################################


def transient(rows: list[dict]) -> None:
    print(f"\n{BAR}\n2. TRANSIENT INTERLEAVING: what the repair protocol did\n{BAR}")
    print("\n  A row of zeros is a result, not a gap. The commit replay serializes the authoring,")
    print("  so it constructs no interleaving at all; the controlled workloads are what do.\n")

    # The adversary count is in the key. Without it the six counts of one scenario merged into one
    # group, and `at_end` takes the row at the highest commit, which several configurations tie on.
    # It then reported one of them, chosen by iteration order, under a label naming only the
    # scenario. Every counter here is a deterministic zero on the histories, so nothing printed was
    # wrong, but the number reported was not the one the label named.
    for (crdt, workload, tracked_file, scenario, adversaries), group_rows in sorted(
        group(rows, ("crdt", "workload", "tracked_file", "scenario", "adversaries")).items()
    ):
        if crdt != "syncordian":
            continue

        conflicts = total(group_rows, "conflicts_observed")
        distrusted = f", {adversaries} distrusted" if adversaries else ""
        print(f"\n  {label_of(workload, tracked_file)}  ({scenario}{distrusted})")
        print(f"      {'interleavings seen':<26} {fmt(conflicts)}")
        print(f"      {'most at once':<26} {fmt(total(group_rows, 'max_concurrent_conflicts'))}")
        print(f"      {'re-placements issued':<26} {fmt(total(group_rows, 'replacement_issued_counter'))}")
        print(f"      {'live duplicates, most':<26} {fmt(total(group_rows, 'live_duplicates_max'))}")
        print(f"      {'alias entries':<26} {fmt(total(group_rows, 'alias_entries'))}")
        print(f"      {'deletes following an alias':<26} {fmt(total(group_rows, 'delete_followed_alias'))}")

        if conflicts is None or not conflicts["mean"]:
            print("      (no interleaving was constructed, so there is no repair to report)")
            continue

        print("    amplification: lines re-issued per conflict")
        for metric, name in (
            ("reissued_lines_mean", "mean"),
            ("reissued_lines_p95", "p95"),
            ("reissued_lines_max", "most"),
        ):
            print(f"      {name:<26} {fmt(at_run(group_rows, metric))}")

        print("    repair latency, in edits")
        for metric, name in (
            ("repair_latency_edits_p50", "p50"),
            ("repair_latency_edits_p95", "p95"),
            ("repair_latency_edits_max", "longest"),
        ):
            print(f"      {name:<26} {fmt(at_run(group_rows, metric))}")

        print("    repair latency, in milliseconds")
        for metric, name in (
            ("repair_latency_ms_p50", "p50"),
            ("repair_latency_ms_p95", "p95"),
            ("repair_latency_ms_max", "longest"),
        ):
            print(f"      {name:<26} {fmt(at_run(group_rows, metric))}")


########################################################################################
# 3. Baseline comparison
########################################################################################


def baselines(rows: list[dict]) -> None:
    print(f"\n{BAR}\n3. BASELINES: absolutes, with the traffic each one does not pay for\n{BAR}")
    print("\n  Syncordian is shown twice: all its traffic, and its operations only. The baselines")
    print("  send no acknowledgements and compute no authenticators, so the second column is the")
    print("  comparison that is like for like and the first is the price of the guarantees.\n")

    by_history = group(rows, ("workload", "tracked_file"))

    for (workload, tracked_file), history_rows in sorted(by_history.items()):
        print(f"\n  {label_of(workload, tracked_file)}")
        header = f"      {'crdt':<12}{'all bytes':>16}{'ops bytes':>16}{'all msgs':>12}{'ops msgs':>12}{'doc bytes':>14}"
        print(header)

        for (crdt, scenario, adversaries), group_rows in sorted(
            group(history_rows, ("crdt", "scenario", "adversaries")).items()
        ):
            if scenario != "baseline" or adversaries != 0:
                continue

            def value(metric):
                row = total(group_rows, metric)
                return row["mean"] if row else 0.0

            ops_bytes = value("bytes_insert") + value("bytes_delete")
            ops_msgs = value("msgs_insert") + value("msgs_delete")

            print(
                f"      {crdt:<12}{value('bytes_total'):>16,.0f}{ops_bytes:>16,.0f}"
                f"{value('msgs_insert') + value('msgs_delete') + value('msgs_ack') + value('msgs_fetch'):>12,.0f}"
                f"{ops_msgs:>12,.0f}{value('heap_size'):>14,.0f}"
            )


########################################################################################
# 4. The ladder
########################################################################################


SWEEP_ROWS = (
    ("bytes_per_insert", "bytes per insert"),
    ("acks_per_insert", "acks per insert"),
    ("bytes_ack", "ack bytes"),
    ("bytes_total", "all bytes"),
    ("bytes_per_line", "bytes per line"),
    ("settle_latency_us_p50", "settle p50 us"),
    ("settle_latency_us_p99", "settle p99 us"),
    ("message_queue_length", "deepest mailbox"),
    ("pid_depth_max", "deepest pid"),
    ("mac_median_us", "authenticator us"),
    ("conflicts_observed", "interleavings"),
    ("reissued_lines_mean", "lines per repair"),
    ("wall_clock_ms", "wall clock ms"),
)


def ladder(rows: list[dict]) -> None:
    print(f"\n{BAR}\n4. THE LADDER: every quantity against the number of replicas\n{BAR}")

    for (crdt, workload, scenario), group_rows in sorted(
        group(rows, ("crdt", "workload", "scenario")).items()
    ):
        if not str(workload).startswith("synthetic:"):
            continue

        sizes = sorted({row["peer_count"] for row in group_rows if row["peer_count"]})
        if len(sizes) < 2:
            continue

        print(f"\n  {label_of(workload, '')}  ({scenario})")
        print(f"      {'quantity':<20}" + "".join(f"{'n=' + str(size):>16}" for size in sizes))

        for metric, name in SWEEP_ROWS:
            cells = ""
            for size in sizes:
                subset = [row for row in group_rows if row["peer_count"] == size]
                row = at_run(subset, metric) or at_end(subset, metric)
                cells += f"{row['mean']:>16,.2f}" if row else f"{'-':>16}"
            print(f"      {name:<20}{cells}")

        # Whether the measurement matches what the argument predicts, which is the point of the
        # sweep rather than a decoration on it.
        print(f"      {'predicted n - 1':<20}" + "".join(f"{size - 1:>16,.2f}" for size in sizes))

        counts = []
        for size in sizes:
            subset = [row for row in group_rows if row["peer_count"] == size and row["axis"] == "run"]
            counts.append(max((row["n"] for row in subset), default=0))

        print(f"      {'runs behind point':<20}" + "".join(f"{count:>16}" for count in counts))

        if len(set(counts)) > 1:
            print("\n      Note: the points do not rest on the same number of runs. Say so in the")
            print("      caption, or drop the short ones.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git", help="aggregate of the git replays")
    parser.add_argument("--workloads", help="aggregate of the controlled workloads")
    parser.add_argument("--sweep", help="aggregate of the peer-count sweep")
    arguments = parser.parse_args()

    given = [path for path in (arguments.git, arguments.workloads, arguments.sweep) if path]

    if not given:
        raise SystemExit("give at least one of --git, --workloads, --sweep")

    for path in given:
        if not os.path.exists(path):
            raise SystemExit(f"no aggregate at {path}")

    if arguments.git:
        rows = load(arguments.git)
        complexity(rows)
        transient(rows)
        baselines(rows)

    if arguments.workloads:
        transient(load(arguments.workloads))

    if arguments.sweep:
        sweep = load(arguments.sweep)
        complexity(sweep)
        ladder(sweep)


if __name__ == "__main__":
    main()
