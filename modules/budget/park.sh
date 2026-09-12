#!/bin/bash
# Park a session against a rate-limit reset, and schedule its own resume.
#
#   park.sh --session ID [--cwd DIR] [--window five_hour|seven_day] [--prompt T]
#   park.sh --cancel --session ID       stop a scheduled resume
#   park.sh --cancel --all              stop every scheduled resume
#   park.sh --status                    what is scheduled
#
# Parking does two things: it schedules `claude --bg --resume ID` for a few
# minutes after the window resets, and it writes a per-session marker that makes
# budget/gate.sh close every tool for that session. The second half is what
# makes the first half safe — a parked session cannot keep spending the window
# it just declared spent.
#
# WHY LAUNCHD. The resume has to survive a closed laptop and a reboot, which a
# backgrounded `sleep` does not: launchd runs a StartCalendarInterval job at the
# next opportunity when the machine was asleep or off at the appointed time.
# That ties this file to macOS, and it says so rather than pretending: on any
# other platform it refuses and names what is missing. The scheduling is the
# only platform-specific part — state, gate and sensor are portable — so a
# second trigger can be added beside this one without touching them.
#
# Pure bash: launchctl and date are the only commands, and both ship with the
# system this runs on.

set -u

RUN="$HOME/.claude/budget-run"
STATE="$HOME/.claude/budget-state"
CONFIG="$HOME/.claude/budget-config"
AGENTS="$HOME/Library/LaunchAgents"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL_PREFIX=com.llmdrive.budget-resume

RESUME_DELAY_S=300
# Written for a FRESH session, not a resumed one — see the correction in
# resume.sh. The parked session is still alive and gated; this prompt starts a
# new one beside it, and HANDOFF.md is the only thing carrying the work across.
DEFAULT_PROMPT="A rate-limit window has reset, and this session was started automatically to pick up work that stopped when the previous window ran out. Read HANDOFF.md in this repository and continue from its next-step section. Say what you are picking up before you start."

SESSION=''; CWD=''; WINDOW=five_hour; PROMPT=''; ACTION=park; ALL=0

while [ $# -gt 0 ]; do
  case $1 in
    --session) SESSION=${2:-}; shift 2 ;;
    --cwd)     CWD=${2:-}; shift 2 ;;
    --window)  WINDOW=${2:-}; shift 2 ;;
    --prompt)  PROMPT=${2:-}; shift 2 ;;
    --cancel)  ACTION=cancel; shift ;;
    --status)  ACTION=status; shift ;;
    --all)     ALL=1; shift ;;
    -h|--help) ACTION=help; shift ;;
    *) echo "park.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [ "$ACTION" = help ]; then
  echo "park.sh --session ID [--cwd DIR] [--window five_hour|seven_day] [--prompt TEXT]"
  echo "park.sh --cancel --session ID | --cancel --all | --status"
  exit 0
fi

if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    case $line in *=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}; k=${k// /}; v=${v// /}
    case $v in ''|*[!0-9]*) continue ;; esac
    [ "$k" = RESUME_DELAY_S ] && RESUME_DELAY_S=$v
  done < "$CONFIG"
fi

# ---------------------------------------------------------------------------
# status / cancel
# ---------------------------------------------------------------------------

if [ "$ACTION" = status ]; then
  found=0
  for f in "$RUN"/parked-*.env; do
    [ -f "$f" ] || continue
    found=1
    sid=''; wake=''; cwd=''
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in SESSION=*) sid=${line#*=} ;; WAKE=*) wake=${line#*=} ;; CWD=*) cwd=${line#*=} ;; esac
    done < "$f"
    when=$(date -r "$wake" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$wake")
    echo "parked  $sid  resumes $when  in $cwd"
  done
  [ "$found" = 1 ] || echo "Nothing parked."
  exit 0
fi

_unpark_one() {   # $1 = session id
  local sid=$1 label="$LABEL_PREFIX.$1"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  rm -f "$AGENTS/$label.plist" "$RUN/parked-$sid.env" "$RUN/parked-$sid"
  echo "Cancelled the scheduled resume for $sid."
}

if [ "$ACTION" = cancel ]; then
  if [ "$ALL" = 1 ]; then
    found=0
    for f in "$RUN"/parked-*.env; do
      [ -f "$f" ] || continue
      found=1
      sid=${f##*/parked-}; sid=${sid%.env}
      _unpark_one "$sid"
    done
    [ "$found" = 1 ] || echo "Nothing was parked."
    exit 0
  fi
  [ -n "$SESSION" ] || { echo "park.sh --cancel needs --session ID or --all" >&2; exit 2; }
  _unpark_one "$SESSION"
  exit 0
fi

# ---------------------------------------------------------------------------
# park
# ---------------------------------------------------------------------------

[ -n "$SESSION" ] || { echo "park.sh: --session ID is required. The budget gate prints the session id." >&2; exit 2; }
case $SESSION in
  *[!A-Za-z0-9._-]*) echo "park.sh: session id has characters that cannot go in a launchd label: $SESSION" >&2; exit 2 ;;
esac
case $WINDOW in five_hour|seven_day) ;; *) echo "park.sh: --window must be five_hour or seven_day" >&2; exit 2 ;; esac

if [ "$(uname -s)" != Darwin ]; then
  cat >&2 <<EOF
park.sh: scheduling needs launchd, and this is not macOS ($(uname -s)).

The gate and the record still work; only the automatic resume does not. Write
the record, commit it, and restart the session yourself once the window resets.
EOF
  exit 1
fi

[ -n "$CWD" ] || CWD=$PWD
[ -d "$CWD" ] || { echo "park.sh: --cwd is not a directory: $CWD" >&2; exit 2; }
[ -n "$PROMPT" ] || PROMPT=$DEFAULT_PROMPT
PROMPT=${PROMPT//$'\n'/ }

RESET=''
if [ -f "$STATE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $WINDOW in
      five_hour) case $line in FIVE_H_RESET=*)  RESET=${line#*=} ;; esac ;;
      seven_day) case $line in SEVEN_D_RESET=*) RESET=${line#*=} ;; esac ;;
    esac
  done < "$STATE"
fi
RESET=${RESET%%.*}
case $RESET in
  ''|*[!0-9]*)
    echo "park.sh: no reset time for the $WINDOW window in $STATE." >&2
    echo "         Claude Code drops a window once it has reset, so this usually means" >&2
    echo "         the window is not exhausted and there is nothing to park against." >&2
    exit 1 ;;
esac

NOW=$(date +%s)
WAKE=$((RESET + RESUME_DELAY_S))

# Round up to the next whole minute, because StartCalendarInterval only has
# minute granularity: the plist can say 15:34 but not 15:34:53. Recording the
# unrounded second made every firing look early to resume.sh, which left the job
# in place — and a job matching one minute of one day never fires again, so the
# work was stranded silently. Found by a live firing, not by reading the code.
# Rounding up rather than down also keeps the wake no earlier than the reset
# plus its delay, which is the thing the caller actually asked for.
if [ $((WAKE % 60)) -ne 0 ]; then
  WAKE=$((WAKE + 60 - WAKE % 60))
fi

if [ "$WAKE" -le "$NOW" ]; then
  echo "park.sh: the $WINDOW window reset at $(date -r "$RESET" '+%H:%M') already — nothing to park against." >&2
  exit 1
fi

MONTH=$(date -r "$WAKE" +%m); DAY=$(date -r "$WAKE" +%d)
HOUR=$(date -r "$WAKE" +%H); MIN=$(date -r "$WAKE" +%M)
# Strip the leading zero so the plist carries an integer, not an octal-looking
# string: launchd wants <integer>8</integer>, never 08.
MONTH=$((10#$MONTH)); DAY=$((10#$DAY)); HOUR=$((10#$HOUR)); MIN=$((10#$MIN))

LABEL="$LABEL_PREFIX.$SESSION"
PLIST="$AGENTS/$LABEL.plist"
ENVFILE="$RUN/parked-$SESSION.env"

mkdir -p "$RUN" "$AGENTS" || exit 1

{
  echo "SESSION=$SESSION"
  echo "CWD=$CWD"
  echo "PROMPT=$PROMPT"
  echo "WAKE=$WAKE"
  echo "LABEL=$LABEL"
  echo "PLIST=$PLIST"
} > "$ENVFILE" || exit 1

# XML-escape the three values that reach the plist. A working directory may
# legitimately contain & or <, and a plist that will not parse fails silently:
# launchd simply never runs the job.
_xml() {
  local __v=$1 s=$2
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  eval "$__v=\$s"
}
_xml X_LABEL "$LABEL"
_xml X_RESUME "$SELF_DIR/resume.sh"
_xml X_ENV "$ENVFILE"
_xml X_LOG "$HOME/.claude/budget-resume.log"

cat > "$PLIST" <<EOF || exit 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$X_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$X_RESUME</string>
    <string>$X_ENV</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Month</key><integer>$MONTH</integer>
    <key>Day</key><integer>$DAY</integer>
    <key>Hour</key><integer>$HOUR</integer>
    <key>Minute</key><integer>$MIN</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$X_LOG</string>
  <key>StandardErrorPath</key><string>$X_LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  rm -f "$PLIST" "$ENVFILE"
  echo "park.sh: launchctl refused the job. Nothing was scheduled and the session is NOT parked." >&2
  echo "         Check with: launchctl print gui/$(id -u) | grep $LABEL_PREFIX" >&2
  exit 1
fi

# Only now: the marker that closes the gate. Setting it before the job was
# accepted would leave a session unable to act and with nothing coming to wake
# it — the one failure mode worse than not parking at all.
touch "$RUN/parked-$SESSION"

echo "Parked. The $WINDOW window resets at $(date -r "$RESET" '+%a %H:%M'); this session resumes at $(date -r "$WAKE" '+%a %H:%M') in $CWD."
echo "Cancel with: \"$SELF_DIR/park.sh\" --cancel --session $SESSION"
