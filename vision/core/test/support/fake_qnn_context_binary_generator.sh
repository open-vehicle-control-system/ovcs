#!/bin/sh
# Stands in for QAIRT's qnn-context-binary-generator: copies the DLC to
# <output_dir>/<binary_file>.bin, so the binary carries the DLC's text. While a file
# named hold sits next to it, it waits first, for 10 s at most.
while [ $# -gt 0 ]; do
  case "$1" in
    --dlc_path) dlc="$2"; shift 2 ;;
    --binary_file) name="$2"; shift 2 ;;
    --output_dir) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
waits=0
while [ -e "$(dirname "$0")/hold" ] && [ "$waits" -lt 100 ]; do
  sleep 0.1
  waits=$((waits + 1))
done
cp "$dlc" "$out/$name.bin"
