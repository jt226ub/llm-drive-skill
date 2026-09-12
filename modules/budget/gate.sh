#!/bin/bash
# The budget gate. Registered twice:
#
#   gate.sh prompt   as a UserPromptSubmit hook — stdout becomes turn context
#   gate.sh tool     as a PreToolUse hook       — stdout is a JSON decision
#
# It reads $HOME/.claude/budget-state, which budget/sensor.sh writes from the
# status line payload, and acts on two windows: the rolling 5-hour session
# window and the 7-day weekly window.
#
#   below WRAP_PCT        nothing but a one-line status on the prompt hook
#   at WRAP_PCT           stop starting work, write the record, park
#   at STOP_PCT           every tool but the record-writing set is denied, and
#                         that allowance is bounded at HANDOFF_CALLS
#   weekly thresholds     the same two stages against the 7-day window, except
#                         that there is no automatic resume from a weekly limit
#
# Subagents get a shorter path: at the hard threshold their tool access closes
# outright and they are told to return their findings. A subagent has no record
# to write — the session that dispatched it does.
#
# WHEN THE SENSOR IS NOT REPORTING, THIS FAILS OPEN AND SAYS SO. A gate that
# denied tools because it could not read a state file would brick the session
# over its own bug. So `tool` stays silent and allows, and `prompt` prints a
# loud notice once per turn — the same lesson as the jq failure this project
# already fixed: not reporting is worse than not working.
#
# Pure bash. Nothing is sourced, including the state and config files: they are
# parsed, because sourcing a file turns a stray line in it into code.

MODE=${1:-prompt}
FLAG="$HOME/.claude/budget-mode"
STATE="$HOME/.claude/budget-state"
CONFIG="$HOME/.claude/budget-config"
RUN="$HOME/.claude/budget-run"
BUDGET_MD="$HOME/.claude/drive-budget/BUDGET.md"

[ -f "$FLAG" ] || exit 0

IFS= read -r -d '' HOOK_JSON

# ---------------------------------------------------------------------------
# Reading the hook payload
# ---------------------------------------------------------------------------

# _str VARNAME HAYSTACK KEY — the string value of "KEY": "...", or empty.
_str() {
  local __v=$1 hay=$2 key=$3 rest out='' c
  case $hay in
    *"\"$key\""*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  rest=${hay#*\"$key\"}
  rest=${rest#*:}
  while :; do
    c=${rest:0:1}
    case $c in ' '|$'\t'|$'\n'|$'\r') rest=${rest:1} ;; *) break ;; esac
  done
  [ "${rest:0:1}" = '"' ] || { eval "$__v=''"; return 1; }
  rest=${rest:1}
  while [ -n "$rest" ]; do
    c=${rest:0:1}
    case $c in
      '\') out="$out${rest:1:1}"; rest=${rest:2} ;;
      '"') break ;;
      *) out="$out$c"; rest=${rest:1} ;;
    esac
  done
  eval "$__v=\$out"
  [ -n "$out" ]
}

_str SESSION_ID "$HOOK_JSON" session_id
_str TOOL_NAME  "$HOOK_JSON" tool_name
_str AGENT_ID   "$HOOK_JSON" agent_id

# ---------------------------------------------------------------------------
# Configuration
#
# The defaults are the answer to "how much of the window is worth reserving so
# the record can still be written". Five-hour: wrap at 97, gate at 99. Weekly:
# document at 90 — a weekly limit costs days, not hours, so it is worth starting
# the record much earlier — and gate at 97.
#
# $HOME/.claude/budget-config overrides them. install.sh writes it once with
# these values and never overwrites it, so an edit survives a reinstall.
# ---------------------------------------------------------------------------
WRAP_PCT=97
STOP_PCT=99
WEEK_DOC_PCT=90
WEEK_STOP_PCT=97
HANDOFF_CALLS=25

if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    case $line in *=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    k=${k// /}; v=${v// /}
    case $v in ''|*[!0-9]*) continue ;; esac
    case $k in
      WRAP_PCT|STOP_PCT|WEEK_DOC_PCT|WEEK_STOP_PCT|HANDOFF_CALLS) eval "$k=\$v" ;;
    esac
  done < "$CONFIG"
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
UPDATED=''; RATE_LIMITS=''
FIVE_H_PCT=''; FIVE_H_RESET=''
SEVEN_D_PCT=''; SEVEN_D_RESET=''
SPEND_PCT=''; SPEND_RESET=''

if [ -f "$STATE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in \#*|'') continue ;; *=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    case $k in
      UPDATED|FIVE_H_PCT|FIVE_H_RESET|SEVEN_D_PCT|SEVEN_D_RESET|SPEND_PCT|SPEND_RESET)
        case $v in ''|*[!0-9.]*) v='' ;; esac
        eval "$k=\$v" ;;
      RATE_LIMITS)
        case $v in present|absent) RATE_LIMITS=$v ;; esac ;;
    esac
  done < "$STATE"
fi

NOW=$(date +%s)

# Whole percent, rounded down. bash 3.2 has no floating point; truncating is the
# conservative direction, so 96.9% does not trip a 97% threshold.
_whole() { local n=${1%%.*}; case $n in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac; }
FIVE_H=$(_whole "$FIVE_H_PCT")
SEVEN_D=$(_whole "$SEVEN_D_PCT")

# The sensor is considered to be reporting when it wrote within the hour. The
# status line re-runs on every assistant message, so an hour of silence means
# no session has been active — or the sensor is not installed.
STALE=1
case $UPDATED in
  ''|*[!0-9]*) ;;
  *) [ $((NOW - UPDATED)) -lt 3600 ] && STALE=0 ;;
esac

# ---------------------------------------------------------------------------
# Which level applies
# ---------------------------------------------------------------------------
# The parked marker holds the moment the park is spent — the wake time park.sh
# scheduled. Past that, it is removed and ignored.
#
# It must expire on its own, and without consulting the sensor, for two reasons.
# Claude Code's own automatic continue resumes an interactive session the instant
# the limit resets, which is *before* the scheduled wake, and it would land on a
# gate that denies every tool and achieve nothing. And a parked session cannot
# un-park itself — the gate denies the very tools it would need — so a marker
# that outlives its window with no way to clear itself is the worst state this
# module can produce.
#
# A marker with no readable timestamp is treated as spent. That is the
# fail-open direction, and it is the right one here for the same reason.
PARKED=0
if [ -n "$SESSION_ID" ] && [ -f "$RUN/parked-$SESSION_ID" ]; then
  PARK_UNTIL=''
  read -r PARK_UNTIL < "$RUN/parked-$SESSION_ID" 2>/dev/null
  case $PARK_UNTIL in
    ''|*[!0-9]*) rm -f "$RUN/parked-$SESSION_ID" 2>/dev/null ;;
    *) if [ "$NOW" -ge "$PARK_UNTIL" ]; then
         rm -f "$RUN/parked-$SESSION_ID" 2>/dev/null
       else
         PARKED=1
       fi ;;
  esac
fi

# A sidecar worker runs on another provider's money and spends none of these
# windows, so gating it would stop work that costs nothing to continue. It is
# told what is happening instead, and never denied.
#
# The same scan lives in the sidecar module's guard.sh, which is installed
# standalone and cannot source anything either. Both read the launcher's own
# records, so they agree by construction rather than by being kept in step.
WORKER=0
if [ -n "$SESSION_ID" ] && [ -d "$HOME/.claude/sidecar-run" ]; then
  for wf in "$HOME/.claude/sidecar-run"/*.env; do
    [ -f "$wf" ] || continue
    while IFS= read -r wline || [ -n "$wline" ]; do
      case $wline in "session=$SESSION_ID") WORKER=1 ;; esac
    done < "$wf"
    [ "$WORKER" = 1 ] && break
  done
fi

LEVEL=none
# Parking is one session deciding it is finished, not a statement about the
# machine, which is why the marker is per session: a second session still has
# its own record to write and must not be gated out of writing it.
if [ "$PARKED" = 1 ]; then
  LEVEL=parked
elif [ "$STALE" = 1 ] || [ "$RATE_LIMITS" != present ]; then
  LEVEL=unknown
elif [ "$FIVE_H" -ge "$STOP_PCT" ]; then
  LEVEL=stop
elif [ "$SEVEN_D" -ge "$WEEK_STOP_PCT" ]; then
  LEVEL=week_stop
elif [ "$FIVE_H" -ge "$WRAP_PCT" ]; then
  LEVEL=wrap
elif [ "$SEVEN_D" -ge "$WEEK_DOC_PCT" ]; then
  LEVEL=week_doc
fi

# A worker is neither gated nor asked to write the session's record: it is told
# what the orchestrator's situation is, so it does not wait for a reply that
# cannot come, and then it gets on with the task it was given. This is checked
# before the subagent branch because a worker's own subagents share its session
# id and are on the same provider's money.
if [ "$WORKER" = 1 ]; then
  case $LEVEL in
    stop|wrap)          LEVEL=worker_five_hour ;;
    week_stop|week_doc) LEVEL=worker_weekly ;;
    parked|subagent)    LEVEL=none ;;
  esac
fi

# A subagent at a hard threshold gets told to return, not to write a record.
if [ "$WORKER" = 0 ] && [ -n "$AGENT_ID" ]; then
  case $LEVEL in stop|week_stop|parked) LEVEL=subagent ;; esac
fi

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

# _hhmm EPOCH — local wall-clock. BSD date takes -r, GNU date takes -d @.
_hhmm() {
  case $1 in ''|*[!0-9]*) return 1 ;; esac
  date -r "$1" '+%a %H:%M' 2>/dev/null || date -d "@$1" '+%a %H:%M' 2>/dev/null
}

_status_line() {
  local t
  if [ "$LEVEL" = unknown ]; then
    if [ "$RATE_LIMITS" = absent ]; then
      echo "Budget: this session reports no plan rate limits (API key, or not a Claude.ai subscription). The gate is inactive."
    else
      echo "Budget: NO USAGE DATA — $HOME/.claude/budget-state is missing or over an hour old, so the gate is inactive and cannot stop anything. The status line sensor is how it is fed; check that settings.json still points statusLine at drive-budget/sensor.sh."
    fi
    return
  fi
  # A window Claude Code has dropped because it just reset reads as -1 here, and
  # printing "5h -1%" is worse than printing nothing: it looks like a bug in the
  # meter rather than an empty window. Say the window is fresh instead.
  if [ "$FIVE_H" -lt 0 ]; then
    t="Budget: 5h window fresh"
  else
    t="Budget: 5h ${FIVE_H}%"
    local r; r=$(_hhmm "$FIVE_H_RESET") && t="$t (resets $r)"
  fi
  [ "$SEVEN_D" -ge 0 ] && t="$t · 7d ${SEVEN_D}%"
  echo "$t"
}

# _section MARKER — print BUDGET.md between <!-- @MARKER --> and the next marker.
_section() {
  local want="<!-- @$1 -->" on=0 line
  [ -f "$BUDGET_MD" ] || { echo "(budget directives missing: $BUDGET_MD)"; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "$want") on=1; continue ;;
      '<!-- @'*) [ "$on" = 1 ] && break ;;
    esac
    [ "$on" = 1 ] && printf '%s\n' "$line"
  done < "$BUDGET_MD"
}

# The directive for the current level, with the session id substituted in so the
# park command can be run verbatim.
_directive() {
  local text
  # $( ) strips trailing newlines, so the blank line between a directive and the
  # schema has to be put back explicitly or the two run together mid-word.
  case $LEVEL in
    wrap)      text="$(_section WRAP)"$'\n\n'"$(_section SCHEMA)" ;;
    stop)      text="$(_section STOP)"$'\n\n'"$(_section SCHEMA)" ;;
    week_doc)  text="$(_section WEEK_DOC)"$'\n\n'"$(_section SCHEMA)" ;;
    week_stop) text="$(_section WEEK_STOP)"$'\n\n'"$(_section SCHEMA)" ;;
    subagent)  text="$(_section SUBAGENT)" ;;
    parked)    text="$(_section PARKED)" ;;
    worker_five_hour) text="$(_section WORKER_FIVE_HOUR)" ;;
    worker_weekly)    text="$(_section WORKER_WEEKLY)" ;;
    *)         return 1 ;;
  esac
  [ -n "$SESSION_ID" ] && text=${text//SESSION_ID/$SESSION_ID}
  # The worker sections name the moment the orchestrator comes back.
  local __when
  __when=$(_hhmm "$FIVE_H_RESET") || __when="its next reset"
  text=${text//FIVE_HOUR_RESET/$__when}
  __when=$(_hhmm "$SEVEN_D_RESET") || __when="its next reset"
  text=${text//SEVEN_DAY_RESET/$__when}
  printf '%s\n' "$text"
}

# ---------------------------------------------------------------------------
# UserPromptSubmit: plain stdout is added to the turn's context.
# ---------------------------------------------------------------------------
if [ "$MODE" = prompt ]; then
  _status_line
  _directive
  exit 0
fi

# ---------------------------------------------------------------------------
# PreToolUse: stdout is a JSON decision.
# ---------------------------------------------------------------------------

_json_escape() {
  local __v=$1 s=$2
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  eval "$__v=\$s"
}

_deny() {
  local esc; _json_escape esc "$1"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  exit 0
}

# Context only. This never returns "allow": the user's own permission rules
# decide that, and a hook that granted permission as a side effect of budget
# accounting would be a far worse bug than the one it is preventing.
_context() {
  local esc; _json_escape esc "$1"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$esc"
  exit 0
}

case $LEVEL in
  none|unknown) exit 0 ;;

  worker_five_hour|worker_weekly)
    # Never a deny. The worker is spending another provider's money, so there is
    # nothing here to protect by stopping it. Rate-limited to once every five
    # minutes for the same reason the wrap warning is: a long run should hear
    # this, and should not hear it on every tool call.
    mkdir -p "$RUN" 2>/dev/null
    LAST=0
    [ -f "$RUN/warned-$SESSION_ID" ] && read -r LAST < "$RUN/warned-$SESSION_ID"
    case $LAST in ''|*[!0-9]*) LAST=0 ;; esac
    [ $((NOW - LAST)) -lt 300 ] && exit 0
    echo "$NOW" > "$RUN/warned-$SESSION_ID" 2>/dev/null
    _context "$(_directive)"
    ;;

  wrap|week_doc)
    # A reminder on every tool call would be noise, and the directive already
    # went out on the prompt hook. Repeat it at most once every five minutes, so
    # a long turn that crosses the threshold mid-run still hears about it.
    mkdir -p "$RUN" 2>/dev/null
    LAST=0
    [ -f "$RUN/warned" ] && read -r LAST < "$RUN/warned"
    case $LAST in ''|*[!0-9]*) LAST=0 ;; esac
    [ $((NOW - LAST)) -lt 300 ] && exit 0
    echo "$NOW" > "$RUN/warned" 2>/dev/null
    _context "$(_status_line)
$(_directive)"
    ;;

  subagent|parked)
    _deny "$(_status_line)
$(_directive)"
    ;;

  stop|week_stop)
    # The record-writing set. Everything else — subagents above all, which fan
    # out and spend the window fastest — is denied outright.
    ALLOWED="Read Write Edit MultiEdit NotebookEdit Glob Grep TodoWrite Bash"
    HIT=0
    for t in $ALLOWED; do [ "$t" = "$TOOL_NAME" ] && HIT=1; done
    if [ "$HIT" = 0 ]; then
      _deny "$(_status_line). The window is spent and the gate is closed. $TOOL_NAME is not one of the tools that can write the record. Write HANDOFF.md, commit it, park the session, and end the turn."
    fi

    # The allowance is bounded: without a ceiling, "write the record" is an
    # unlimited licence to keep calling Read and Bash. The counter is keyed to
    # the window's reset, so a new window starts it over.
    mkdir -p "$RUN" 2>/dev/null
    case $LEVEL in stop) STAMP=$FIVE_H_RESET ;; *) STAMP=$SEVEN_D_RESET ;; esac
    PREV=''; N=0
    if [ -f "$RUN/calls" ]; then read -r PREV N < "$RUN/calls"; fi
    case $N in ''|*[!0-9]*) N=0 ;; esac
    [ "$PREV" = "$STAMP" ] || N=0
    N=$((N + 1))
    echo "$STAMP $N" > "$RUN/calls" 2>/dev/null
    if [ "$N" -gt "$HANDOFF_CALLS" ]; then
      _deny "$(_status_line). The gate allowed $HANDOFF_CALLS calls to write the record and they are used up. Stop now: end the turn with what stands, and say the record was not finished."
    fi
    # The full directive once, then a running count. Repeating several hundred
    # lines on each of the allowed calls would spend the window it is trying to
    # protect.
    if [ "$N" = 1 ]; then
      _context "$(_status_line)
$(_directive)"
    fi
    _context "$(_status_line). Record allowance: $N of $HANDOFF_CALLS used. Write HANDOFF.md, commit it, park the session, end the turn."
    ;;
esac

exit 0
