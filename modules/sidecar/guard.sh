#!/bin/bash
# PreToolUse hook: stop a sidecar worker from publishing its work.
#
# A worker hands work back as a branch for the session that dispatched it to
# review and merge. Pushing skips that review, and does it unattended.
#
# There are two guards and this is the second of them. The first is a refusing
# `pre-push` reached through GIT_CONFIG_* at launch, which holds regardless of
# how git is invoked. This one inspects the command text before it runs, which
# the permissions reference recommends for exactly this — "to inspect the full
# command text with your own logic before it runs, use a PreToolUse hook" —
# and which catches routes that are not git at all. Neither is sufficient alone:
# the git hook cannot see a non-git publish, and this cannot see an obfuscated
# command. They fail differently, which is the point.
#
# THIS HOOK RUNS IN EVERY SESSION, so it must be cheap and it must do nothing at
# all unless the session is a known worker. It fails open: a session it cannot
# identify is not a worker as far as this is concerned, because gating an
# ordinary session over a lookup that went wrong would be a worse bug than the
# one being prevented.
#
# Pure bash. Nothing is sourced — this file is installed standalone.

RUN="$HOME/.claude/sidecar-run"

# Not a worker unless proven otherwise, and there is nothing to prove it with.
[ -d "$RUN" ] || exit 0

IFS= read -r -d '' HOOK_JSON

# _str VARNAME HAYSTACK KEY — the string value of "KEY": "...", or empty.
_str() {
  local __v=$1 __hay=$2 __key=$3 __r __o='' __c
  case $__hay in
    *"\"$__key\""*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  __r=${__hay#*\"$__key\"}
  __r=${__r#*:}
  while :; do
    __c=${__r:0:1}
    case $__c in ' '|$'\t'|$'\n'|$'\r') __r=${__r:1} ;; *) break ;; esac
  done
  [ "${__r:0:1}" = '"' ] || { eval "$__v=''"; return 1; }
  __r=${__r:1}
  while [ -n "$__r" ]; do
    __c=${__r:0:1}
    case $__c in
      '\') __o="$__o${__r:1:1}"; __r=${__r:2} ;;
      '"') break ;;
      *) __o="$__o$__c"; __r=${__r:1} ;;
    esac
  done
  eval "$__v=\$__o"
  [ -n "$__o" ]
}

_str SESSION_ID "$HOOK_JSON" session_id
_str TOOL_NAME  "$HOOK_JSON" tool_name
[ -n "$SESSION_ID" ] || exit 0
[ "$TOOL_NAME" = Bash ] || exit 0

# Is this session one of ours? The launcher records `session=<id>` for each
# worker it starts, so the answer is a scan of small files rather than anything
# clever.
IS_WORKER=0
WORKER_NAME=''
for f in "$RUN"/*.env; do
  [ -f "$f" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "session=$SESSION_ID") IS_WORKER=1 ;;
      worker=*) WORKER_NAME=${line#*=} ;;
    esac
  done < "$f"
  [ "$IS_WORKER" = 1 ] && break
  WORKER_NAME=''
done
[ "$IS_WORKER" = 1 ] || exit 0

# The command text. `command` is the Bash tool's own parameter name, and the
# only one in this payload, so the plain scan finds it.
_str CMD "$HOOK_JSON" command
[ -n "$CMD" ] || exit 0

# Deliberately broader than a permission rule: any git invocation that mentions
# pushing, however it is spelled. A worker has no legitimate reason to push, so
# a false positive costs it one refused command and a clear explanation, while a
# false negative costs unreviewed work on someone's remote.
case $CMD in
  *push*) ;;
  *) exit 0 ;;
esac
case $CMD in
  *git*) ;;
  *) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
  "sidecar: this session is the worker ${WORKER_NAME:-?}, and a worker does not publish. Commit to your branch and stop; the session that dispatched you reviews the diff and merges it. If the work is finished, say so and end your turn."
exit 0
