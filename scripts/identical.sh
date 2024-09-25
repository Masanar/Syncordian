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

# Use the first file as a reference, excluding .gitignore
REFERENCE_FILE=""
for FILE in "${FILES[@]}"; do
  if [[ "$(basename "$FILE")" != ".gitignore" ]]; then
    REFERENCE_FILE="$FILE"
    break
  fi
done

# Ensure we found a valid reference file
if [ -z "$REFERENCE_FILE" ]; then
  echo "No valid reference file found."
  exit 1
fi

# Loop through all the files and compare with the reference file
for FILE in "${FILES[@]}"; do
  if [[ "$(basename "$FILE")" != ".gitignore" ]]; then
    if ! cmp -s "$REFERENCE_FILE" "$FILE"; then
      echo "The files are not identical. Mismatch found in: $FILE"
      exit 1
    fi
  fi
done

echo "All files are identical."
