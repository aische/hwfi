#!/bin/sh
# This script has a deliberate syntax error: the `if` block is never closed with
# `fi`, so `sh -n broken.sh` fails. workflows/fix drives an agent to repair it.
greet() {
  name="$1"
  if [ -z "$name" ]; then
    echo "Hello, world!"
  else
    echo "Hello, $name!"
}

greet "$@"
