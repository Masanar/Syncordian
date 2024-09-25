import os
import json
import matplotlib.pyplot as plt
import re

# Yes the vast majority of this code is chatgpt generated and I'm not ashamed of it
# is late at night and I'm tired. I made this whole project by myself and I'm proud of it
# I'm not going to spend time writing code that I can generate in 5 seconds. Additionally,
# I had to fine tunning the code generated by chatgpt to make it work.


# Function to extract the commit number (X) from the filename
def extract_commit_number(filename):
    match = re.search(r"commit_(\d+)_", filename)
    if match:
        return int(match.group(1))
    return None


# Function to read and process JSON files in the correct order
def read_json_files(directory):
    # Lists to store x-axis (current_commit) and y-axis (other values)
    x_axis = []
    metrics = {
        "delete_stash_counter": [],
        "delete_valid_counter": [],
        "insert_distance_greater_than_one": [],
        "insert_valid_counter": [],
    }

    # Get all JSON files in the directory
    files = [f for f in os.listdir(directory) if f.endswith(".json")]

    # Sort files by commit number
    files.sort(key=lambda f: extract_commit_number(f))

    # Read through all JSON files in the correct order
    for filename in files:
        filepath = os.path.join(directory, filename)
        with open(filepath, "r") as file:
            data = json.load(file)
            commit_number = extract_commit_number(filename)
            x_axis.append(commit_number)

            # Append values for each relevant metric
            for key in metrics:
                metrics[key].append(data[key])

    new_metrics = {}
    for key in metrics:
        if key == "delete_stash_counter":
            new_metrics["Delete_Stash_Messages"] = metrics[key]
        if key == "delete_valid_counter":
            new_metrics["Delete_Valid_Messages"] = metrics[key]
        if key == "insert_distance_greater_than_one":    
            new_metrics["Insert_Distance_Greater_Than_One"] = metrics[key]
        if key == "insert_valid_counter":
            new_metrics["Insert_Valid_Messages"] = metrics[key]

    return x_axis, new_metrics


# Function to normalize a list of values
def normalize(values):
    if not values:
        return values
    min_val = min(values)
    max_val = max(values)
    return [(value - min_val) / (max_val - min_val) for value in values]


# Function to generate the plot with normalized values
def plot_metrics(x_axis, metrics):

    # Normalize metrics
    normalized_metrics = {key: normalize(values) for key, values in metrics.items()}

    # Create a plot for each metric
    fig, ax = plt.subplots(figsize=(10, 8))
    ax.set_xlabel("Commit Number")

    # Plot each normalized metric
    for metric, values in normalized_metrics.items():
        if any(values):  # Plot only if there are non-zero values
            ax.plot(x_axis, values, label=metric.replace("_", " ").title())

    # Customize the plot
    ax.legend()
    ax.set_title("Normalized Metric Values Over Commit Numbers")
    ax.grid(True)

    # Show the plot
    plt.tight_layout()
    plt.show()


# Main function to execute the script
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    directory = os.path.join(script_dir, "../debug/metadata/no_byzantine_nodes")
    x_axis, metrics = read_json_files(directory)
    plot_metrics(x_axis, metrics)


if __name__ == "__main__":
    main()
