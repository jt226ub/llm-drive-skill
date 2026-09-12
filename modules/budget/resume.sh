#!/bin/bash
# What launchd runs when a parked session's window has reset.
#
#   resume.sh /path/to/parked-<session>.env
#
# It clears the gate for that session and then does one of two things, chosen by
# whether that session is still running: nudges the person if it is, or starts a
# new session from HANDOFF.md if it is not. Either way it removes its own
# launchd job so it never fires twice.
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
       # Early. park.sh now rounds the wake time up to a whole minute so this
       # should not happen, but clock adjustment can still do it — and there is
       # no second chance: a StartCalendarInterval job matching one minute of
       # one day never fires again, so exiting here strands the work silently.
       # That is exactly what happened on the first live firing.
       #
       # So wait the remainder out when it is short, and only give up when the
       # gap is too large to be jitter, where waiting would mean sleeping in a
       # launchd job for an unbounded time.
       GAP=$((WAKE - NOW))
       if [ "$GAP" -le 120 ]; then
         log "resume: woke ${GAP}s early for $SESSION — waiting it out."
         sleep "$GAP"
       else
         log "resume: woke ${GAP}s early for $SESSION — too early to be jitter; leaving the job and doing nothing."
         exit 0
       fi
     fi ;;
esac

# The gate is cleared first. If the resume itself fails, a session that can act
# is a better place to land than one still gated shut with no job coming.
rm -f "$RUN/parked-$SESSION" "$RUN/calls" "$RUN/warned"

# launchd jobs start with a minimal PATH, and Claude Code's own installer puts
# the binary somewhere login shells find and launchd does not.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# _bounded SECONDS OUTFILE COMMAND... — run a command with its output captured,
# and kill it if it overruns. Nothing launchd starts may hang forever: the first
# live firing of this script waited thirty-five minutes on a call that never
# returned, logged nothing, and left its job loaded. A job that fails is
# recoverable; one that hangs fails silently.
_bounded() {
  local limit=$1 out=$2; shift 2
  "$@" < /dev/null > "$out" 2>&1 &
  local pid=$! waited=0
  while [ "$waited" -lt "$limit" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    _BOUNDED_WAITED=$waited
    return 124
  fi
  wait "$pid"
  local rc=$?
  _BOUNDED_WAITED=$waited
  return $rc
}

CLAUDE=$(command -v claude 2>/dev/null)
if [ -z "$CLAUDE" ]; then
  log "resume: cannot find the claude binary on PATH — nothing was started for $SESSION."
  log "resume: the gate has been cleared, so picking the work up by hand will work."
else
  cd "$CWD" 2>/dev/null || log "resume: cannot cd to '$CWD', starting in $PWD instead"

  # IS THE PARKED SESSION STILL ALIVE? This branch is the correction of
  # 2026-09-12. Parking does not exit a session — it ends a turn and gates the
  # tools — so an interactive session is idle-but-alive at wake time, and
  # `claude --bg --resume <id>` against a live session never returns, which is
  # what hung the first firing.
  #
  # But the fix is not to abandon it and start fresh either: that session was
  # left open with its context for a reason, and its context is the expensive
  # thing. Nothing outside a session can type into it — there is no messaging
  # subcommand, `--continue` refuses a session that is still running, and the
  # only transport is a private socket this project will not depend on. So when
  # the session is alive the honest move is to clear the gate and tell the
  # person, who can continue it in one keystroke with everything intact.
  #
  # When it is gone, unattended continuation is still wanted and a new session
  # reading HANDOFF.md is the way to get it. The gate forces that file to be
  # written before parking precisely so this case works.
  #
  # A live session is listed by `claude agents --json` with its id in quotes.
  # Substring, not parsing: bash can do this and a JSON runtime is not a
  # dependency this project accepts.
  ALIVE=0
  if _bounded 20 "$RUN/agents.$$" "$CLAUDE" agents --json; then
    case "$(cat "$RUN/agents.$$" 2>/dev/null)" in
      *"\"$SESSION\""*) ALIVE=1 ;;
    esac
  else
    log "resume: could not list sessions (rc $?), so assuming $SESSION is gone."
  fi
  rm -f "$RUN/agents.$$"

  if [ "$ALIVE" = 1 ]; then
    log "resume: $SESSION is still running — gate cleared, context kept, nudging instead."
    NOTE="Budget window reset. Your parked session in $(basename "$CWD") can continue — its tools are open again."
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"$NOTE\" with title \"drive budget\" sound name \"Ping\"" 2>/dev/null \
        || log "resume: osascript refused the notification; the gate is still cleared."
    else
      log "resume: no osascript on this platform, so no notification was posted."
    fi
    log "resume: $NOTE"
  else
    log "resume: $SESSION is gone — starting a new session in $PWD from HANDOFF.md"
    if _bounded 60 "$RUN/start.$$" "$CLAUDE" --bg "$PROMPT"; then
      log "resume: claude exited 0 after ${_BOUNDED_WAITED}s"
    else
      log "resume: claude failed or overran after ${_BOUNDED_WAITED}s — nothing was started."
    fi
    rm -f "$RUN/start.$$"
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
