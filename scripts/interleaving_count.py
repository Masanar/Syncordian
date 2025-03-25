import os
import difflib
import json

def count_diff_lines(file_lines, base_lines):
    """Count the number of lines that differ using ndiff."""
    diff = list(difflib.ndiff(file_lines, base_lines))
    count = 0
    for line in diff:
        # Lines that are different start with '- ' (in file_lines) or '+ ' (in base_lines)
        if line.startswith('- ') or line.startswith('+ '):
            count += 1
    return count

def main():
    base_file_path = os.path.join('debug', 'README_versions', 'README_f9993d0c.md')
    docs_dir = os.path.join('debug', 'documents', 'logoot')
    result = {}
    total_diff = 0
    count_files = 0

    if not os.path.isfile(base_file_path):
        print(f"Base file not found: {base_file_path}")
        return

    with open(base_file_path, 'r', encoding='utf-8') as f:
        base_lines = f.readlines()

    if not os.path.isdir(docs_dir):
        print(f"Documents directory not found: {docs_dir}")
        return

    for filename in os.listdir(docs_dir):
        file_path = os.path.join(docs_dir, filename)
        if os.path.isfile(file_path):
            with open(file_path, 'r', encoding='utf-8') as f:
                file_lines = f.readlines()
            diff_count = count_diff_lines(file_lines, base_lines)
            result[filename] = diff_count
            total_diff += diff_count
            count_files += 1

    # Calculate average differences for all files
    result['average'] = total_diff / count_files if count_files > 0 else 0

    # Save the comparison results to a JSON file
    output_json_path = 'diff_comparison.json'
    with open(output_json_path, 'w', encoding='utf-8') as f:
        json.dump(result, f, indent=4)

    print(f"Comparison finished. Results saved in {output_json_path}")

if __name__ == '__main__':
    main()