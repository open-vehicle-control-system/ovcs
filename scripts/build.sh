#!/bin/bash

set -e

COMPONENT=$1
BASEDIR=$(dirname $0)
shift

if [ ! -d "$COMPONENT" ]; then
    echo "Missing argument: [component name], you should specify it as first argument:"
    echo
    echo "$ ./build.sh [component name]"
    echo
    exit 1
fi

$BASEDIR/../$COMPONENT/firmware/build.sh "$@"