#!/usr/bin/env bash
# Operator-facing entry point for declaring an ordinary task parked after its
# terminal outcome has been relayed and only external human action remains.
# bin/fm-watch.sh owns window validation, secondmate rejection, key derivation,
# and marker creation; this wrapper only provides a seatbelt-safe command shape.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
  echo "Usage: fm-mark-parked.sh <window>" >&2
  exit 2
fi

exec "$SCRIPT_DIR/fm-watch.sh" mark-parked "$1"
