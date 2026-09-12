#!/bin/bash
# What launchd runs when a parked session's window has reset.
#
#   resume.sh /path/to/parked-<session>.env
#
# It clears the gate for that session, starts the session again in the
# background, and removes its own launchd job so it never fires twice.
#
# Everything is logged to $HOME/.claude/budget-resume.log, because this runs
# with nobody watching: a resume that failed silently would look exactly like a
# resume that never came due.

set -u

RUN="$HOME/.claude/budget-run"

# stdout and stderr are the log: the plist points both at
# $HOME/.claude/budget-resume.log, so everything printed here lands there.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ENVFILE=${1:-}
[ -n "$ENVFILE" ] && [ -f "$ENVFILE" ] || { log "resume: no env file at '${ENVFILE:-}' — nothing to do."; exit 1; }

SESSION=''; CWD=''; PROMPT=''; WAKE=''; LABEL=''; PLIST=''
while IFS= read -r line || [ -n "$line" ]; do
  k=${line%%=*}; v=${line#*=}
  case $k in
    SESSION|CWD|PROMPT|WAKE|LABEL|PLIST) eval "$k=\$v" ;;
  esac
done < "$ENVFILE"

[ -n "$SESSION" ] || { log "resume: env file has no SESSION — $ENVFILE"; exit 1; }

NOW=$(date +%s)
case $WAKE in
  ''|*[!0-9]*) ;;
  *) if [ "$NOW" -lt "$WAKE" ]; then
       # launchd fired early, which it should not. Leave the job in place and
       # let the next firing do the work rather than resuming into a window
       # that has not reset.
       log "resume: woke $((WAKE - NOW))s early for $SESSION — leaving the job scheduled."
       exit 0
     fi ;;
esac

# The gate is cleared first. If the resume itself fails, a session that can act
# is a better place to land than one still gated shut with no job coming.
rm -f "$RUN/parked-$SESSION" "$RUN/calls" "$RUN/warned"

# launchd jobs start with a minimal PATH, and Claude Code's own installer puts
# the binary somewhere login shells find and launchd does not.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
CLAUDE=$(command -v claude 2>/dev/null)
if [ -z "$CLAUDE" ]; then
  log "resume: cannot find the claude binary on PATH — nothing was started for $SESSION."
  log "resume: the gate has been cleared, so picking the work up by hand will work."
else
  cd "$CWD" 2>/dev/null || log "resume: cannot cd to '$CWD', starting in $PWD instead"
  log "resume: starting a new session in $PWD for the work parked as $SESSION"

  # A NEW SESSION, NOT --resume. This is the correction of 2026-09-12: the first
  # live firing hung for 35 minutes because `claude --bg --resume <id>` does not
  # return when that session is still running — and a parked interactive session
  # is still running, always. Parking does not exit a session; it ends its turn
  # and gates its tools, so the session is idle-but-alive at wake time and
  # "already running" is the normal case rather than an edge one.
  #
  # Measured on this machine: `claude --bg "<prompt>"` on a fresh session returns
  # in 0s with exit 0 and no TTY; the same command with --resume against a live
  # session never returns at all.
  #
  # HANDOFF.md is what carries the work across, which is why the gate makes the
  # session write it before parking. A fresh session reading that file is also a
  # better starting point than the exhausted context that hit the wall.
  #
  # Bounded, because this runs unattended: nothing launchd starts may hang
  # forever. The wait is generous relative to the 0s this takes when it works.
  "$CLAUDE" --bg "$PROMPT" < /dev/null 2>&1 &
  CPID=$!
  WAITED=0
  while [ "$WAITED" -lt 60 ] && kill -0 "$CPID" 2>/dev/null; do
    sleep 2
    WAITED=$((WAITED + 2))
  done
  if kill -0 "$CPID" 2>/dev/null; then
    kill "$CPID" 2>/dev/null
    log "resume: claude did not return within ${WAITED}s — killed it. Nothing was started."
  else
    wait "$CPID"
    log "resume: claude exited $? after ${WAITED}s"
  fi
fi

# Self-removal, last. A StartCalendarInterval job with a month and day set would
# otherwise sit there and fire again next year.
if [ -n "$LABEL" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  [ -n "$PLIST" ] && rm -f "$PLIST"
  log "resume: job $LABEL removed."
fi
rm -f "$ENVFILE"
