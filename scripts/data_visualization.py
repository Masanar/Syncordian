"""Figures for the evaluation, drawn from the aggregate of repeated runs.

Reads the long-format summary that ``aggregate_runs.py`` writes, so this script never sees
an individual run and never decides how a number was summarized. Every series is a mean over
the runs of one configuration, shown with a 95% confidence interval and with the individual
runs drawn behind it. The individual runs are drawn deliberately: with ten repetitions a
reader should be able to see the spread rather than only a summary of it.

A quantity that does not vary across runs is drawn as a plain line with no band, because the
aggregate marks it deterministic and there is no uncertainty to show.

Run from ``Code/``, after ``aggregate_runs.py``::

    python scripts/aggregate_runs.py
    python scripts/data_visualization.py

Figures are written to ``Code/figures/``.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

import matplotlib.pyplot as plt

# Display name, colour, and line style for each metric. The keys are the aggregate's metric
# names; `_delta` names the per-commit work, computed inside each run before averaging.
METRIC_PROPERTIES = {
    "delete_stash_counter_delta": {"name": "Delete stash activate", "color": "#03071e", "linestyle": "-"},
    "delete_valid_counter_delta": {"name": "Valid delete messages", "color": "#eb6834", "linestyle": "--", "linewidth": 1.6},
    "insert_distance_greater_than_one_delta": {
        "name": "Insert messages ahead of local clock",
        "color": "#4a3aa7",
        "linestyle": "-.",
        "linewidth": 1.6,
    },
    "insert_valid_counter_delta": {"name": "Valid insert messages", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "settle_counter_delta": {
        "name": "Lines settled (acknowledged by all peers)",
        "color": "#008300",
        "linestyle": ":",
        "linewidth": 2,
    },
    "byzantine_delete_counter": {
        "name": "Delete messages Distrusted nodes",
        "color": "#e85d04",
        "linestyle": "-.",
        "linewidth": 1,
    },
    "byzantine_insert_counter": {
        "name": "Insert messages Distrusted nodes",
        "color": "#3d405b",
        "linestyle": ":",
        "linewidth": 1.2,
    },
    "byzantine_replay_counter": {
        "name": "Genuine messages replayed by distrusted nodes",
        "color": "#7209b7",
        "linestyle": "--",
        "linewidth": 1.2,
    },
    "admission_rejected_counter": {
        "name": "Messages rejected at admission",
        "color": "#d00000",
        "linestyle": "-.",
        "linewidth": 1.2,
    },
    "replay_rejected_counter": {
        "name": "Messages recognized as already applied",
        "color": "#ff006e",
        "linestyle": ":",
        "linewidth": 1.2,
    },
    "insert_valid_counter": {"name": "Valid insert messages", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},
    "delete_valid_counter": {"name": "Valid delete messages", "color": "#eb6834", "linestyle": "--", "linewidth": 1.6},
}

# The series each figure carries.
PER_COMMIT_METRICS = (
    "insert_valid_counter_delta",
    "delete_valid_counter_delta",
    "insert_distance_greater_than_one_delta",
    "settle_counter_delta",
)

ADVERSARY_SWEEP_METRICS = (
    "byzantine_insert_counter",
    "byzantine_delete_counter",
    "byzantine_replay_counter",
    "admission_rejected_counter",
    "replay_rejected_counter",
    "insert_valid_counter",
    "delete_valid_counter",
)


def load(path: str) -> list[dict]:
    with open(path) as handle:
        return json.load(handle)


def properties_of(metric: str) -> dict:
    return METRIC_PROPERTIES.get(metric, {"name": metric, "color": "black", "linestyle": "-"})


def series_for(rows: list[dict], metric: str, axis: str) -> list[dict]:
    """The rows of one metric along one axis, ordered by their position on it."""
    return sorted(
        (row for row in rows if row["metric"] == metric and row["axis"] == axis),
        key=lambda row: row["point"],
    )


def draw(axes, points: list[dict], metric: str, show_runs: bool) -> bool:
    """Draws one metric as a mean, an interval, and the runs behind it.

    Returns whether anything was drawn: a metric that is zero everywhere is left out, since
    an empty series in a legend claims a measurement that carries no information.
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
                [row["point"]] * len(row["values"]),
                row["values"],
                marker=".",
                markersize=2,
                linestyle="none",
                color=properties["color"],
                alpha=0.35,
            )

    return True


def plot(rows: list[dict], metrics, axis: str, xlabel: str, ylabel: str, output: str,
         show_runs: bool = True) -> None:
    figure, axes = plt.subplots(figsize=(8, 6))
    axes.set_xlabel(xlabel)
    axes.set_ylabel(ylabel)

    drawn = 0
    repetitions = max((row["n"] for row in rows), default=0)

    for metric in metrics:
        if draw(axes, series_for(rows, metric, axis), metric, show_runs):
            drawn += 1

    if drawn == 0:
        plt.close(figure)
        print(f"  nothing to draw for {output}")
        return

    axes.legend(loc="best", frameon=True, fancybox=True, shadow=True)
    axes.grid(True)

    # The reader has to know how many runs are behind a band without leaving the figure.
    axes.set_title(
        f"mean of {repetitions} runs, shaded 95% confidence interval",
        fontsize=9,
        loc="right",
    )

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")


def group_by_configuration(rows: list[dict]) -> dict[tuple, list[dict]]:
    grouped = defaultdict(list)

    for row in rows:
        grouped[(row["crdt"], row["tracked_file"], row["scenario"], row["delay"])].append(row)

    return grouped


def sweep_over_adversaries(rows: list[dict]) -> list[dict]:
    """Recasts the final per-run totals as a series over the number of distrusted nodes.

    The sweep is assembled from the runs themselves, using the adversary count each run
    records in its manifest. It used to be read from a directory that no code ever wrote to,
    which is why the sweep figure had to be built by hand.
    """
    final = defaultdict(dict)

    for row in rows:
        if row["axis"] != "commit":
            continue

        key = (row["adversaries"], row["metric"])
        if key not in final or row["point"] > final[key]["point"]:
            final[key] = row

    return [
        {**row, "axis": "adversaries", "point": adversaries}
        for (adversaries, _metric), row in final.items()
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aggregate", default="debug/aggregate/summary.json")
    parser.add_argument("--figures", default="figures")
    arguments = parser.parse_args()

    if not os.path.exists(arguments.aggregate):
        raise SystemExit(
            f"no aggregate at {arguments.aggregate}; run scripts/aggregate_runs.py first"
        )

    rows = load(arguments.aggregate)
    os.makedirs(arguments.figures, exist_ok=True)

    for (crdt, tracked_file, scenario, _delay), group in group_by_configuration(rows).items():
        label = f"{crdt}_{os.path.basename(tracked_file).replace('.', '-')}_{scenario}"

        plot(
            group,
            PER_COMMIT_METRICS,
            "commit",
            "Commit number",
            "Messages per commit",
            os.path.join(arguments.figures, f"messages_per_commit_{label}.pdf"),
        )

    # One sweep figure per history, over every adversary count that was run for it.
    by_history = defaultdict(list)
    for row in rows:
        by_history[(row["crdt"], row["tracked_file"])].append(row)

    for (crdt, tracked_file), group in by_history.items():
        if len({row["adversaries"] for row in group}) < 2:
            continue

        label = f"{crdt}_{os.path.basename(tracked_file).replace('.', '-')}"

        plot(
            sweep_over_adversaries(group),
            ADVERSARY_SWEEP_METRICS,
            "adversaries",
            "Number of distrusted nodes",
            "Messages over the whole replay",
            os.path.join(arguments.figures, f"distrusted_nodes_{label}.pdf"),
        )


if __name__ == "__main__":
    main()
