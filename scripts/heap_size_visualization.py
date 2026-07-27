"""Document growth per implementation, drawn from the aggregate of repeated runs.

Shows how a replica's document grows as it applies edits, one curve per implementation and
history, as a mean over the runs of that configuration with the range those runs covered. It reads
the honest-network runs only, `baseline` at zero distrusted nodes, because a forged operation is
rejected at admission and never enters a document.

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


def growth_series(rows: list[dict]) -> dict[tuple[str, str], list[dict]]:
    """The per-edit heap size of one implementation on one history, ordered by edit number.

    The history belongs in the key, and so does the filter below. An earlier version bucketed on
    the implementation alone, and with two histories in the aggregate it handed ``fill_between``
    the README document and the git plugin document interleaved at every edit number. The band it
    drew was the distance between two different documents, presented as a confidence interval over
    runs, and it spanned the whole figure. It also ended abruptly where the shorter history ran
    out, which is the visible symptom of the same thing.

    A distrusted node inserts nothing that any replica keeps, so its runs would only add
    configurations that duplicate the honest ones. The figure is about how a document grows on an
    honest network, so it is drawn from those runs and says so.
    """
    by_series = defaultdict(list)

    for row in rows:
        if row["axis"] != "edit" or row["metric"] != "heap_size":
            continue

        if row["scenario"] != "baseline" or row["adversaries"] != 0:
            continue

        by_series[(row["crdt"], row["tracked_file"])].append(row)

    return {
        series: sorted(points, key=lambda row: row["point"])
        for series, points in by_series.items()
    }


def plot(series: dict[tuple[str, str], list[dict]], output: str) -> None:
    figure, axes = plt.subplots(figsize=(8, 6))
    repetitions = 0

    # Colour says which implementation, and the line style says which history, because the same
    # implementation is replayed over both and two curves in one colour cannot be told apart.
    histories = sorted({tracked_file for _crdt, tracked_file in series})
    styles = ("-", "--", "-.", ":")

    for (implementation, tracked_file), points in sorted(series.items()):
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
            label=f"{properties['name']}, {os.path.basename(tracked_file)}",
            color=properties["color"],
            linestyle=styles[histories.index(tracked_file) % len(styles)],
            linewidth=1.6,
        )

        # No band where the size does not vary across runs. The band is the range the runs
        # covered, matching `data_visualization.py`, so that an identically styled band means the
        # same thing in every figure of the paper. At three repetitions the Student t interval is
        # about two and a half times the observed range, and on the per-commit counts it reaches
        # below zero; the interval is what a quoted number carries, not what a band shows.
        if any(not row["deterministic"] for row in points):
            axes.fill_between(
                x,
                [row["min"] for row in points],
                [row["max"] for row in points],
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
        f"mean of {repetitions} runs, shaded range across runs", fontsize=9, loc="right"
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
