#!/bin/sh
# Stands in for QAIRT's qnn-context-binary-generator: copies the DLC to
# <output_dir>/<binary_file>.bin, so the binary carries the DLC's text. While a file
# named hold sits next to it, it waits first, for 10 s at most. While a file named fail
# sits next to it, it writes a file named failed there and exits with status 1.
while [ $# -gt 0 ]; do
  case "$1" in
    --dlc_path) dlc="$2"; shift 2 ;;
    --binary_file) name="$2"; shift 2 ;;
    --output_dir) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -e "$(dirname "$0")/fail" ]; then
  touch "$(dirname "$0")/failed"
  exit 1
fi
waits=0
while [ -e "$(dirname "$0")/hold" ] && [ "$waits" -lt 100 ]; do
  sleep 0.1
  waits=$((waits + 1))
done
cp "$dlc" "$out/$name.bin"
