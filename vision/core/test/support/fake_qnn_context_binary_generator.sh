#!/bin/sh
# Stands in for QAIRT's qnn-context-binary-generator: copies the DLC to
# <output_dir>/<binary_file>.bin, so the binary carries the DLC's text.
while [ $# -gt 0 ]; do
  case "$1" in
    --dlc_path) dlc="$2"; shift 2 ;;
    --binary_file) name="$2"; shift 2 ;;
    --output_dir) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$dlc" "$out/$name.bin"
