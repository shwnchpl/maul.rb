#!/bin/bash

if [ ! $# -eq 1 ]; then
  echo "usage: $0 [path-to-fifo]"
  exit 1
fi

while read -r f; do
    echo $f > $1
done
