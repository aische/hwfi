#!/bin/sh
# Deliberate syntax error: missing `fi` to close the if block.
greet() {
  name="$1"
  if [ -z "$name" ]; then
    echo "Hello, world!"
  else
    echo "Hello, $name!"
}

greet "$@"
