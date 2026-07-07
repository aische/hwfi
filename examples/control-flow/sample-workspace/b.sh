#!/bin/sh
name="$1"
if [ -z "$name" ]; then
  name="world"
fi
echo "hello $name"
