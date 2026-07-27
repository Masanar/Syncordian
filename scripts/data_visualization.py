"""Figures for the evaluation, drawn from the aggregate of repeated runs.

Reads the long-format summary that ``aggregate_runs.py`` writes, so this script never sees
an individual run and never decides how a number was summarized. Every series is a mean over
the runs of one configuration, shown with the range those runs covered and with the runs
themselves drawn on top. The individual runs are drawn deliberately: at a handful of
repetitions a reader should be able to see the spread rather than only a summary of it.

The band is the observed range and not the Student t interval the aggregate also carries. See
``draw()`` for why: on a per-commit count at three repetitions the t interval reaches below
zero, and a message count cannot. The t interval is still what every number quoted in prose
carries, from ``summary.json`` and ``ws9_numbers.py``.

A quantity that does not vary across runs is drawn as a plain line with no band, because the
aggregate marks it deterministic and there is no spread to show.

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
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

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
    """Draws one metric as a mean, the range the runs covered, and the runs themselves.

    The band is the observed minimum to maximum across runs, not the Student t interval that
    `aggregate_runs.py` also computes. The t interval is the right thing to quote beside a number
    and the wrong thing to shade here, for a reason the per-commit series makes plain. At three
    repetitions the half-width is 2.48 standard deviations, so any point whose spread exceeds
    about 40% of its mean is given a negative lower bound, and on the README history 27 of 344
    plotted points were: a message count cannot be negative, and a band that says it can be reads
    as an error in the measurement.

    It is not an error, and it is not really uncertainty about how many messages there were. The
    runs do identical work: cumulative inserts and deletes are exactly equal across seeds, and
    cumulative settles agree to a tenth of a percent. What varies is which commit a settle is
    attributed to, since a line settles when the last acknowledgement arrives and the delay model
    randomizes arrival per seed. So the per-commit series is a timing split of a fixed total, the
    spread at a point is the width of that split, and the range across runs is exactly that: it
    cannot leave the region the runs occupied, and at three runs it is the whole dataset rather
    than a normal-theory summary of three points.

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

    # No band on a quantity that does not vary across runs. See aggregate_runs.py.
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
         show_runs: bool = True, symlog: bool = False) -> None:
    figure, axes = plt.subplots(figsize=(8, 6))
    axes.set_xlabel(xlabel)
    axes.set_ylabel(ylabel)

    # A symmetric log axis where the series span orders of magnitude, which the adversary sweep
    # does: the forged messages are in the hundreds and the valid ones in the tens of thousands,
    # so on a linear axis the forged series lie on the x axis and cannot be read. It is symmetric
    # rather than plain log because zero distrusted nodes forge zero messages, and that is a
    # measured point rather than a gap. Normalizing instead would hide the absolutes, which is
    # what the reviewer objected to.
    if symlog:
        axes.set_yscale("symlog", linthresh=1)

    drawn = 0
    repetitions = max((row["n"] for row in rows), default=0)

    for metric in metrics:
        if draw(axes, series_for(rows, metric, axis), metric, show_runs):
            drawn += 1

    if drawn == 0:
        plt.close(figure)
        print(f"  nothing to draw for {output}")
        return

    # What the shading means goes in the legend and not only in the corner title. Every series is
    # drawn as three things in one colour, a line, a translucent band and a scatter of points, and
    # a reader who is told only "shaded interval" in nine point type above the axes has to guess
    # which of the three that names.
    handles, labels = axes.get_legend_handles_labels()
    handles.append(
        Patch(facecolor="0.35", alpha=0.18, linewidth=0, label=f"range across {repetitions} runs")
    )
    labels.append(f"range across {repetitions} runs")

    if show_runs:
        handles.append(
            Line2D([], [], marker=".", markersize=4, linestyle="none", color="0.35",
                   alpha=0.6, label="individual runs")
        )
        labels.append("individual runs")

    axes.legend(handles, labels, loc="best", frameon=True, fancybox=True, shadow=True, fontsize=8)
    axes.grid(True)

    # The reader has to know how many runs are behind a band without leaving the figure. The band
    # is the range the runs covered, not a confidence interval: see draw() for why the t interval
    # is quoted beside numbers but not shaded here.
    axes.set_title(
        f"mean of {repetitions} runs, shaded range across runs",
        fontsize=9,
        loc="right",
    )

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")


def group_by_configuration(rows: list[dict]) -> dict[tuple, list[dict]]:
    """One group per configuration whose per-commit series is one experiment.

    The adversary count belongs in the key. Without it, a root holding the adversary sweep put
    all six counts of one scenario in one group, and the per-commit figure drew a line through
    six values at every commit while calling itself the mean of one. The figure that suffered is
    the one the paper reads as its no-adversary figure, so the blend was invisible in the paper
    and not in the data.
    """
    grouped = defaultdict(list)

    for row in rows:
        grouped[
            (row["crdt"], row["tracked_file"], row["scenario"], row["adversaries"], row["delay"])
        ].append(row)

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

    # The adversary count is in the filename, always, including when it is zero. A figure that
    # does not name it can be mistaken for one drawn at a different count, and the no-adversary
    # figure is the one the paper depends on being exactly that.
    for (crdt, tracked_file, scenario, adversaries, _delay), group in group_by_configuration(rows).items():
        label = (
            f"{crdt}_{os.path.basename(tracked_file).replace('.', '-')}_{scenario}_adv{adversaries}"
        )

        plot(
            group,
            PER_COMMIT_METRICS,
            "commit",
            "Commit number",
            "Messages per commit",
            os.path.join(arguments.figures, f"messages_per_commit_{label}.pdf"),
        )

    # One sweep figure per history *and scenario*, over every adversary count run for it.
    #
    # The scenario belongs in the key. Without it, a root holding `baseline` at zero adversaries and
    # `reorder_storm` at one produced a figure whose x axis read "0 to 1 distrusted nodes" while the
    # difference between the two points was also every capability the storm turns on: injection at
    # half the messages, tampering, replay, duplication and reordering. The reader is told they are
    # seeing the cost of one adversary. Two points from two scenarios are not that, and are now two
    # figures, each of which needs at least two adversary counts of its own before it is drawn.
    by_history = defaultdict(list)
    for row in rows:
        by_history[(row["crdt"], row["tracked_file"], row["scenario"])].append(row)

    for (crdt, tracked_file, scenario), group in by_history.items():
        if len({row["adversaries"] for row in group}) < 2:
            continue

        label = f"{crdt}_{os.path.basename(tracked_file).replace('.', '-')}_{scenario}"

        plot(
            sweep_over_adversaries(group),
            ADVERSARY_SWEEP_METRICS,
            "adversaries",
            "Number of distrusted nodes",
            "Messages over the whole replay",
            os.path.join(arguments.figures, f"distrusted_nodes_{label}.pdf"),
            symlog=True,
        )


if __name__ == "__main__":
    main()
