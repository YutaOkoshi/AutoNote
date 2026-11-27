#!/bin/sh
# Builds SharePatrol.app: a tiny app that only runs daily-patrol.sh. See README「launchd から会議ファイルのフォルダを
# 読めないとき」. macOS decides folder access per app; a script started straight from launchd is refused without a
# prompt, while an app opened by launchd gets the prompt under its own name.
#
# Usage: make-patrol-app.sh <SHARE_HOME>        e.g. "$HOME/Library/Application Support/AutoNoteShare"
# The app finds config.env, bin/ and logs/ in the folder it sits in, so it must stay in <SHARE_HOME>.
# The patrol's output goes to logs/launchd-patrol.out.log / .err.log, followed by a line "patrol exit <code>"
# (launchd itself only sees the exit code of `open`).
set -eu
SHARE_HOME=${1:?usage: make-patrol-app.sh <SHARE_HOME>}
APP="$SHARE_HOME/SharePatrol.app"
if [ -e "$APP" ]; then
  echo "already there: $APP (move it away first; a rebuilt app may be asked for the permission again)" >&2
  exit 1
fi
mkdir -p "$SHARE_HOME/logs"
/usr/bin/osacompile -o "$APP" \
  -e 'set h to do shell script "/usr/bin/dirname " & quoted form of POSIX path of (path to me)' \
  -e 'set out to quoted form of (h & "/logs/launchd-patrol.out.log")' \
  -e 'try' \
  -e 'do shell script "SHARE_CONFIG=" & quoted form of (h & "/config.env") & " /bin/sh " & quoted form of (h & "/bin/daily-patrol.sh") & " >> " & out & " 2>> " & quoted form of (h & "/logs/launchd-patrol.err.log") & "; echo \"patrol exit $?\" >> " & out' \
  -e 'end try'
echo "built: $APP"
