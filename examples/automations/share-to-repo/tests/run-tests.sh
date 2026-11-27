#!/bin/sh
# Runs the share-to-repo tests. Everything happens in temp folders; nothing real is read or sent.
# Usage: tests/run-tests.sh [-v] [test_module ...]    KEEP_SANDBOX=1 keeps the temp folders.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PY="${SHARE_PYTHON:-/usr/bin/python3}"
cd "$HERE"
unset SHARE_CONFIG SHARE_HOME NOTIFY_MODE SLACK_WEBHOOK_URL SLACK_WEBHOOK_OP_REF MIRROR_DIR AUTONOTE_CLI 2>/dev/null || true
VERBOSE=""
if [ "${1:-}" = "-v" ]; then VERBOSE="-v"; shift; fi
if [ "$#" -gt 0 ]; then
  exec "$PY" -m unittest $VERBOSE "$@"
fi
exec "$PY" -m unittest discover $VERBOSE -s "$HERE" -p 'test_*.py'
