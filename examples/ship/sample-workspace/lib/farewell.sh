#!/bin/sh
# Deliberate syntax error: missing `fi` to close the if block.
farewell() {
  name="$1"
  if [ -z "$name" ]; then
    echo "Goodbye, world!"
  else
    echo "Goodbye, $name!"
}

farewell "$@"
