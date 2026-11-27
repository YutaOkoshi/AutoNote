#!/bin/sh
# Daily patrol (launchd): retries, re-shares edited meetings, reminds about recordings. See README.md.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "${SHARE_PYTHON:-/usr/bin/python3}" "$DIR/lib/daily_patrol.py" "$@"
