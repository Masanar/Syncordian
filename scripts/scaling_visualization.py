"""The scaling figures, drawn from the aggregate of the peer-count sweep.

Answers the question the git replay cannot: what the costs do as the number of replicas grows. A
replay has as many replicas as the file had authors, and that is not a knob, so the sweep is run on
the synthetic workload instead (``scripts/scalability_sweep.exs``).

Six figures, one per quantity the review asks about:

1. bytes per operation
2. acknowledgement traffic, beside the operation traffic it accompanies, with the measured number of
   acknowledgements per insert drawn against the ``n - 1`` that is predicted
3. settle latency percentiles
4. memory per line at one replica, which is where the per-line response checklist shows
5. queue depth
6. re-placement amplification, with the number of conflicts that produced it

Like ``data_visualization.py`` this script reads only the long-format summary, so it never sees an
individual run and never decides how a number was summarized. Every point is a mean over the runs at
one network size, with a 95% interval and the individual runs behind it. A quantity that does not
vary across runs is drawn without a band, because the aggregate marks it deterministic and there is
no uncertainty to show.

The horizontal axis is logarithmic with base two, because the ladder doubles at each step. A
quantity that grows linearly in the number of replicas is then a curve and one that grows
quadratically is a steeper curve, so figure 2 also reports the measured ratio, where a quadratic
total shows as a straight line against its prediction.

Run from ``Code/``, after the sweep and the aggregation::

    mix run --no-start scripts/scalability_sweep.exs --quick --root debug/sweep
    python scripts/aggregate_runs.py --runs debug/sweep --out debug/sweep-aggregate
    python scripts/scaling_visualization.py --aggregate debug/sweep-aggregate/summary.json

Figures are written to ``Code/figures/``.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

import matplotlib.pyplot as plt

# Display name, colour, and line style for each metric, in the same form
# ``data_visualization.py`` uses so the two sets of figures read as one evaluation.
METRIC_PROPERTIES = {
    "bytes_per_insert": {"name": "Bytes per insert", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "bytes_per_ack": {"name": "Bytes per acknowledgement", "color": "#008300", "linestyle": "--", "linewidth": 1.6},
    "bytes_per_delete": {"name": "Bytes per delete", "color": "#eb6834", "linestyle": "-.", "linewidth": 1.4},
    "bytes_insert": {"name": "Insert traffic", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "bytes_ack": {"name": "Acknowledgement traffic", "color": "#d00000", "linestyle": "--", "linewidth": 1.8},
    "bytes_total": {"name": "All traffic", "color": "#03071e", "linestyle": ":", "linewidth": 1.4},
    "msgs_insert": {"name": "Insert messages", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "msgs_ack": {"name": "Acknowledgement messages", "color": "#d00000", "linestyle": "--", "linewidth": 1.8},
    "acks_per_insert": {"name": "Acknowledgements per insert, measured", "color": "#d00000", "linestyle": "-", "linewidth": 1.8},
    "settle_latency_us_p50": {"name": "Settle latency, median", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "settle_latency_us_p95": {"name": "Settle latency, 95th percentile", "color": "#7209b7", "linestyle": "--", "linewidth": 1.6},
    "settle_latency_us_p99": {"name": "Settle latency, 99th percentile", "color": "#d00000", "linestyle": "-.", "linewidth": 1.6},
    "apply_latency_us_p50": {"name": "Apply latency, median", "color": "#008300", "linestyle": ":", "linewidth": 1.4},
    "bytes_per_line": {"name": "Bytes per line, one replica", "color": "#4a3aa7", "linestyle": "-", "linewidth": 1.8},
    "document_bytes": {"name": "Document size, one replica", "color": "#3d405b", "linestyle": "--", "linewidth": 1.4},
    "message_queue_length": {"name": "Deepest mailbox observed", "color": "#e85d04", "linestyle": "-", "linewidth": 1.6},
    "reissued_lines_mean": {"name": "Lines re-issued per conflict", "color": "#7209b7", "linestyle": "-", "linewidth": 1.8},
    "conflicts_observed": {"name": "Interleavings observed", "color": "#03071e", "linestyle": "--", "linewidth": 1.4},
    "replacement_issued_counter": {"name": "Re-placements issued", "color": "#ff006e", "linestyle": "-.", "linewidth": 1.4},
    "pid_depth_max": {"name": "Deepest position identifier", "color": "#008300", "linestyle": ":", "linewidth": 1.4},
    "mac_median_us": {"name": "Authenticator time, median", "color": "#eb6834", "linestyle": "-", "linewidth": 1.6},
}

# The six figures, as (file name, metrics, vertical label). The order is the order the review lists
# the quantities in.
FIGURES = (
    (
        "scaling_bytes_per_operation",
        ("bytes_per_insert", "bytes_per_ack", "bytes_per_delete"),
        "Bytes per message",
    ),
    (
        "scaling_acknowledgement_traffic",
        ("bytes_total", "bytes_ack", "bytes_insert"),
        "Bytes over the whole run",
    ),
    (
        "scaling_settle_latency",
        ("settle_latency_us_p99", "settle_latency_us_p95", "settle_latency_us_p50", "apply_latency_us_p50"),
        "Microseconds",
    ),
    (
        "scaling_memory_per_line",
        ("bytes_per_line",),
        "Bytes per line, one replica",
    ),
    (
        "scaling_queue_depth",
        ("message_queue_length", "pid_depth_max"),
        "Depth",
    ),
    (
        "scaling_replacement_amplification",
        ("conflicts_observed", "replacement_issued_counter", "reissued_lines_mean"),
        "Count",
    ),
)


def load(path: str) -> list[dict]:
    with open(path) as handle:
        return json.load(handle)


def properties_of(metric: str) -> dict:
    return METRIC_PROPERTIES.get(metric, {"name": metric, "color": "black", "linestyle": "-"})


def sweep_over_peers(rows: list[dict]) -> list[dict]:
    """Recasts the run-level values as a series over the size of the network.

    The peer count is a configuration column rather than a position on an axis, because two network
    sizes are two different experiments and the aggregate is right to keep them apart. Turning it
    into an axis is a presentation decision and belongs here, not in the aggregation.
    """
    return [
        {**row, "axis": "peers", "point": int(row["peer_count"])}
        for row in rows
        if row["axis"] == "run" and row["peer_count"]
    ]


def draw(axes, points: list[dict], metric: str, show_runs: bool) -> bool:
    """Draws one metric as a mean, an interval, and the runs behind it.

    Returns whether anything was drawn: a metric that is zero at every point is left out, because an
    empty series in a legend claims a measurement that carries no information.
    """
    if not points or not any(row["mean"] for row in points):
        return False

    properties = properties_of(metric)
    x = [row["point"] for row in points]
    mean = [row["mean"] for row in points]

    axes.plot(
        x,
        mean,
        label=properties["name"],
        color=properties["color"],
        linestyle=properties.get("linestyle", "-"),
        linewidth=properties.get("linewidth", 1),
        marker="o",
        markersize=3.5,
    )

    # No band on a quantity whose variance across runs is zero. See aggregate_runs.py.
    if any(not row["deterministic"] for row in points):
        axes.fill_between(
            x,
            [row["ci_low"] for row in points],
            [row["ci_high"] for row in points],
            color=properties["color"],
            alpha=0.18,
            linewidth=0,
        )

    if show_runs:
        for row in points:
            axes.plot(
                [row["point"]] * len(row.get("values", [])),
                row.get("values", []),
                marker=".",
                markersize=2,
                linestyle="none",
                color=properties["color"],
                alpha=0.35,
            )

    return True


def series_for(rows: list[dict], metric: str) -> list[dict]:
    return sorted(
        (row for row in rows if row["metric"] == metric and row["axis"] == "peers"),
        key=lambda row: row["point"],
    )


def plot(rows: list[dict], metrics, ylabel: str, output: str, logy: bool = False) -> bool:
    figure, axes = plt.subplots(figsize=(8, 6))
    axes.set_xlabel("Number of replicas")
    axes.set_ylabel(ylabel)

    drawn = 0
    repetitions = max((row["n"] for row in rows), default=0)

    for metric in metrics:
        if draw(axes, series_for(rows, metric), metric, show_runs=True):
            drawn += 1

    if drawn == 0:
        plt.close(figure)
        print(f"  nothing to draw for {output}")
        return False

    # The ladder doubles at each step, so the axis does too. Labelled with the actual counts rather
    # than with powers, because the counts are what the sweep was run at.
    points = sorted({row["point"] for row in rows if row["axis"] == "peers"})
    axes.set_xscale("log", base=2)
    axes.set_xticks(points)
    axes.set_xticklabels([str(point) for point in points])

    if logy:
        axes.set_yscale("log")

    axes.legend(loc="best", frameon=True, fancybox=True, shadow=True)
    axes.grid(True, which="both", alpha=0.4)

    # The reader has to know how many runs are behind a band without leaving the figure, and has to
    # be told when the points do not all rest on the same number of runs.
    fewest = min((row["n"] for row in rows if row["axis"] == "peers"), default=0)
    behind = f"{repetitions} runs" if fewest == repetitions else f"{fewest} to {repetitions} runs"

    axes.set_title(
        f"mean of {behind}, shaded 95% confidence interval",
        fontsize=9,
        loc="right",
    )

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")
    return True


def plot_acks_per_insert(rows: list[dict], output: str) -> bool:
    """The measured acknowledgements per insert, against the count that is predicted.

    This is the figure that answers the scalability remark most directly. The argument is that each
    insert makes every other replica acknowledge, so the cost per insert should be ``n - 1`` and the
    total should grow as the square of the network. Drawing the measurement next to that prediction
    turns the argument into something a reader can check rather than accept.
    """
    points = series_for(rows, "acks_per_insert")

    if not points:
        print(f"  nothing to draw for {output}")
        return False

    figure, axes = plt.subplots(figsize=(8, 6))
    axes.set_xlabel("Number of replicas")
    axes.set_ylabel("Acknowledgement messages per insert")

    draw(axes, points, "acks_per_insert", show_runs=True)

    x = [row["point"] for row in points]
    axes.plot(
        x,
        [point - 1 for point in x],
        label="Predicted, $n - 1$",
        color="#3d405b",
        linestyle=":",
        linewidth=1.6,
    )

    axes.set_xscale("log", base=2)
    axes.set_xticks(x)
    axes.set_xticklabels([str(point) for point in x])
    axes.legend(loc="best", frameon=True, fancybox=True, shadow=True)
    axes.grid(True, which="both", alpha=0.4)

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")
    return True


def group_by_workload(rows: list[dict]) -> dict[tuple, list[dict]]:
    """One sweep per workload and environment. Two workloads are not two points of one curve."""
    grouped = defaultdict(list)

    for row in rows:
        if str(row["workload"]).startswith("synthetic:"):
            grouped[(row["crdt"], row["workload"], row["scenario"], row["delay"])].append(row)

    return grouped


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aggregate", default="debug/sweep-aggregate/summary.json")
    parser.add_argument("--figures", default="figures")
    arguments = parser.parse_args()

    if not os.path.exists(arguments.aggregate):
        raise SystemExit(
            f"no aggregate at {arguments.aggregate}; run the sweep and then "
            "scripts/aggregate_runs.py --runs debug/sweep --out debug/sweep-aggregate"
        )

    rows = load(arguments.aggregate)
    os.makedirs(arguments.figures, exist_ok=True)

    groups = group_by_workload(rows)

    if not groups:
        raise SystemExit(
            "the aggregate holds no synthetic runs, so there is no peer sweep to draw; "
            "run scripts/scalability_sweep.exs first"
        )

    drawn = 0

    for (crdt, workload, scenario, _delay), group in sorted(groups.items()):
        sweep = sweep_over_peers(group)
        sizes = sorted({row["point"] for row in sweep})

        if len(sizes) < 2:
            print(
                f"skipping {workload}: the sweep has only {len(sizes)} network size, "
                "and a scaling figure needs at least two"
            )
            continue

        name = workload.split(":", 1)[1]
        label = f"{crdt}_{name}_{scenario}"
        print(f"{workload} over {sizes}")

        for stem, metrics, ylabel in FIGURES:
            # Traffic totals and latencies span orders of magnitude across the ladder, so those two
            # are drawn on a logarithmic vertical axis. The rest are read as absolutes.
            logy = stem in ("scaling_acknowledgement_traffic", "scaling_settle_latency")

            if plot(
                sweep,
                metrics,
                ylabel,
                os.path.join(arguments.figures, f"{stem}_{label}.pdf"),
                logy=logy,
            ):
                drawn += 1

        if plot_acks_per_insert(
            sweep, os.path.join(arguments.figures, f"scaling_acks_per_insert_{label}.pdf")
        ):
            drawn += 1

    if drawn == 0:
        raise SystemExit("no figure could be drawn from this aggregate")


if __name__ == "__main__":
    main()
