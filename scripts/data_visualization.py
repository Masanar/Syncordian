import os
import json
import matplotlib.pyplot as plt
import re

# Define a global properties map that holds both the display name, color, and linestyle for each metric
metric_properties_map = {
    "delete_stash_counter": {"name": "Delete stash activate", "color": "#03071e", "linestyle": "-"},  # Dark Black
    "delete_valid_counter": {"name": "Valid delete messages", "color": "#eb6834", "linestyle": "--", "linewidth": 1.6},  # Orange
    "insert_distance_greater_than_one": {
        "name": "Insert messages ahead of local clock",
        "color": "#4a3aa7",  # Violet
        "linestyle": "-.",
        "linewidth": 1.6,
    },
    "insert_valid_counter": {"name": "Valid insert messages", "color": "#2a78d6", "linestyle": "-", "linewidth": 1.6},  # Blue
    "settle_counter": {
        "name": "Lines settled (acknowledged by all peers)",
        "color": "#008300",  # Green
        "linestyle": ":",
        "linewidth": 2,
    },
    "byzantine_delete_counter": {
        "name": "Delete messages Distrusted nodes",
        "color": "#e85d04",  # Bright Red
        "linestyle": "-.",
        "linewidth": 1,
    },
    "byzantine_insert_counter": {
        "name": "Insert messages Distrusted nodes",
        "color": "#3d405b",  # Orange Red
        "linestyle": ":",
        "linewidth": 1.2,
    },
    "requeue_counter": {"name": "Delete messages requeued", "color": "#e85d04", "linestyle": ":", "linewidth": 2},  # Bright Orange
    "delete_requeue_limit": {
        "name": "Delete messages reach requeue limit",
        "color": "#ff006e",  # Golden Orange
        "linestyle": ":",
        "linewidth": 1,
    },
    "insert_request_limit_counter": {
        "name": "Insert messages reach request limit",
        "color": "#d00000",  # Mustard Yellow
        "linestyle": "-.",
    },
    "insert_stash_fail_counter": {"name": "Insert messages fail stash", "color": "#081c15", "linestyle": "-"},  # Dark Green
}

# Function to extract byzantine node number from the filename
def extract_byzantine_number(filename):
    match = re.search(r"byzantine_nodes_(\d+)_", filename)
    if match:
        return int(match.group(1))
    return None

# Function to extract commit number from the filename (e.g. "commit_42.json";
# anchored so it doesn't match the "commit_42.json" suffix of
# "byzantine_nodes_2_commit_42.json")
def extract_commit_number(filename):
    match = re.fullmatch(r"commit_(\d+)\.json", filename)
    if match:
        return int(match.group(1))
    return None

# Function to read JSON files for the 'byzantine nodes' data
def read_json_files_byzantine_nodes(directory):
    x_axis = []
    metrics = {
        "byzantine_delete_counter": [],
        "byzantine_insert_counter": [],
        "delete_requeue_limit": [],
        "insert_distance_greater_than_one": [],
        "insert_request_limit_counter": [],
        "insert_stash_fail_counter": [],
        "insert_valid_counter": [],
        "delete_valid_counter": []
    }

    files = [f for f in os.listdir(directory) if f.endswith(".json")]
    files.sort(key=lambda f: extract_byzantine_number(f))

    for filename in files:
        filepath = os.path.join(directory, filename)
        with open(filepath, "r") as file:
            data = json.load(file)
            byzantine_number = extract_byzantine_number(filename)
            x_axis.append(byzantine_number)
            for key in metrics:
                metrics[key].append(data[key])

    return x_axis, metrics

# Function to read JSON files for the 'no byzantine nodes' data
def read_json_files_no_byzantine_nodes(directory):
    x_axis = []
    metrics = {
        "delete_valid_counter": [],
        "insert_distance_greater_than_one": [],
        "insert_valid_counter": [],
        "settle_counter": [],
    }

    files = [f for f in os.listdir(directory) if extract_commit_number(f) is not None]
    files.sort(key=lambda f: extract_commit_number(f))

    for filename in files:
        filepath = os.path.join(directory, filename)
        with open(filepath, "r") as file:
            data = json.load(file)
            commit_number = extract_commit_number(filename)
            x_axis.append(commit_number)
            for key in metrics:
                metrics[key].append(data[key])

    return x_axis, metrics

# The supervisor collects peer metadata asynchronously, so some per-commit
# snapshots miss peer responses and their network-wide sums dip below earlier
# ones (a few are even all-zero). Keep the longest subsequence of snapshots in
# which every counter is non-decreasing — the maximal mutually-consistent set —
# and drop the rest.
def filter_consistent_snapshots(x_axis, metrics):
    keys = list(metrics.keys())
    vectors = [[metrics[k][i] for k in keys] for i in range(len(x_axis))]
    n = len(vectors)
    best, prev = [1] * n, [-1] * n
    for i in range(n):
        for j in range(i):
            if best[j] + 1 > best[i] and all(a <= b for a, b in zip(vectors[j], vectors[i])):
                best[i], prev[i] = best[j] + 1, j
    i = max(range(n), key=lambda k: best[k], default=-1)
    chain = []
    while i != -1:
        chain.append(i)
        i = prev[i]
    chain.reverse()
    return (
        [x_axis[i] for i in chain],
        {k: [metrics[k][i] for i in chain] for k in keys},
    )

# The peer counters are cumulative sums over the whole network; the difference
# between consecutive snapshots is the number of messages of that kind processed
# for that commit. Snapshot commit numbers may have gaps, so deltas are taken
# between consecutive available snapshots.
def to_deltas(metrics):
    return {
        key: [values[0]] + [b - a for a, b in zip(values, values[1:])]
        for key, values in metrics.items()
    }

# Function to normalize a list of values
def normalize(values):
    if not values:
        return values
    min_val = min(values)
    max_val = max(values)
    if min_val == max_val:
        return [1] * len(values)
    else:
        return [(value - min_val) / (max_val - min_val) for value in values]

def plot_metrics(x_axis, metrics, xlabel, title, output_path, normalize_values=True, ylabel="Normalized Metrics"):
    if normalize_values:
        metrics = {key: normalize(values) for key, values in metrics.items()}

    # Create the main plot
    fig, ax1 = plt.subplots(figsize=(8, 6))
    ax1.set_xlabel(xlabel)
    ax1.set_ylabel(ylabel)

    # Plot each metric with predefined colors and line styles
    for metric, values in metrics.items():
        properties = metric_properties_map.get(
            metric, {"name": metric, "color": "black"}
        )
        linestyle = properties.get(
            "linestyle", "-"
        )  # Default to solid line if linestyle not provided
        linewidth = properties.get(
            "linewidth", 1
        )  # Default to 1 if linewidth not provided
        if any(values):  # Plot only if there are non-zero values
            ax1.plot(
                x_axis,
                values,
                label=properties["name"],
                color=properties["color"],
                linestyle=linestyle,
                linewidth=linewidth,
            )

    # Let matplotlib place the legend in the emptiest corner
    ax1.legend(loc="best", frameon=True, fancybox=True, shadow=True)

    # Customize the plot with grid
    ax1.grid(True)

    # Save the plot to a file
    plt.tight_layout()
    # plt.title(title)
    plt.savefig(output_path)
    print(f"Plot saved to {output_path}")

# Main function to execute the script
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    directory = os.path.join(script_dir, "../debug/metadata/supervisor/syncordian")
    directory_byzantine = os.path.join(script_dir, "../debug/metadata/byzantine_nodes")
    figures_dir = os.path.join(script_dir, "../figures")
    os.makedirs(figures_dir, exist_ok=True)

    # Plot no byzantine nodes data
    x_axis_no_byzantine, metrics_no_byzantine = read_json_files_no_byzantine_nodes(
        directory
    )
    x_axis_no_byzantine, metrics_no_byzantine = filter_consistent_snapshots(
        x_axis_no_byzantine, metrics_no_byzantine
    )
    plot_metrics(
        x_axis_no_byzantine,
        to_deltas(metrics_no_byzantine),
        "Commit Number",
        "Message Processing per Commit",
        os.path.join(figures_dir, "no_byzantine_metrics.pdf"),
        normalize_values=False,
        ylabel="Messages per commit",
    )

    # Plot byzantine nodes data
    x_axis_byzantine, metrics_byzantine = read_json_files_byzantine_nodes(
        directory_byzantine
    )
    plot_metrics(
        x_axis_byzantine,
        metrics_byzantine,
        "Number of Distrusted Nodes",
        "Normalized Metric Values Over Distrusted Nodes",
        os.path.join(figures_dir, "byzantine_metrics.pdf"),
    )

if __name__ == "__main__":
    main()
