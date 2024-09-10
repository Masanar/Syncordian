#!/bin/bash

# Folder containing the files
FOLDER="../debug/documents"

# Get the list of files in the folder (ignoring extensions)
FILES=("$FOLDER"/*)

# If there are fewer than 2 files, they are trivially identical
if [ "${#FILES[@]}" -lt 2 ]; then
  echo "There are fewer than 2 files. Nothing to compare."
  exit 0
fi

# Use the first file as a reference
REFERENCE_FILE="${FILES[0]}"
# Loop through all the files and compare with the reference file
for FILE in "${FILES[@]}"; do
  if ! cmp -s "$REFERENCE_FILE" "$FILE"; then
    echo "The files are not identical. Mismatch found in: $FILE"
    exit 1
  fi
done

echo "All files are identical."