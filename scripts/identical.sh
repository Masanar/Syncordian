#!/bin/bash

# Directory containing the files
DIRECTORY="../debug"

# Get a list of all files in the directory (excluding directories)
FILES=("$DIRECTORY"/*)

# Check if there are any files in the directory
if [ ${#FILES[@]} -eq 0 ]; then
  echo "No files found in the directory."
  exit 1
fi

# Use the first file as the reference
REFERENCE_FILE="${FILES[0]}"

# Flag to check if all files are identical
ALL_IDENTICAL=true

# Compare each file with the reference file
for FILE in "${FILES[@]}"; do
  # Check if it's a file
  if [ -f "$FILE" ]; then
    if ! cmp -s "$REFERENCE_FILE" "$FILE"; then
      echo "File ${FILE##*/} is different from ${REFERENCE_FILE##*/}."
      ALL_IDENTICAL=false
    fi
  fi
done

# Check the flag to print the final message
if $ALL_IDENTICAL; then
  echo "All files are identical."
else
  echo "Some files are different."
fi
