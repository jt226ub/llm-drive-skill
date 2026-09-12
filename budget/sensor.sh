#!/bin/bash
# statusLine command for the budget module: the sensor.
#
# WHY A STATUS LINE. Claude Code publishes plan rate-limit utilisation in
# exactly one place a local script can read without credentials: the JSON it
# pipes to the statusLine command. No hook event carries it — checked against
# the hooks reference — and the only other local trace is the `quotaLimits`
# record written into the transcript when a request is *rejected* with a 429,
# which arrives after the work has already stopped. The status line runs on
# every new assistant message, costs no tokens, and needs no network, so it is
# the sensor.
#
#   "rate_limits": {
#     "five_hour":   { "used_percentage": 23.5, "resets_at": 1738425600 },
#     "seven_day":   { "used_percentage": 41.2, "resets_at": 1738857600 },
#     "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }
#   }
#
# Each window is independently optional, the whole object is absent for API-key
# and non-subscriber sessions and until the first API response of a session, and
# Claude Code drops a window once its resets_at has passed. Absence is normal;
# it is never treated as zero.
#
# This script does two things and prints one line:
#   1. writes $HOME/.claude/budget-state, atomically, for budget/gate.sh to read
#   2. prints the status line the user sees
#
# It runs whether or not budget mode is switched on. Writing the state costs
# nothing and keeps it warm, so /budget-on takes effect on the next assistant
# message rather than after a session restart.
#
# Pure bash, like everything else here: no jq, no python, no awk. lib.sh says
# why at length. Nothing is sourced — this file is installed standalone.

STATE="$HOME/.claude/budget-state"

# Read the whole payload. `read -d ''` returns 1 at EOF having set the variable,
# which is the normal path here, so its status is deliberately ignored.
IFS= read -r -d '' PAYLOAD

# ---------------------------------------------------------------------------
# Extraction
#
# Anchoring on the key name and then bounding the search to the object that
# follows is what makes this safe against key order and against absent windows:
# the first "used_percentage" after `"five_hour": {` is five_hour's own, and
# cutting at the first `}` stops a missing member from reading a later object's
# value. Window objects hold only numbers, so the first `}` is the right one.
# ---------------------------------------------------------------------------

# _num VARNAME HAYSTACK KEY — VARNAME gets the numeric value of "KEY": <number>,
# or empty when the key is absent or the value is not a number.
_num() {
  local __v=$1 hay=$2 key=$3 rest c out=''
  case $hay in
    *"\"$key\""*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  rest=${hay#*\"$key\"}
  rest=${rest#*:}
  # Skip leading whitespace, then take the number.
  while :; do
    c=${rest:0:1}
    case $c in ' '|$'\t'|$'\n'|$'\r') rest=${rest:1} ;; *) break ;; esac
  done
  while :; do
    c=${rest:0:1}
    case $c in
      [0-9]|.|-) out="$out$c"; rest=${rest:1} ;;
      *) break ;;
    esac
  done
  eval "$__v=\$out"
  [ -n "$out" ]
}

# _scope VARNAME HAYSTACK KEY — VARNAME gets the text of the object that follows
# "KEY":, up to its first `}`. Correct only for objects that contain no nested
# object and no string, which is exactly what the rate-limit windows are.
_scope() {
  local __v=$1 hay=$2 key=$3 rest cut
  case $hay in
    *"\"$key\""*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  rest=${hay#*\"$key\"}
  case $rest in
    *'{'*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  rest=${rest#*\{}
  cut=${rest%%\}*}
  eval "$__v=\$cut"
  return 0
}

# _str VARNAME HAYSTACK KEY — VARNAME gets the string value of "KEY": "...".
# Backslash escapes are kept verbatim; this feeds the status line only.
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
      '\') out="$out${rest:0:2}"; rest=${rest:2} ;;
      '"') break ;;
      *) out="$out$c"; rest=${rest:1} ;;
    esac
  done
  eval "$__v=\$out"
  [ -n "$out" ]
}

FIVE_H_PCT=''; FIVE_H_RESET=''
SEVEN_D_PCT=''; SEVEN_D_RESET=''
SPEND_PCT=''; SPEND_RESET=''
RATE_LIMITS=absent

case $PAYLOAD in
  *'"rate_limits"'*)
    RATE_LIMITS=present
    LIMITS=${PAYLOAD#*\"rate_limits\"}
    _scope W "$LIMITS" five_hour   && { _num FIVE_H_PCT  "$W" used_percentage; _num FIVE_H_RESET  "$W" resets_at; }
    _scope W "$LIMITS" seven_day   && { _num SEVEN_D_PCT "$W" used_percentage; _num SEVEN_D_RESET "$W" resets_at; }
    _scope W "$LIMITS" spend_limit && { _num SPEND_PCT   "$W" used_percentage; _num SPEND_RESET   "$W" resets_at; }
    ;;
esac

# ---------------------------------------------------------------------------
# State file
#
# Written through a temp file in the same directory and moved into place, so a
# reader never sees a half-written file. The status line is cancelled and
# re-run whenever an update arrives while it is still going, which makes a
# torn write a matter of when, not if.
#
# ONLY WHEN THIS SESSION HAS PLAN LIMITS TO REPORT. budget-state describes the
# account, not this session, and a session without rate_limits knows nothing
# about the account — so it must not overwrite what a session that does know
# wrote. Two real cases make that more than theory: every session's first status
# line runs before its first API response and so carries no rate_limits, and any
# session pointed at a non-Anthropic endpoint or an API key never carries them
# at all. Writing RATE_LIMITS=absent from either would put the gate into its
# fail-open state while the real numbers were sitting on disk a moment earlier.
# Leaving the file alone hands the decision to the gate's staleness check, which
# is the thing that actually knows how old is too old.
# ---------------------------------------------------------------------------
if [ "$RATE_LIMITS" = present ]; then
  TMP="$STATE.tmp.$$"
  {
    echo "# written by drive-budget sensor.sh — do not edit, it is rewritten constantly"
    echo "UPDATED=$(date +%s)"
    echo "RATE_LIMITS=$RATE_LIMITS"
    echo "FIVE_H_PCT=$FIVE_H_PCT"
    echo "FIVE_H_RESET=$FIVE_H_RESET"
    echo "SEVEN_D_PCT=$SEVEN_D_PCT"
    echo "SEVEN_D_RESET=$SEVEN_D_RESET"
    echo "SPEND_PCT=$SPEND_PCT"
    echo "SPEND_RESET=$SPEND_RESET"
  } > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# The line itself
# ---------------------------------------------------------------------------

# _hhmm EPOCH — local wall-clock HH:MM. BSD date takes -r, GNU date takes -d @.
_hhmm() {
  [ -n "$1" ] || return 1
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null
}

# Whole percent, rounded down. bash 3.2 has no floating point, and truncating
# is the conservative direction: 96.9% does not trip a 97% threshold.
_whole() { local n=${1%%.*}; [ -n "$n" ] && echo "$n"; }

_str MODEL "$PAYLOAD" display_name
_str DIR "$PAYLOAD" current_dir
[ -n "$DIR" ] && DIR=${DIR##*/}

LINE=''
[ -n "$MODEL" ] && LINE="$MODEL"
[ -n "$DIR" ] && LINE="${LINE:+$LINE · }$DIR"

if [ "$RATE_LIMITS" = present ]; then
  if [ -n "$FIVE_H_PCT" ]; then
    T=$(_hhmm "$FIVE_H_RESET")
    LINE="${LINE:+$LINE · }5h $(_whole "$FIVE_H_PCT")%${T:+ →$T}"
  fi
  [ -n "$SEVEN_D_PCT" ] && LINE="${LINE:+$LINE · }7d $(_whole "$SEVEN_D_PCT")%"
  [ -n "$SPEND_PCT" ] && LINE="${LINE:+$LINE · }spend $(_whole "$SPEND_PCT")%"
else
  # Said out loud rather than left blank. A status line that silently shows no
  # budget is the same failure this project already fixed once in the hook: the
  # user cannot tell "nothing to report" from "the sensor is broken".
  LINE="${LINE:+$LINE · }no plan limits in this session"
fi

[ -f "$HOME/.claude/budget-mode" ] || LINE="$LINE · budget off"

echo "$LINE"
exit 0
