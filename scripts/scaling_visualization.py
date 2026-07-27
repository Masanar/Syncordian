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
one network size, with the range those runs covered and the individual runs behind it. A quantity
that does not vary across runs is drawn without a band, because the aggregate marks it deterministic
and there is no uncertainty to show.

The band is the observed range and not the Student interval the aggregate also carries, which is the
same choice ``data_visualization.py`` and ``heap_size_visualization.py`` make and for the same
reason: an identically styled band has to mean one thing across the paper's figures, and at three
repetitions a symmetric interval on a count can extend below zero. The intervals are unchanged in
``summary.json`` and are quoted beside numbers by ``ws9_numbers.py``.

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
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

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
    "replacement_issued_counter": {"name": "Lines re-issued in total", "color": "#ff006e", "linestyle": "-.", "linewidth": 1.4},
    "insert_amplification": {"name": "Insert messages, over the authored prediction", "color": "#008300", "linestyle": "-", "linewidth": 1.8},
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
        ("conflicts_observed", "replacement_issued_counter", "reissued_lines_mean", "insert_amplification"),
        "Count, and the traffic ratio",
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
    """Draws one metric as a mean, the range the runs covered, and the runs behind it.

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
            [row["min"] for row in points],
            [row["max"] for row in points],
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


def legend_with_band(axes, behind: str, show_runs: bool = True) -> None:
    """The legend, with an entry for the band and one for the per-run dots.

    Every series is drawn as three things in one colour, a line, a translucent band and a scatter of
    points. A reader told only "shaded range" in nine point type above the axes has to guess which of
    the three that names, so the band and the dots are named where the series are named.
    """
    handles, labels = axes.get_legend_handles_labels()

    handles.append(Patch(facecolor="0.35", alpha=0.18, linewidth=0, label=f"range across {behind}"))
    labels.append(f"range across {behind}")

    if show_runs:
        handles.append(
            Line2D([], [], marker=".", markersize=4, linestyle="none", color="0.35", alpha=0.6)
        )
        labels.append("individual runs")

    axes.legend(handles, labels, loc="best", frameon=True, fancybox=True, shadow=True, fontsize=8)


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

    # The reader has to know how many runs are behind a band without leaving the figure, and has to
    # be told when the points do not all rest on the same number of runs.
    fewest = min((row["n"] for row in rows if row["axis"] == "peers"), default=0)
    behind = f"{repetitions} runs" if fewest == repetitions else f"{fewest} to {repetitions} runs"

    legend_with_band(axes, behind)
    axes.grid(True, which="both", alpha=0.4)

    axes.set_title(
        f"mean of {behind}, shaded range across runs",
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

    The two agree to within a hundredth at every point measured, and that is a drawing problem as
    much as a result: two overlapping lines of similar weight read as one line, and a reader cannot
    tell agreement from a missing series. So the prediction is drawn first and wide and pale, as a
    reference the measurement sits inside, and the measurement is drawn over it as markers. Both
    remain visible where they coincide, which is everywhere.
    """
    points = series_for(rows, "acks_per_insert")

    if not points:
        print(f"  nothing to draw for {output}")
        return False

    figure, axes = plt.subplots(figsize=(8, 6))
    axes.set_xlabel("Number of replicas")
    axes.set_ylabel("Acknowledgement messages per insert")

    x = [row["point"] for row in points]
    axes.plot(
        x,
        [point - 1 for point in x],
        label="Predicted, $n - 1$",
        color="#3d405b",
        linestyle="-",
        linewidth=7,
        alpha=0.25,
        solid_capstyle="round",
        zorder=1,
    )

    draw(axes, points, "acks_per_insert", show_runs=True)

    axes.set_xscale("log", base=2)
    axes.set_yscale("log", base=2)
    axes.set_xticks(x)
    axes.set_xticklabels([str(point) for point in x])
    axes.set_yticks([point - 1 for point in x])
    axes.set_yticklabels([str(point - 1) for point in x])

    repetitions = max((row["n"] for row in points), default=0)
    legend_with_band(axes, f"{repetitions} runs")
    axes.grid(True, which="both", alpha=0.4)
    axes.set_title(
        f"mean of {repetitions} runs, shaded range across runs",
        fontsize=9,
        loc="right",
    )

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")
    return True


def plot_paper_panels(rows: list[dict], output: str) -> bool:
    """The two panels the paper prints, drawn as one figure rather than two.

    The seven figures above are diagnostics, sized to be read on their own at eight inches wide. Two
    of them also carry an argument the paper makes, and putting those two side by side in LaTeX does
    not work: each would be scaled to under half the text width of a two-column page, which takes a
    ten point label down to about four points. So the pair is drawn here at the width it will be
    printed at, and the paper includes this one file. Same data, same summaries, same band.
    """
    acks = series_for(rows, "acks_per_insert")
    amplification = [
        (metric, series_for(rows, metric))
        for metric in ("conflicts_observed", "replacement_issued_counter", "reissued_lines_mean", "insert_amplification")
    ]

    if not acks:
        print(f"  nothing to draw for {output}")
        return False

    figure, (left, right) = plt.subplots(1, 2, figsize=(9.4, 3.6))
    x = [row["point"] for row in acks]
    repetitions = max((row["n"] for row in acks), default=0)

    # Left: the measurement inside the prediction. Wide and pale underneath, so the coincidence reads
    # as agreement rather than as one missing series.
    left.plot(
        x,
        [point - 1 for point in x],
        label="Predicted, $n - 1$",
        color="#3d405b",
        linestyle="-",
        linewidth=8,
        alpha=0.25,
        solid_capstyle="round",
        zorder=1,
    )
    draw(left, acks, "acks_per_insert", show_runs=True)
    left.set_ylabel("Acknowledgements per \\texttt{insert}" if plt.rcParams["text.usetex"]
                    else "Acknowledgements per insert")
    left.set_yscale("log", base=2)
    left.set_yticks([point - 1 for point in x])
    left.set_yticklabels([str(point - 1) for point in x])

    # Right: what the repair adds. Logarithmic, because a ratio near unity, a block of eight and a
    # conflict count in the thousands do not share a linear axis.
    for metric, points in amplification:
        draw(right, points, metric, show_runs=True)
    right.set_ylabel("Count, and the traffic ratio")
    right.set_yscale("log")

    for axes in (left, right):
        axes.set_xlabel("Number of replicas")
        axes.set_xscale("log", base=2)
        axes.set_xticks(x)
        axes.set_xticklabels([str(point) for point in x])
        axes.grid(True, which="both", alpha=0.4)
        legend_with_band(axes, f"{repetitions} runs")

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
            # Traffic totals and latencies span orders of magnitude across the ladder, so those are
            # drawn on a logarithmic vertical axis. The rest are read as absolutes. The amplification
            # figure joined them for a different reason: it puts four series in one axis whose
            # magnitudes are a ratio near unity, a block size of eight, and a conflict count in the
            # thousands, and on a linear axis the first two lie flat on the horizontal axis.
            logy = stem in (
                "scaling_acknowledgement_traffic",
                "scaling_settle_latency",
                "scaling_replacement_amplification",
            )

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

        if plot_paper_panels(
            sweep, os.path.join(arguments.figures, f"scaling_paper_panels_{label}.pdf")
        ):
            drawn += 1

    if drawn == 0:
        raise SystemExit("no figure could be drawn from this aggregate")


if __name__ == "__main__":
    main()
