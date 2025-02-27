import os
import json
import matplotlib.pyplot as plt
import re

# Define a global properties map that holds both the display name, color, and linestyle for each metric
metric_properties_map = {
    "delete_stash_counter": {"name": "Delete stash activate", "color": "#03071e", "linestyle": "-"},  # Dark Black
    "delete_valid_counter": {"name": "Valid delete messages", "color": "#370617", "linestyle": "--"},  # Dark Burgundy
    "insert_distance_greater_than_one": {
        "name": "Insert messages ahead of local clock",
        "color": "#7209b7",  # Deep Red
        "linestyle": "--",
        "linewidth": 1,
    },
    "insert_valid_counter": {"name": "Valid insert messages", "color": "#9d0208", "linestyle": "-"},  # Crimson
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
    "delete_requeue_counter": {"name": "Delete messages requeued", "color": "#e85d04", "linestyle": ":", "linewidth": 2},  # Bright Orange
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

# Function to extract commit number from the filename
def extract_commit_number(filename):
    match = re.search(r"commit_(\d+)_", filename)
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
        "delete_stash_counter": [],
        "delete_valid_counter": [],
        "insert_distance_greater_than_one": [],
        "insert_valid_counter": [],
    }

    files = [f for f in os.listdir(directory) if f.endswith(".json")]
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

def plot_metrics(x_axis, metrics, xlabel, title):
    # Normalize metrics
    normalized_metrics = {key: normalize(values) for key, values in metrics.items()}

    # Create the main plot
    fig, ax1 = plt.subplots(figsize=(8, 6))
    ax1.set_xlabel(xlabel)
    ax1.set_ylabel("Normalized Metrics")

    # Plot each normalized metric with predefined colors and line styles
    for metric, values in normalized_metrics.items():
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

    # Customize the legend to appear in the upper right corner
    ax1.legend(loc="lower right", frameon=True, fancybox=True, shadow=True)

    # Customize the plot with grid
    ax1.grid(True)

    # Show the plot
    plt.tight_layout()
    # plt.title(title)
    plt.show()

# Main function to execute the script
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    directory = os.path.join(script_dir, "../debug/metadata/no_byzantine_nodes")
    directory_byzantine = os.path.join(script_dir, "../debug/metadata/byzantine_nodes")

    # Plot no byzantine nodes data
    x_axis_no_byzantine, metrics_no_byzantine = read_json_files_no_byzantine_nodes(
        directory
    )
    plot_metrics(
        x_axis_no_byzantine,
        metrics_no_byzantine,
        "Commit Number",
        "Normalized Metric Values Over Commit Numbers",
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
    )

if __name__ == "__main__":
    main()
