import os
import json
import matplotlib.pyplot as plt
import re
from matplotlib.ticker import FuncFormatter

# Function to extract the edit number from the filename
def extract_edit_number(filename):
    match = re.search(r"edit_(\d+)\.json", filename)
    if match:
        return int(match.group(1))
    return None

# Function to read JSON files and extract edit numbers and heap sizes
def read_json_files(directory):
    x_axis = []
    heap_sizes = []

    files = [f for f in os.listdir(directory) if f.endswith(".json")]
    files.sort(key=lambda f: extract_edit_number(f))  # Sort by edit number

    for filename in files:
        filepath = os.path.join(directory, filename)
        with open(filepath, "r") as file:
            data = json.load(file)
            edit_number = extract_edit_number(filename)
            if edit_number is not None:
                x_axis.append(edit_number)
                heap_sizes.append(data["heap_size"])
    

    return x_axis, heap_sizes

# Function to read data from commit_sizes_with_edits.json
def read_commit_sizes_with_edits(filepath):
    x_axis = []
    heap_sizes = []

    with open(filepath, "r") as file:
        data = json.load(file)
        for entry in data:
            x_axis.append(entry["edit_number"])  # Use "edit_number" for the x-axis
            heap_sizes.append(entry["heap_size"])  # Use "heap_size" for the y-axis

    return x_axis, heap_sizes

# Function to format y-axis labels
def format_y_axis(value, _):
    if value >= 1000:
        return f"{int(value / 1000)}kB"  # Convert to 'K' format
    return str(int(value))  # Keep smaller values as-is

# Function to plot the graph
def plot_heap_sizes(fugue_data, syncordian_data, logoot_data, commit_data, output_path="../figures/heap_size_plot.pdf"):
    fig, ax = plt.subplots(figsize=(10, 6))

    # Plot Fugue data
    ax.plot(
        fugue_data[0], fugue_data[1],
        label="Fugue",
        color="blue",
        linestyle="-",
        linewidth=2
    )

    # Plot Syncordian data
    ax.plot(
        syncordian_data[0], syncordian_data[1],
        label="Syncordian",
        color="green",
        linestyle="--",
        linewidth=2
    )

    # Plot Logoot data
    ax.plot(
        logoot_data[0], logoot_data[1],
        label="Logoot",
        color="orange",
        linestyle="-.",
        linewidth=2
    )

    # Plot Commit data (Original README)
    ax.plot(
        commit_data[0], commit_data[1],
        label="Original README",
        color="red",
        linestyle=":",
        linewidth=2
    )

    # Add vertical lines for the commit points
    for x in commit_data[0]:  # Iterate over the x-axis values (edit numbers) for commits
        ax.axvline(
            x=x,
            color="lightgray",  # Use a lighter color for the lines
            linestyle="--",
            linewidth=0.5,  # Make the lines thinner
            alpha=0.5  # Add transparency
        )

    # Customize the y-axis to display values in 'K' format
    ax.yaxis.set_major_formatter(FuncFormatter(format_y_axis))

    # Customize the plot
    ax.set_xlabel("Edit Number")
    ax.set_ylabel("Document Size")
    ax.legend(loc="upper left")
    ax.grid(True)

    # Save the plot to a file
    plt.tight_layout()
    plt.savefig(output_path)
    print(f"Plot saved to {output_path}")

# Main function
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fugue_dir = os.path.join(script_dir, "../debug/metadata/individual_peer/fugue")
    syncordian_dir = os.path.join(script_dir, "../debug/metadata/individual_peer/syncordian")
    logoot_dir = os.path.join(script_dir, "../debug/metadata/individual_peer/logoot")  # New directory for Logoot
    commit_sizes_path = os.path.join(script_dir, "../debug/README_versions/commit_sizes_with_edits.json")
    output_path = os.path.join(script_dir, "../figures/heap_size_plot.pdf")

    # Read data for Fugue, Syncordian, and Logoot
    fugue_x, fugue_heap_sizes = read_json_files(fugue_dir)
    syncordian_x, syncordian_heap_sizes = read_json_files(syncordian_dir)
    logoot_x, logoot_heap_sizes = read_json_files(logoot_dir)  # Read Logoot data

    # Read data for Commit Sizes
    commit_x, commit_heap_sizes = read_commit_sizes_with_edits(commit_sizes_path)

    # Plot the data and save the graph as a PDF
    plot_heap_sizes(
        (fugue_x, fugue_heap_sizes),
        (syncordian_x, syncordian_heap_sizes),
        (logoot_x, logoot_heap_sizes),  # Pass Logoot data
        (commit_x, commit_heap_sizes),
        output_path
    )

if __name__ == "__main__":
    main()