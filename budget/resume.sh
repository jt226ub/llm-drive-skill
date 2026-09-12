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
  log "resume: cannot find the claude binary on PATH — session $SESSION was NOT resumed."
  log "resume: the gate has been cleared, so resuming it by hand will work: claude --resume $SESSION"
else
  cd "$CWD" 2>/dev/null || log "resume: cannot cd to '$CWD', starting in $PWD instead"
  log "resume: starting session $SESSION in $PWD"
  "$CLAUDE" --bg --resume "$SESSION" "$PROMPT" 2>&1
  log "resume: claude exited $?"
fi

# Self-removal, last. A StartCalendarInterval job with a month and day set would
# otherwise sit there and fire again next year.
if [ -n "$LABEL" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  [ -n "$PLIST" ] && rm -f "$PLIST"
  log "resume: job $LABEL removed."
fi
rm -f "$ENVFILE"
