#!/bin/bash

git log --pretty=format: --name-only | \
  grep -v '^$' | \
  sort | \
  uniq -c | \
  sort -nr | \
  head -n 10

