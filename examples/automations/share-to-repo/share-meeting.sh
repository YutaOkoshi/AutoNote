#!/bin/sh
# Shares one AutoNote meeting file to the meeting-record repository. See README.md.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "${SHARE_PYTHON:-/usr/bin/python3}" "$DIR/lib/share_meeting.py" "$@"
