"""Document growth per implementation, drawn from the aggregate of repeated runs.

Shows how a replica's document grows as it applies edits, for each implementation that was
replayed, as a mean over the runs of that implementation with a 95% confidence interval.

Reads the long-format summary that ``aggregate_runs.py`` writes. The earlier version of this
script also read a file of per-commit source sizes that no code in the project produces,
which made it raise before drawing anything. That series is gone: the baseline it provided
is the ``crdt-memory-usage`` table in the paper, which is measured rather than reconstructed.

Run from ``Code/``, after ``aggregate_runs.py``::

    python scripts/aggregate_runs.py
    python scripts/heap_size_visualization.py

The figure is written to ``Code/figures/heap_size_plot.pdf``.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

IMPLEMENTATIONS = {
    "syncordian": {"name": "Syncordian", "color": "#2a78d6"},
    "fugue": {"name": "Fugue", "color": "#eb6834"},
    "logoot": {"name": "Logoot", "color": "#008300"},
    "treedoc": {"name": "Treedoc", "color": "#4a3aa7"},
}


def format_kilobytes(value, _position):
    return f"{value / 1000:.0f}K" if value >= 1000 else f"{value:.0f}"


def load(path: str) -> list[dict]:
    with open(path) as handle:
        return json.load(handle)


def growth_series(rows: list[dict]) -> dict[str, list[dict]]:
    """The per-edit heap size of each implementation, ordered by edit number."""
    by_implementation = defaultdict(list)

    for row in rows:
        if row["axis"] == "edit" and row["metric"] == "heap_size":
            by_implementation[row["crdt"]].append(row)

    return {
        implementation: sorted(points, key=lambda row: row["point"])
        for implementation, points in by_implementation.items()
    }


def plot(series: dict[str, list[dict]], output: str) -> None:
    figure, axes = plt.subplots(figsize=(8, 6))
    repetitions = 0

    for implementation, points in sorted(series.items()):
        if not points:
            continue

        properties = IMPLEMENTATIONS.get(
            implementation, {"name": implementation, "color": "black"}
        )
        x = [row["point"] for row in points]
        repetitions = max(repetitions, max(row["n"] for row in points))

        axes.plot(
            x,
            [row["mean"] for row in points],
            label=properties["name"],
            color=properties["color"],
            linewidth=1.6,
        )

        # No band where the size does not vary across runs.
        if any(not row["deterministic"] for row in points):
            axes.fill_between(
                x,
                [row["ci_low"] for row in points],
                [row["ci_high"] for row in points],
                color=properties["color"],
                alpha=0.18,
                linewidth=0,
            )

    if repetitions == 0:
        plt.close(figure)
        raise SystemExit("the aggregate holds no per-edit document sizes")

    axes.yaxis.set_major_formatter(FuncFormatter(format_kilobytes))
    axes.set_xlabel("Edit number")
    axes.set_ylabel("Document size")
    axes.legend(loc="upper left")
    axes.grid(True)
    axes.set_title(
        f"mean of {repetitions} runs, shaded 95% confidence interval", fontsize=9, loc="right"
    )

    plt.tight_layout()
    plt.savefig(output)
    plt.close(figure)
    print(f"Plot saved to {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aggregate", default="debug/aggregate/summary.json")
    parser.add_argument("--figures", default="figures")
    arguments = parser.parse_args()

    if not os.path.exists(arguments.aggregate):
        raise SystemExit(
            f"no aggregate at {arguments.aggregate}; run scripts/aggregate_runs.py first"
        )

    os.makedirs(arguments.figures, exist_ok=True)
    plot(
        growth_series(load(arguments.aggregate)),
        os.path.join(arguments.figures, "heap_size_plot.pdf"),
    )


if __name__ == "__main__":
    main()
