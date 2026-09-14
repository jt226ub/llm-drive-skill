#!/bin/bash
# Delegate coding work to a model on another provider, inside Claude Code.
#
#   sidecar.sh start  --task TEXT [--provider NAME] [--model SLUG] [--permission-mode MODE]
#   sidecar.sh status
#   sidecar.sh collect --worker NAME     the diff it produced, and what it cost
#   sidecar.sh stop    --worker NAME
#   sidecar.sh spend                     month to date against the cap
#
# The worker is a second Claude Code session pointed at another endpoint, so it
# gets the real harness — the real tools, the real permission system, the real
# hooks — and needs nothing explained to it. It spends the provider's money and
# none of the claude.ai subscription's rate-limit windows.
#
# Four things here are load-bearing and each was learned by breaking it. They
# are in DESIGN.md §10a and §10b with the evidence, and in short:
#
#   1. --model takes a Claude alias, never a provider id. Claude Code checks
#      model names against its own catalogue before a request leaves, so a
#      provider id kills the session even though the endpoint accepts it.
#   2. The permission mode must not be narrowed. acceptEdits let the worker
#      write a file and then stalled it on the commit with nobody to answer.
#   3. No CLAUDE_CONFIG_DIR. Permissions resolve from the config directory and
#      the working directory, so the default gives the worker exactly the
#      orchestrator's permissions in that folder — and the drive contract with
#      them. An isolated directory inherits nothing.
#   4. No worktree machinery. Claude Code makes one for a background session by
#      itself; collect finds it rather than creating it.
#
# Pure bash, like the rest of this project. `claude`, `git` and `date` are the
# only commands, and a sidecar without `claude` has nothing to launch anyway.

set -u

FLAG="$HOME/.claude/sidecar-mode"
CREDS="$HOME/.claude/sidecar-credentials"
RUN="$HOME/.claude/sidecar-run"
LEDGER="$HOME/.claude/sidecar-ledger"
BALANCE="$HOME/.claude/sidecar-balance"
EXTRA="$HOME/.claude/statusline-extra"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HOME/.claude/sidecar-config"
# The monthly spend cap, in whole dollars, for token-billed providers. `start`
# refuses a provider that has reached its cap (D17); requests-, quota- and
# time-billed providers have their own caps in their profiles. Read from CONFIG
# so it is not baked into the script.
CAP_USD=80
if [ -f "$CONFIG" ]; then
  while IFS= read -r __cl || [ -n "$__cl" ]; do
    __cl=${__cl%%#*}
    case $__cl in CAP_USD=*) __cv=${__cl#*=}; __cv=${__cv// /}; case $__cv in ""|*[!0-9]*) ;; *) CAP_USD=$__cv ;; esac ;; esac
  done < "$CONFIG"
fi

die() { echo "sidecar: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Every local here is __-prefixed for the reason spelled out above _price: these
# return by `eval "$1=..."`, so a local sharing a name with the variable the
# caller asked for gets assigned instead, and the caller silently receives
# nothing. _credential had exactly that — called as `_credential key KEY` while
# declaring `local key=$2` — and it shipped an empty credential without a word.

# _rules_section VARNAME FILE SECTION — the body of `## SECTION` in a provider's
# rules of engagement (providers/NAME.rules.md), up to the next `## ` heading,
# without the blank lines at either end. Returns 1 when the file or the section
# is absent or empty, so a provider without rules changes nothing. Two sections
# are read: `## Orchestrator` (how the dispatching session should use this
# model — the sidecar-mode hook injects it) and `## Worker` (appended to the
# worker's system prompt after the hand-off brief).
_rules_section() {
  local __rl __in=0 __body='' __want="## $3"
  [ -f "$2" ] || return 1
  while IFS= read -r __rl || [ -n "$__rl" ]; do
    if [ "$__in" = 1 ]; then
      case $__rl in "## "*) break ;; esac
      __body="$__body$__rl"$'\n'
    elif [ "$__rl" = "$__want" ]; then
      __in=1
    fi
  done < "$2"
  while [ "${__body#$'\n'}" != "$__body" ]; do __body=${__body#$'\n'}; done
  while [ "${__body%$'\n'}" != "$__body" ]; do __body=${__body%$'\n'}; done
  [ -n "$__body" ] || return 1
  eval "$1=\$__body"
}

# _agy_stats TURNS_VAR IN_VAR OUT_VAR CACHED_VAR THINK_VAR FILE — counts from
# the one JSON envelope `agy -p … --output-format json` prints on exit:
# `num_turns` and `usage.{input_tokens,output_tokens,cache_read_tokens,
# thinking_tokens}`. No JSON runtime is a dependency here.
_agy_stats() {
  local __f=$6 __txt __n __turns __in __out __ca __th
  [ -f "$__f" ] || return 1
  __txt=$(tr -d ' \n\r\t' < "$__f")
  case $__txt in *'"usage":{'*) ;; *) return 1 ;; esac
  __n=${__txt#*\"num_turns\":}; __turns=${__n%%[!0-9]*}
  __n=${__txt#*\"input_tokens\":}; __in=${__n%%[!0-9]*}
  __n=${__txt#*\"output_tokens\":}; __out=${__n%%[!0-9]*}
  __n=${__txt#*\"cache_read_tokens\":}; __ca=${__n%%[!0-9]*}
  __n=${__txt#*\"thinking_tokens\":}; __th=${__n%%[!0-9]*}
  eval "$1=\${__turns:-0}; $2=\${__in:-0}; $3=\${__out:-0}; $4=\${__ca:-0}; $5=\${__th:-0}"
}

# _agy_seconds VARNAME FILE — the envelope's duration_seconds, whole seconds.
_agy_seconds() {
  local __f=$2 __txt __n
  [ -f "$__f" ] || return 1
  __txt=$(tr -d ' \n\r\t' < "$__f")
  case $__txt in *'"duration_seconds":'*) ;; *) return 1 ;; esac
  __n=${__txt#*\"duration_seconds\":}; __n=${__n%%[!0-9]*}
  eval "$1=\${__n:-0}"
}

# _agy_field VARNAME FILE KEY — a top-level string field of that envelope
# (`status`, `response`, `error`). Escapes are left as printed; a quote inside
# a JSON string is always escaped, so cutting at the first `","` is safe.
_agy_field() {
  local __f=$2 __key=$3 __txt
  [ -f "$__f" ] || return 1
  __txt=$(tr -d '\n\r' < "$__f")
  case $__txt in *"\"$__key\":\""*) ;; *) return 1 ;; esac
  __txt=${__txt#*\"$__key\":\"}
  __txt=${__txt%%\",\"*}
  eval "$1=\$__txt"
}

# Runs collected today on a provider whose unit is not money (one line per
# collect: DATE PROVIDER N), and the moment a quota-billed provider last ran
# out (EPOCH PROVIDER MESSAGE) — the plan's quota is not readable headless, so
# a run that ends in a quota error is what marks it spent, for 5 hours.
REQUESTS="$HOME/.claude/sidecar-requests"
QUOTA="$HOME/.claude/sidecar-quota"
QUOTA_HOLD_S=18000
_requests_today() {
  local __v=$1 __prov=$2 __today __line __sum=0
  __today=$(date +%Y-%m-%d)
  if [ -f "$REQUESTS" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      case $__line in "$__today $__prov "*) __sum=$((__sum + ${__line##* })) ;; esac
    done < "$REQUESTS"
  fi
  eval "$__v=\$__sum"
}

# _conf VARNAME FILE KEY — read `key=value` from a profile.
_conf() {
  local __v=$1 __file=$2 __key=$3 __line __out=''
  [ -f "$__file" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case $__line in \#*|'') continue ;; esac
    case ${__line%%=*} in "$__key") __out=${__line#*=} ;; esac
  done < "$__file"
  eval "$__v=\$__out"
  [ -n "$__out" ]
}

# _json_string VALUE — VALUE with the two characters a JSON string cannot carry
# bare escaped, on stdout. Enough for a credential and a URL; not a JSON encoder.
_json_string() {
  local __s=$1
  __s=${__s//\\/\\\\}
  __s=${__s//\"/\\\"}
  printf '%s' "$__s"
}

# _credential VARNAME KEY — read a secret from the 0600 file outside the repo.
_credential() {
  local __v=$1 __key=$2 __line __out=''
  [ -f "$CREDS" ] || die "no credential file at $CREDS. Put ${__key}=... in it, mode 0600."
  while IFS= read -r __line || [ -n "$__line" ]; do
    case ${__line%%=*} in "$__key") __out=${__line#*=} ;; esac
  done < "$CREDS"
  [ -n "$__out" ] || die "$CREDS has no $__key."
  eval "$__v=\$__out"
}

# ---------------------------------------------------------------------------
# Claude Code queries
# ---------------------------------------------------------------------------

# _agents VARNAME — the whole `claude agents --json` blob, or empty.
_agents() {
  local __v=$1 __out
  __out=$(claude agents --json 2>/dev/null) || __out=''
  eval "$__v=\$__out"
}

# _session_for VARNAME NAME — the full session id of a live session called NAME.
# Scanned rather than parsed: the blob is one object per session and the name
# and id travel together, so cutting at the name and taking the sessionId on
# either side of it is enough, and a JSON runtime is not a dependency this
# project accepts.
_session_for() {
  local __v=$1 __name=$2 __blob __before __after __id=''
  _agents __blob
  case $__blob in
    *"\"name\": \"$__name\""*) ;;
    *) eval "$__v=''"; return 1 ;;
  esac
  __before=${__blob%%\"name\": \"$__name\"*}
  # sessionId sits just before the name within the same object.
  case $__before in
    *'"sessionId": "'*)
      __after=${__before##*\"sessionId\": \"}
      __id=${__after%%\"*} ;;
  esac
  eval "$__v=\$__id"
  [ -n "$__id" ]
}

# _transcript VARNAME SESSION_ID — path to that session's transcript, or empty.
_transcript() {
  local __v=$1 __sid=$2 __f
  __f=$(ls -t "$HOME/.claude/projects"/*/"$__sid.jsonl" 2>/dev/null | head -1)
  eval "$__v=\$__f"
  [ -n "$__f" ]
}

# ---------------------------------------------------------------------------
# Money
#
# Micro-USD throughout, as whole numbers, because bash has no floating point.
# ---------------------------------------------------------------------------

# Every local in this section is __-prefixed, and that is not decoration. These
# helpers return values by `eval "$1=..."`, so a local sharing a name with one
# the caller passed would be assigned instead of the caller's variable — the
# function would silently do nothing. The first test written against _usage hit
# exactly that, because the obvious call is `_usage miss cached out FILE`.

# _price_age VARNAME — days since the price table was last checked, or -1 when
# it carries no date. There is nothing to fetch prices from, so the only defence
# against a stale table is saying how old it is.
_price_age() {
  local __p __rest __d __then __now
  __d=''
  while read -r __p __rest; do
    case $__p in checked) __d=${__rest%% *} ;; esac
  done < "$SELF_DIR/prices.conf"
  case $__d in
    ????-??-??) ;;
    *) eval "$1=-1"; return 1 ;;
  esac
  # No date arithmetic in bash, and no python here: seconds since the epoch for
  # both, through the one date(1) form macOS and GNU agree on well enough.
  __then=$(date -j -f %Y-%m-%d "$__d" +%s 2>/dev/null) \
    || __then=$(date -d "$__d" +%s 2>/dev/null) || { eval "$1=-1"; return 1; }
  __now=$(date +%s)
  eval "$1=\$(( (__now - __then) / 86400 ))"
}

# _price VAR_MISS VAR_CACHED VAR_OUT PROVIDER MODEL
_price() {
  local __p __m __i __c __o __found=0
  while read -r __p __m __i __c __o; do
    case $__p in \#*|''|checked) continue ;; esac
    if [ "$__p" = "$4" ] && [ "$__m" = "$5" ]; then
      eval "$1=\$__i"; eval "$2=\$__c"; eval "$3=\$__o"; __found=1
    fi
  done < "$SELF_DIR/prices.conf"
  [ "$__found" = 1 ] || die "no price for $4/$5 in prices.conf. Add it rather than guessing."
}

# _usage VAR_MISS VAR_CACHED VAR_OUT TRANSCRIPT — sum the token counts.
#
# cache_creation_input_tokens count as missed input: DeepSeek makes no separate
# charge for a cache write, so those tokens are simply input that did not hit.
#
# ONE RESPONSE IS BILLED ONCE. A transcript records the same assistant message
# more than once — 21 usage records against 13 distinct message ids in the run
# that exposed this — so summing every `"usage":{` counted several responses
# twice and the first ledger figures were about double. Found because the number
# failed a sniff test: a one-line function does not cost 1.35 million tokens.
# Each message id is counted once; a record carrying no id is counted, since
# dropping it would understate, and understating spend is the worse direction.
_usage() {
  local __file=$4 __line __rest __id __seen=" " __n __n_resp=0 __miss=0 __cached=0 __out=0
  while IFS= read -r __line || [ -n "$__line" ]; do
    case $__line in *'"usage":{'*) ;; *) continue ;; esac
    __id=''
    case $__line in
      *'"message":{'*)
        __rest=${__line#*\"message\":\{}
        case $__rest in
          *'"id":"'*) __id=${__rest#*\"id\":\"}; __id=${__id%%\"*} ;;
        esac ;;
    esac
    if [ -n "$__id" ]; then
      case $__seen in *" $__id "*) continue ;; esac
      __seen="$__seen$__id "
    fi
    __n_resp=$((__n_resp + 1))
    __rest=${__line#*\"usage\":\{}
    _field __n "$__rest" input_tokens                && __miss=$((__miss + __n))
    _field __n "$__rest" cache_creation_input_tokens && __miss=$((__miss + __n))
    _field __n "$__rest" cache_read_input_tokens     && __cached=$((__cached + __n))
    _field __n "$__rest" output_tokens               && __out=$((__out + __n))
  done < "$__file"
  _USAGE_RESPONSES=$__n_resp
  eval "$1=\$__miss"; eval "$2=\$__cached"; eval "$3=\$__out"
}

# _field VARNAME HAYSTACK KEY — the integer after "KEY": , bounded to this object.
_field() {
  local __fv=$1 __hay=$2 __key=$3 __r __ch __o=''
  __hay=${__hay%%\}*}
  case $__hay in *"\"$__key\""*) ;; *) eval "$__fv=0"; return 1 ;; esac
  __r=${__hay#*\"$__key\"}
  __r=${__r#*:}
  while :; do case ${__r:0:1} in ' ') __r=${__r:1} ;; *) break ;; esac; done
  while :; do
    __ch=${__r:0:1}
    case $__ch in [0-9]) __o="$__o$__ch"; __r=${__r:1} ;; *) break ;; esac
  done
  case $__o in '') eval "$__fv=0"; return 1 ;; esac
  eval "$__fv=\$__o"
}

# _usd VARNAME MICRO — micro-USD as dollars and cents, without floating point.
_usd() {
  local __m=$2 __d __c
  __d=$((__m / 1000000)); __c=$(((__m % 1000000 + 5000) / 10000))
  [ "$__c" -ge 100 ] && { __d=$((__d + 1)); __c=$((__c - 100)); }
  [ "$__c" -lt 10 ] && __c="0$__c"
  eval "$1=\"\$__d.\$__c\""
}

# _to_micro VARNAME DECIMAL — "4.99" becomes 4990000.
_to_micro() {
  local __v=$1 __s=$2 __int __frac
  __int=${__s%%.*}
  case $__s in *.*) __frac=${__s#*.} ;; *) __frac='' ;; esac
  __frac="${__frac}000000"; __frac=${__frac:0:6}
  case $__int in ''|*[!0-9]*) eval "$__v=''"; return 1 ;; esac
  case $__frac in *[!0-9]*) eval "$__v=''"; return 1 ;; esac
  # 10# because a fraction like 090000 is not octal, whatever it looks like.
  eval "$__v=\$(( __int * 1000000 + 10#$__frac ))"
}

# _sample_balance PROVIDER — append one balance reading to the log.
#
# This is the only authoritative money signal available: there is no pricing
# endpoint and no usage or cost endpoint, so what was really spent can only be
# learned by watching this number fall. The log is append-only and carries the
# raw readings rather than a running total, so a wrong derivation can be redone
# from the data rather than having destroyed it.
#
# Silent when the provider has no balance endpoint, or the call fails: a missing
# sample degrades the figure to the estimate, and is not worth failing a launch
# over.
_sample_balance() {
  local __prof="$SELF_DIR/providers/$1.conf" __url __field __secret __ckey __cv __body __raw __micro
  [ -f "$__prof" ] || return 1
  _conf __url "$__prof" balance_url   || return 1
  _conf __field "$__prof" balance_field || return 1
  _conf __ckey "$__prof" cred_key || return 1
  command -v curl >/dev/null 2>&1 || return 1
  # NOT __key: _credential declares `local __key` itself, so passing that name
  # makes it assign its own local and hand back nothing. The __ convention does
  # not prevent a collision when the helper uses __ names too; only a name the
  # helper does not use does.
  _credential __secret "$__ckey" 2>/dev/null || return 1
  # One header, the one the profile says this provider wants. Sending both was
  # rejected outright — "Authentication Fails (auth header format should be
  # Bearer sk-...)" — so the balance reading silently never happened. The
  # preflight can send both because the messages endpoint accepts either; this
  # one cannot.
  local __hdr
  case $(_conf __cv "$__prof" cred_var; echo "$__cv") in
    ANTHROPIC_API_KEY) __hdr="x-api-key: $__secret" ;;
    *)                 __hdr="Authorization: Bearer $__secret" ;;
  esac
  __body=$(curl -s -m 20 "$__url" -H "$__hdr" 2>/dev/null) || return 1
  case $__body in *"\"$__field\""*) ;; *) return 1 ;; esac
  __raw=${__body#*\"$__field\"}
  __raw=${__raw#*:}
  __raw=${__raw#\"}
  __raw=${__raw%%\"*}
  __raw=${__raw%%,*}
  _to_micro __micro "$__raw" || return 1
  printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$__micro" >> "$BALANCE" 2>/dev/null
}

# _billed_mtd VARNAME — micro-USD actually billed this month, from the samples.
#
# The sum of the DROPS between consecutive readings, not first minus last. A
# top-up raises the balance, and first-minus-last would read that as the month
# costing less, or as negative spend. Counting only the falls is correct whether
# or not anyone tops up, and needs no separate baseline to keep in step.
#
# Returns 1 when there are fewer than two readings this month, because one
# reading is a number and not yet a measurement.
_billed_mtd() {
  local __month __ts __prov __bal __prev='' __total=0 __n=0 __only=${2:-}
  __month=$(date +%Y-%m)
  [ -f "$BALANCE" ] || { eval "$1=0"; return 1; }
  while read -r __ts __prov __bal; do
    case $__ts in "$__month"*) ;; *) continue ;; esac
    [ -z "$__only" ] || [ "$__prov" = "$__only" ] || continue
    case $__bal in ''|*[!0-9]*) continue ;; esac
    __n=$((__n + 1))
    if [ -n "$__prev" ] && [ "$__bal" -lt "$__prev" ]; then
      __total=$((__total + __prev - __bal))
    fi
    __prev=$__bal
  done < "$BALANCE"
  eval "$1=\$__total"
  [ "$__n" -ge 2 ]
}

# _month_to_date VARNAME [PROVIDER] — micro-USD spent this calendar month.
_month_to_date() {
  local __month __total=0 __ts __a __b __c __d __e __micro __rest __only=${2:-}
  __month=$(date +%Y-%m)
  if [ -f "$LEDGER" ]; then
    while read -r __ts __a __b __c __d __e __micro __rest; do
      case $__ts in "$__month"*) ;; *) continue ;; esac
      [ -z "$__only" ] || [ "$__a" = "$__only" ] || continue
      case $__micro in ''|*[!0-9]*) continue ;; esac
      __total=$((__total + __micro))
    done < "$LEDGER"
  fi
  eval "$1=\$__total"
}

# _anthropic_line VARNAME — the subscription's own windows, from the budget
# sensor's state file. Always shown by `spend`: the point of a sidecar is what
# it saves here.
_anthropic_line() {
  local __f="$HOME/.claude/budget-state" __l __five='' __seven='' __reset='' __t='' __out
  if [ -f "$__f" ]; then
    while IFS= read -r __l || [ -n "$__l" ]; do
      case $__l in
        FIVE_H_PCT=*) __five=${__l#*=} ;; SEVEN_D_PCT=*) __seven=${__l#*=} ;; FIVE_H_RESET=*) __reset=${__l#*=} ;;
      esac
    done < "$__f"
  fi
  if [ -z "$__five" ] && [ -z "$__seven" ]; then
    __out="Anthropic: no plan-limit reading yet (the budget sensor writes $__f once a session has answered)"
  else
    __out="Anthropic:"
    if [ -n "$__five" ]; then
      case $__reset in ''|*[!0-9]*) ;; *) __t=$(date -r "$__reset" +%H:%M 2>/dev/null || date -d "@$__reset" +%H:%M 2>/dev/null) ;; esac
      __out="$__out 5h ${__five%%.*}% used${__t:+ (resets $__t)}"
    fi
    [ -n "$__seven" ] && __out="$__out${__five:+ ·} 7d ${__seven%%.*}% used"
  fi
  eval "$1=\$__out"
}

# _latest_reading VARNAME PROVIDER — the newest balance reading for a provider
# (micro-units: micro-USD for money, minutes×10^6 for time), or 1 when none.
_latest_reading() {
  local __ts __prov __bal __last=''
  [ -f "$BALANCE" ] || return 1
  while read -r __ts __prov __bal; do
    [ "$__prov" = "$2" ] || continue
    case $__bal in ''|*[!0-9]*) continue ;; esac
    __last=$__bal
  done < "$BALANCE"
  [ -n "$__last" ] || return 1
  eval "$1=\$__last"
}

# _quota_spent_at VARNAME PROVIDER — epoch of the newest quota-out mark, or 1.
_quota_spent_at() {
  local __qts __qprov __qrest __qlast=''
  [ -f "$QUOTA" ] || return 1
  while read -r __qts __qprov __qrest; do
    [ "$__qprov" = "$2" ] || continue
    case $__qts in ''|*[!0-9]*) continue ;; esac
    __qlast=$__qts
  done < "$QUOTA"
  [ -n "$__qlast" ] || return 1
  eval "$1=\$__qlast"
}

# Callers below pass names no helper declares as a local (__spent, __left, __bill):
# _month_to_date and _latest_reading have their own __micro and __bal, and an
# eval into a colliding name assigns the helper's local, not the caller's.
# _provider_in_use PROVIDER — a worker is out on it, or it has cost something
# in the current period. Others are not shown: a line for every profile would
# bury the ones that matter.
_provider_in_use() {
  local __f __l __spent __req __today __q
  for __f in "$RUN"/*.env; do
    [ -f "$__f" ] || continue
    while IFS= read -r __l || [ -n "$__l" ]; do
      [ "$__l" = "provider=$1" ] && return 0
    done < "$__f"
  done
  _month_to_date __spent "$1"; [ "$__spent" -gt 0 ] && return 0
  _requests_today __req "$1"; [ "$__req" -gt 0 ] && return 0
  _quota_spent_at __q "$1" && [ $(( $(date +%s) - __q )) -lt "$QUOTA_HOLD_S" ] && return 0
  __today=$(date +%Y-%m-%d)
  [ -f "$BALANCE" ] && grep -q "^$__today[^ ]* $1 " "$BALANCE" 2>/dev/null && return 0
  return 1
}

# _cap_reached VARNAME PROVIDER — 0 with the reason when the provider's cap is
# reached: money (CAP_USD, the higher of the estimate and the billed figure),
# requests (daily_requests), quota (a run hit the plan's quota within the last
# 5 h), or time (a balance reading of the session's minutes at 0, taken
# fresh). `start` refuses on it; `spend` says so.
_cap_reached() {
  local __prof="$SELF_DIR/providers/$2.conf" __billing=tokens __spent __bill __usd_out __daily __req __left
  _conf __billing "$__prof" billing || __billing=tokens
  case $__billing in
    tokens)
      _month_to_date __spent "$2"
      _billed_mtd __bill "$2" && [ "$__bill" -gt "$__spent" ] && __spent=$__bill
      if [ "$__spent" -ge $((CAP_USD * 1000000)) ]; then
        _usd __usd_out "$__spent"; eval "$1=\"\\\$$__usd_out of the \\\$$CAP_USD monthly cap; it resets on the 1st\""; return 0
      fi ;;
    requests)
      _conf __daily "$__prof" daily_requests || return 1
      _requests_today __req "$2"
      if [ "$__req" -ge "$__daily" ]; then eval "$1=\"$__req of $__daily model requests today; it resets at midnight\""; return 0; fi ;;
    quota)
      _quota_spent_at __left "$2" || return 1
      if [ $(( $(date +%s) - __left )) -lt "$QUOTA_HOLD_S" ]; then
        __req=$(date -r "$__left" +%H:%M 2>/dev/null || date -d "@$__left" +%H:%M 2>/dev/null)
        eval "$1=\"the plan's quota ran out at $__req; it refreshes within 5 h\""; return 0
      fi ;;
    *)
      _conf __usd_out "$__prof" balance_url || return 1
      _sample_balance "$2" 2>/dev/null
      _latest_reading __left "$2" || return 1
      if [ "$__left" -le 0 ]; then eval "$1=\"the session's time is up (0 min left at the last reading)\""; return 0; fi ;;
  esac
  return 1
}

# _provider_line VARNAME PROVIDER — one line per kind of cost.
_provider_line() {
  local __prof="$SELF_DIR/providers/$2.conf" __billing=tokens __spent __bill __usd_out __usd_bill __daily __req __left __why __out
  _conf __billing "$__prof" billing || __billing=tokens
  case $__billing in
    tokens)
      _month_to_date __spent "$2"; _usd __usd_out "$__spent"
      __out="$2: API est \$$__usd_out"
      if _billed_mtd __bill "$2"; then _usd __usd_bill "$__bill"; __out="$__out · billed \$$__usd_bill"; fi
      __out="$__out / \$$CAP_USD this month" ;;
    requests)
      _conf __daily "$__prof" daily_requests || __daily='?'
      _requests_today __req "$2"
      __out="$2: $__req of $__daily model requests today (the plan's allowance, not money)" ;;
    quota)
      _requests_today __req "$2"
      __out="$2: $__req run(s) today on the plan's quota (refreshed every 5 h up to a weekly cap; not readable headless, the CLI refuses when it is spent)" ;;
    *)
      if _latest_reading __left "$2"; then
        __out="$2: $((__left / 1000000)) min of session time left at the last reading"
      else
        __out="$2: in use, unmetered"
      fi ;;
  esac
  _cap_reached __why "$2" && __out="$__out — CAP REACHED ($__why); start refuses"
  eval "$1=\$__out"
}

# Rewrite the status line segment. The budget sensor prints the first line of
# this file when it exists, which is how a second module reaches a status line
# that settings.json only has one slot for.
_write_extra() {
  local micro dollars tmp text billed bdollars
  _month_to_date micro
  _usd dollars "$micro"
  text="API \$$dollars/\$$CAP_USD"
  # Both figures when both exist, because they measure different things and a
  # divergence between them is the interesting signal: the estimate is a price
  # table applied to token counts, the billed figure is the provider's own
  # balance falling. Hiding either would make a disagreement invisible.
  if _billed_mtd billed; then
    _usd bdollars "$billed"
    text="API est \$$dollars · billed \$$bdollars / \$$CAP_USD"
  fi
  # Over the cap is red here; `start` is what refuses (D17).
  if [ "$micro" -gt $((CAP_USD * 1000000)) ]; then
    text="$(printf '\033[31m%s\033[0m' "$text")"
  fi
  tmp="$EXTRA.tmp.$$"
  printf '%s\n' "$text" > "$tmp" 2>/dev/null && mv -f "$tmp" "$EXTRA" 2>/dev/null || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

# _make_guard VARNAME WORKER — the pre-push refusal hook directory for a worker,
# with the repository's own hooks symlinked in beside it (core.hooksPath
# replaces the hooks directory rather than adding to it). Reached through
# GIT_CONFIG_* so it holds for any git process, whichever harness runs it.
_make_guard() {
  local __v=$1 __worker=$2 __guard="$RUN/$2.hooks" __repo_hooks __h
  mkdir -p "$__guard" || die "cannot create $__guard"
  # Absolute: `git rev-parse --git-path hooks` answers relative to the current
  # directory, and a relative symlink target would resolve against the guard
  # directory and dangle (it shipped that way once; the test did not catch it).
  __repo_hooks=$(git rev-parse --git-path hooks 2>/dev/null)
  case $__repo_hooks in /*) ;; ?*) __repo_hooks="$PWD/$__repo_hooks" ;; esac
  if [ -n "$__repo_hooks" ] && [ -d "$__repo_hooks" ]; then
    for __h in "$__repo_hooks"/*; do
      [ -f "$__h" ] || continue
      case ${__h##*/} in pre-push) continue ;; esac
      ln -sf "$__h" "$__guard/${__h##*/}" 2>/dev/null
    done
  fi
  printf '#!/bin/sh\necho "sidecar: push refused. This worker hands work back as a branch for review; the session that dispatched it merges." >&2\nexit 1\n' \
    > "$__guard/pre-push" || die "cannot write the pre-push guard"
  chmod +x "$__guard/pre-push"
  eval "$__v=\$__guard"
}

# _no_worker_out — one worker at a time, by decision (D12).
_no_worker_out() {
  local __f __existing=''
  for __f in "$RUN"/*.env; do
    [ -f "$__f" ] || continue
    __existing=${__f##*/}; __existing=${__existing%.env}
    break
  done
  [ -z "$__existing" ] || die "worker $__existing is already out. One at a time, so that each result is reviewed before the next task starts. Collect it, then: \"$SELF_DIR/sidecar.sh\" stop --worker $__existing"
}

cmd_start() {
  [ -f "$FLAG" ] || die "sidecar mode is off. Switch it on with /sidecar-on."
  [ -n "$TASK" ] || die "start needs --task TEXT."
  local profile="$SELF_DIR/providers/$PROVIDER.conf"
  [ -f "$profile" ] || die "no profile at $profile."
  local why
  _cap_reached why "$PROVIDER" && die "$PROVIDER has reached its cap: $why. Nothing launched. Use another provider, or raise the cap in $CONFIG (CAP_USD) or the profile (daily_requests)."
  # --model is a per-run choice among the slugs the profile lists (D19); a Claude
  # Code worker never gets one (it checks model names against its own catalogue).
  if [ -n "$MODEL" ]; then
    local models=''
    _conf models "$profile" models || die "$PROVIDER takes no --model: its profile lists no models=."
    case ",$models," in *",$MODEL,"*) ;; *) die "$PROVIDER does not offer model $MODEL. Its profile lists: ${models//,/ }" ;; esac
  fi
  local harness=claude
  _conf harness "$profile" harness || harness=claude
  case $harness in
    claude) ;;
    antigravity-cli) _start_agy "$profile"; return ;;
    *) die "$profile: harness=$harness is not one this sidecar can launch (claude, antigravity-cli)." ;;
  esac

  local base cred_var cred_key model alias key
  _conf base      "$profile" base_url    || die "$profile has no base_url."
  _conf cred_var  "$profile" cred_var    || die "$profile has no cred_var."
  _conf cred_key  "$profile" cred_key    || die "$profile has no cred_key."
  _conf model     "$profile" model       || die "$profile has no model."
  _conf alias     "$profile" model_alias || die "$profile has no model_alias."
  # Before anything is spent, because it is about configuration rather than the
  # run, and because the orchestrator can act on it here: nothing can fetch
  # prices — the provider's /models carries none and every billing endpoint
  # probed returns 404 — so an unrevisited table is the one input that goes
  # wrong silently. Said at spawn, it can be fixed before the run it would
  # mis-price.
  local age
  if _price_age age && [ "$age" -gt 30 ]; then
    echo "sidecar: prices.conf was last checked $age days ago, so every cost figure will be suspect." >&2
    echo "         There is no pricing endpoint to fetch from, so this table is maintained by hand." >&2
    echo "         Update $SELF_DIR/prices.conf against the provider's published rates and set its" >&2
    echo "         \`checked\` date before relying on a figure from this run." >&2
  fi

  _credential key "$cred_key"
  # An empty credential is the one failure that costs real money in the wrong
  # place. Claude Code treats it as no credential at all and falls back to the
  # saved claude.ai login, so the worker runs on the subscription — spending the
  # rate-limit windows this module exists to protect, while the ledger records
  # it as the provider's cheap tokens. It happened: a returned-by-eval helper
  # shadowed its own output variable and shipped an empty string in silence.
  [ -n "$key" ] || die "the credential for $cred_key came back empty. Refusing to launch: an empty credential silently runs the worker on your claude.ai subscription instead of $PROVIDER."

  _no_worker_out

  git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repository. The worker hands work back as a branch."

  # PREFLIGHT. This is the guard the whole module rests on, and it exists
  # because of a measurement: a background worker launched with a deliberately
  # wrong key logged three 401s from the provider and then completed the task
  # anyway, on the claude.ai subscription. A background session does not stop at
  # a rejected credential — Claude Code retries and falls back to the saved
  # login. So a sidecar that merely *sets* the variables can quietly spend the
  # exact thing it was built to protect, and report it as pennies.
  #
  # One tiny request settles it before any work starts. It costs a handful of
  # tokens on the provider and turns "probably delegated" into "delegated".
  command -v curl >/dev/null 2>&1 \
    || die "curl is needed to check the credential before launching, and a launch that cannot be checked is the failure this guard exists to prevent."
  local code
  code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' "$base/v1/messages" \
           -H "x-api-key: $key" -H "Authorization: Bearer $key" \
           -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
           -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null)
  case $code in
    200) ;;
    401|403) die "$PROVIDER rejected the credential in $cred_key (HTTP $code). Refusing to launch: a worker whose credential is rejected does not fail, it finishes the work on your claude.ai subscription." ;;
    000|'') die "could not reach $base to check the credential. Refusing to launch rather than risk the work landing on your subscription." ;;
    *) die "$base answered HTTP $code to a one-token probe. Refusing to launch until that is understood." ;;
  esac

  # A reading before the work starts, so this run has a "before" to difference
  # against the one collect takes afterwards.
  _sample_balance "$PROVIDER" 2>/dev/null

  local worker="sidecar-$(date +%H%M%S)"
  mkdir -p "$RUN" || die "cannot create $RUN"

  # The credential goes in through the environment of this one command and
  # nowhere else: never a file in the repository, never the command line, where
  # it would sit in `ps` for anyone on the machine to read.
  # The worker hands work back as a branch for the orchestrator to review and
  # merge. It does not publish it. Both halves of that are here because an
  # instruction alone was not enough: workers told "Commit it. Nothing else."
  # attempted `git push` four times each, and only the absence of a remote in
  # the test repositories made that harmless. A worker inherits the
  # orchestrator's permissions, so in a real repository it would have succeeded
  # — pushing unreviewed work straight past the review this module is built
  # around, and doing it unattended.
  #
  # --disallowed-tools takes permission-rule syntax and is additive, so it
  # denies the push without overriding whatever permissions the user already
  # has. The brief says the same thing in words, because a worker that knows the
  # shape of the hand-off writes a better branch than one that keeps hitting a
  # wall it does not understand.
  # The brief goes in the system prompt, not in front of the task. Prepending it
  # made the prompt multi-line and the session then started with an EMPTY prompt
  # and sat idle: two workers in a row did nothing at all and looked merely
  # "blocked", which cost two live tests that were read as inconclusive before
  # the cause was found. It is also the right place for it — this is a standing
  # instruction about how work is handed back, not part of any one task.
  # Appended, never a replacement. The default system prompt is ~31,000
  # characters and most of it is harness knowledge — how the tools behave, how
  # permissions work, how files are handled — which is the whole reason for
  # running the worker inside Claude Code rather than writing an agent loop. It
  # is also a stable prefix, so it sits in the provider's automatic cache and
  # bills at a fraction after the first call.
  #
  # What that prompt gets wrong for a worker is narrow and worth correcting: it
  # describes a Claude model, so the worker believes it is one. Asked directly,
  # a DeepSeek worker answered "Model ID: claude-sonnet-5" in good faith, and it
  # signs commits with Claude attribution. Both are corrected here rather than by
  # discarding 31,000 characters of things that are true.
  local brief="You are running on $PROVIDER's $model, reached through an Anthropic-compatible endpoint. Your harness is Claude Code and everything it tells you about tools, permissions and files is accurate, but anything in it that identifies you as a Claude model is not: you are $model. Do not describe yourself as a Claude model, and do not put Claude co-authorship or attribution in commit messages.

Your work will be reviewed as a branch by the session that dispatched you, so commit it and stop there. Do not push, and do not merge into any other branch. If you cannot finish, commit what you have and say what is left."
  # Per-provider conduct, after the brief: what this particular model needs to
  # be told (how to pace itself, what it gets wrong). Optional — a provider with
  # no rules.md gets the brief alone.
  local worker_rules
  if _rules_section worker_rules "$SELF_DIR/providers/$PROVIDER.rules.md" Worker; then
    brief="$brief

Rules of engagement for $model on $PROVIDER:
$worker_rules"
  fi
  # A refusing pre-push hook, reached through the environment rather than the
  # repository's configuration, so nothing in the user's repo is modified.
  #
  # This is the guard that actually holds. A permission rule does not: the
  # permissions reference names `Bash(git push *)` as its own example of a rule's
  # limits, listing `git -C . push`, `git -c … push` and `git 'push'` as things
  # it misses, and a worker did push past the rule to a real remote. Measured
  # against the same five forms, the hook refused every one and the remote stayed
  # empty, because GIT_CONFIG_* is inherited by any git process however it is
  # spelled.
  #
  # The repository's own hooks are symlinked in beside it, since core.hooksPath
  # replaces the hooks directory rather than adding to it — without this, a
  # repo's pre-commit lint would silently stop running inside the worker.
  local guard
  _make_guard guard "$worker"

  # The endpoint pair travels twice: in the environment, and in a settings file
  # passed with --settings. A background session does not always take
  # ANTHROPIC_BASE_URL and the credential from its environment — measured
  # 2026-09-13: launched from a shell inside another --bg session, with and
  # without an inherited environment, the worker answered on the claude.ai login
  # and the endpoint saw no request, while `claude -p` with the same variables
  # reached it. The settings `env` block was honoured in every case measured
  # (D14). A file rather than a JSON literal on the command line, so the
  # credential still never appears in `ps`; 0600, beside the worker's records,
  # removed by `stop`.
  local settings="$RUN/$worker.settings.json"
  ( umask 077 && printf '{"env":{"%s":"%s","ANTHROPIC_BASE_URL":"%s"}}\n' \
      "$cred_var" "$(_json_string "$key")" "$(_json_string "$base")" > "$settings" ) \
    || die "cannot write $settings"

  local out
  out=$(env "$cred_var=$key" ANTHROPIC_BASE_URL="$base" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$guard" \
        claude --bg --name "$worker" --model "$alias" \
               --settings "$settings" \
               --permission-mode "$PERMISSION_MODE" \
               --disallowed-tools "Bash(git push *)" \
               --append-system-prompt "$brief" \
               "$TASK" < /dev/null 2>&1) \
    || die "claude refused to start the worker: $out"

  local sid=''
  _session_for sid "$worker" || sid=''

  {
    echo "worker=$worker"
    echo "provider=$PROVIDER"
    echo "model=$model"
    echo "session=$sid"
    echo "repo=$PWD"
    echo "started=$(date +%s)"
  } > "$RUN/$worker.env"

  # The session id comes from `claude agents --json`, not from the line
  # `claude --bg` prints. That line carries ANSI colour around the id — parsing
  # it yielded a "short id" of ESC[36m8da5db3dESC[39m — and the JSON has no
  # colour in it. attach, logs and stop all take the full id.
  echo "worker $worker · $PROVIDER/$model · $PWD"
  if [ -n "$sid" ]; then
    echo "  watch:   claude attach ${sid%%-*}"
  else
    echo "  watch:   claude agents        (it is not listed yet)"
  fi
  echo "  collect: \"$SELF_DIR/sidecar.sh\" collect --worker $worker"
}

# The Antigravity CLI as the worker (D18, superseding D16's Gemini CLI: Google
# stopped serving personal accounts there on 2026-06-18). `agy` runs the task
# headless in a worktree of its own and exits; there is no session to attach
# to, no peer messaging, and no credential of ours — the login is the user's
# Google account, kept by the CLI itself. Google forbids using that login from
# any other software, so the official CLI it is.
AGY_TOKEN="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
_start_agy() {
  local profile=$1 model='' timeout=''
  _conf model "$profile" model || model=auto
  [ -n "$MODEL" ] && model=$MODEL
  _conf timeout "$profile" print_timeout || timeout=2h
  command -v agy >/dev/null 2>&1 || die "agy is not installed: curl -fsSL https://antigravity.google/cli/install.sh | bash, then run \`agy\` once to sign in."
  [ -f "$AGY_TOKEN" ] || die "not signed in to Antigravity CLI: $AGY_TOKEN is missing. Run \`agy\` once and sign in with Google; the worker cannot sign in for you."
  # The plan's quota is free; purchased AI credits are money. The CLI spends
  # them only when `useG1Credits` is switched on (opt-in; the CLI rewrites its
  # settings file on every start and drops the default, so an absent key is
  # off). Nothing launches while it is on.
  if [ -f "$AGY_SETTINGS" ] && tr -d ' \n\r\t' < "$AGY_SETTINGS" | grep -q '"useG1Credits":true'; then
    die "$AGY_SETTINGS has useG1Credits=true: the CLI would spend purchased AI credits (money) once the plan's quota is gone. Switch it off first."
  fi
  _no_worker_out
  git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repository. The worker hands work back as a branch."
  local repo worker wt
  repo=$(git rev-parse --show-toplevel)
  worker="sidecar-$(date +%H%M%S)"
  # The branch is named after the worker, so a second start within the same
  # second (or a branch left from an earlier run) must not reuse the name.
  local base=$worker n=1
  while git show-ref --verify --quiet "refs/heads/$worker"; do
    worker="$base-$n"; n=$((n + 1))
  done
  # The CLI does not make a worktree for a headless run, so this does — under
  # the same path Claude Code uses for its background sessions, so `collect`
  # finds both kinds the same way.
  wt="$repo/.claude/worktrees/$worker"
  mkdir -p "$repo/.claude/worktrees" || die "cannot create $repo/.claude/worktrees"
  git worktree add -q -b "$worker" "$wt" >/dev/null 2>&1 || die "git worktree add failed for $wt (is the branch name $worker free?)"
  local guard
  _make_guard guard "$worker"
  # The brief rides at the top of the prompt. A standing-instruction file
  # (GEMINI.md / AGENTS.md) written into the worktree would show up in the diff
  # and clobber a repository's own; the prompt does not.
  # The worktree's absolute path is spelled out: the first live run searched the
  # whole home directory for a file that was two levels below its own cwd.
  local brief="You are running the official Antigravity CLI headless inside a git worktree at $wt (your working directory, on the branch $worker). Every file the task names is inside that directory; do not search or edit outside it. Your work will be reviewed as a branch by the session that dispatched you, so commit it on this branch and stop there. Do not push, do not merge into any other branch, do not switch branches. If you cannot finish, commit what you have and say what is left. Your final answer is the report the reviewer reads: what changed, what you ran and its result, what is left."
  local worker_rules
  if _rules_section worker_rules "$SELF_DIR/providers/$PROVIDER.rules.md" Worker; then
    brief="$brief

Rules of engagement for $model on $PROVIDER:
$worker_rules"
  fi
  local prompt="$brief

TASK:
$TASK"
  local -a margs=()
  [ "$model" != auto ] && margs=(--model "$model")
  # --dangerously-skip-permissions: nobody is there to approve tools (the
  # CLI auto-denies what it cannot ask about). --print-timeout: the CLI's
  # default is 5 minutes, which no coding task fits. The exit code lands in
  # .rc for status; stdout is the one JSON envelope the CLI prints when done.
  # The wrapper's own descriptors are detached too: a background subshell that
  # inherits the caller's stdout keeps a `$(sidecar.sh start …)` waiting until
  # the worker finishes (measured: 30 s for a 30 s stub), and an orchestrator
  # launching from a tool call would have hung with it.
  (
    cd "$wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$guard" \
      agy -p "$prompt" --output-format json --dangerously-skip-permissions --print-timeout "$timeout" ${margs[@]+"${margs[@]}"} \
        < /dev/null > "$RUN/$worker.out" 2> "$RUN/$worker.err"
    echo $? > "$RUN/$worker.rc"
  ) < /dev/null > /dev/null 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null
  {
    echo "worker=$worker"
    echo "provider=$PROVIDER"
    echo "model=$model"
    echo "harness=antigravity-cli"
    echo "pid=$pid"
    echo "worktree=$wt"
    echo "repo=$repo"
    echo "started=$(date +%s)"
  } > "$RUN/$worker.env"
  echo "worker $worker · $PROVIDER/$model (Antigravity CLI, headless) · $wt"
  echo "  budget:  the plan's quota (refreshed every 5 h up to a weekly cap, not readable headless); a run that hits it marks $PROVIDER spent for 5 h"
  echo "  watch:   tail -f \"$RUN/$worker.err\"   (the JSON result arrives in $RUN/$worker.out when it exits)"
  echo "  collect: \"$SELF_DIR/sidecar.sh\" collect --worker $worker"
}

cmd_status() {
  local f found=0 blob
  _agents blob
  for f in "$RUN"/*.env; do
    [ -f "$f" ] || continue
    found=1
    local worker='' provider='' model='' repo='' pid='' line state=gone
    while IFS= read -r line || [ -n "$line" ]; do
      case ${line%%=*} in
        worker) worker=${line#*=} ;; provider) provider=${line#*=} ;;
        model) model=${line#*=} ;; repo) repo=${line#*=} ;; pid) pid=${line#*=} ;;
      esac
    done < "$f"
    if [ -n "$pid" ]; then
      if kill -0 "$pid" 2>/dev/null; then state=live
      elif [ -f "$RUN/$worker.rc" ]; then state="exited($(cat "$RUN/$worker.rc"))"
      fi
    else
      case $blob in *"\"name\": \"$worker\""*) state=live ;; esac
    fi
    echo "$state  $worker  $provider/$model  $repo"
  done
  [ "$found" = 1 ] || echo "No workers."
  cmd_spend
}

cmd_collect() {
  [ -n "$WORKER" ] || die "collect needs --worker NAME."
  local f="$RUN/$WORKER.env"
  [ -f "$f" ] || die "no worker called $WORKER. Try: sidecar.sh status"
  local provider='' model='' session='' repo='' harness=claude worktree='' pid='' line
  while IFS= read -r line || [ -n "$line" ]; do
    case ${line%%=*} in
      provider) provider=${line#*=} ;; model) model=${line#*=} ;;
      session) session=${line#*=} ;; repo) repo=${line#*=} ;;
      harness) harness=${line#*=} ;; worktree) worktree=${line#*=} ;; pid) pid=${line#*=} ;;
    esac
  done < "$f"

  # The session id is resolved late when the launch could not get it: a worker
  # that has only just started may not be listed yet.
  if [ -z "$session" ]; then
    _session_for session "$WORKER" && {
      printf 'session=%s\n' "$session" >> "$f"
    }
  fi

  echo "== what the worker changed =="
  local wt found=0
  while read -r wt _; do
    case $wt in *"/.claude/worktrees/"*) ;; *) continue ;; esac
    found=1
    echo "worktree: $wt"
    git -C "$wt" --no-pager log --oneline -5 2>/dev/null
    git -C "$wt" --no-pager diff --stat HEAD~1 2>/dev/null || \
      git -C "$wt" --no-pager status --short 2>/dev/null
  done < <(git -C "$repo" worktree list 2>/dev/null)
  [ "$found" = 1 ] || echo "(no worktree yet — the worker may still be starting)"

  echo
  if [ "$harness" = antigravity-cli ]; then
    _collect_agy "$provider" "$model" "$pid"
    return
  fi
  # And one after, which is what makes a difference computable at all.
  _sample_balance "$provider" 2>/dev/null

  echo "== what it cost =="
  if [ -z "$session" ]; then
    echo "no session id yet, so nothing was priced."
    return 0
  fi
  local tr
  if ! _transcript tr "$session"; then
    echo "no transcript for $session yet, so nothing was priced."
    return 0
  fi
  # Did the provider actually serve this? A background session that gets a 401
  # from the provider does not stop: Claude Code retries and then falls back to
  # the saved claude.ai login, finishing the work on the subscription. Measured
  # — a worker launched with a deliberately wrong key logged three 401s and then
  # completed the task anyway. Pricing that as the provider's cheap tokens would
  # be a ledger that lies in the most expensive direction, so it is refused.
  #
  # start's preflight is the real guard; this catches a credential that stopped
  # working part-way through a run, which the preflight cannot see.
  if grep -q '"error":"authentication_error"\|"status":401\|401 ' "$tr" 2>/dev/null; then
    echo "WARNING: this run hit an authentication error against $provider."
    echo "         A background worker does not stop on a 401 — Claude Code"
    echo "         falls back to your claude.ai login and finishes the work on"
    echo "         the subscription, spending the windows this module exists to"
    echo "         protect. Nothing was added to the ledger, because it cannot"
    echo "         be priced as $provider honestly."
    return 1
  fi

  # A provider that charges nothing per token — one you host yourself — has no
  # price row and must not be treated as an error. Without this, `collect` died
  # on `no price for …` and the work could not be reported at all, which made
  # the module unusable with a self-hosted endpoint despite everything else
  # about it being provider-agnostic.
  local billing=tokens
  _conf billing "$SELF_DIR/providers/$provider.conf" billing || billing=tokens
  local miss cached out pm pc po micro dollars
  _usage miss cached out "$tr"
  if [ "$billing" != tokens ]; then
    echo "$provider/$model · ${_USAGE_RESPONSES:-?} responses · no per-token cost ($provider bills as '$billing')"
    echo "  Tokens are still counted: in $miss (+$cached cached), out $out."
    return 0
  fi
  _price pm pc po "$provider" "$model"
  micro=$(( miss * pm / 1000000 + cached * pc / 1000000 + out * po / 1000000 ))
  _usd dollars "$micro"
  # Cost, not a token count. Every request re-sends the whole conversation, so
  # cache_read is that request's cumulative prefix rather than new tokens:
  # summing it across a run is right for cost — those tokens really are billed,
  # at the cache-hit rate — and badly misleading as a total, because the
  # provider's own dashboard counts unique tokens processed. One run read
  # 700,345 summed cached tokens while DeepSeek reported 55,939 for it, and the
  # two figures are both correct about different things. Printing the summed
  # total invited exactly that comparison, so it is not printed.
  echo "$provider/$model · ${_USAGE_RESPONSES:-?} responses · ≈\$$dollars"
  echo "  (cost, not a token count: cache reads are billed per request at the"
  echo "   hit rate, so the provider's dashboard token figure will differ)"

  # Append-only, one line per collect. A spend record that gets rewritten is not
  # a record. Collecting the same worker twice would double-count, so each
  # collect replaces nothing and the marker below makes the repeat visible.
  if [ -f "$RUN/$WORKER.collected" ]; then
    echo "(already collected once — not added to the ledger again)"
  else
    printf '%s %s %s %s %s %s %s %s\n' \
      "$(date +%Y-%m-%dT%H:%M:%S)" "$provider" "$model" \
      "$miss" "$cached" "$out" "$micro" "$session" >> "$LEDGER"
    : > "$RUN/$WORKER.collected"
    _write_extra
  fi
}

# What an Antigravity CLI worker cost: turns and tokens from the envelope the
# CLI printed on exit. Nothing is priced in money — the plan's quota is the
# unit, and a run that ends in a quota error marks the provider spent (QUOTA).
_collect_agy() {
  local provider=$1 model=$2 pid=$3 out="$RUN/$WORKER.out" turns inn outt ca th st='' err='' resp='' today
  echo "== what it cost =="
  if kill -0 "$pid" 2>/dev/null; then
    echo "still running (pid $pid); the CLI prints its result and usage when it exits."
    return 0
  fi
  if ! _agy_stats turns inn outt ca th "$out"; then
    echo "no usage yet: $out holds no JSON result. Exit code: $(cat "$RUN/$WORKER.rc" 2>/dev/null || echo unknown); stderr tail:"
    tail -n 5 "$RUN/$WORKER.err" 2>/dev/null | sed 's/^/  /'
    return 1
  fi
  _agy_field st "$out" status || st='?'
  local secs=0 rate=''
  _agy_seconds secs "$out" || secs=0
  # output tokens over the whole run (tool time included): what the rate feels like from outside
  [ "$secs" -gt 0 ] && rate=", ~$(( (outt + th) / secs )) output tok/s over the run"
  echo "$provider/$model · $turns turn(s), status $st, ${secs}s · no per-token cost ($provider bills as the plan's quota)"
  echo "  Tokens are still counted: in $inn (+$ca cached), out $outt (+$th thinking)$rate."
  if [ "$st" != SUCCESS ]; then
    _agy_field err "$out" error || err=''
    echo "== the CLI reported an error =="
    printf '%s\n' "${err:-(no message)}"
  fi
  if _agy_field resp "$out" response && [ -n "$resp" ]; then
    echo "== what it said =="
    resp=${resp//\\\"/\"}
    printf '%b\n' "${resp:0:1200}"     # %b: the envelope's \n and \t come out as line breaks and tabs
  fi
  if [ -f "$RUN/$WORKER.collected" ]; then
    echo "(already collected once — not counted again)"
  else
    printf '%s %s 1\n' "$(date +%Y-%m-%d)" "$provider" >> "$REQUESTS"
    case $(printf '%s' "$err" | tr '[:upper:]' '[:lower:]') in
      *quota*|*rate*limit*|*resource_exhausted*|*credits*|*"too many requests"*)
        printf '%s %s %s\n' "$(date +%s)" "$provider" "$(printf '%s' "$err" | tr -d '\n' | cut -c1-120)" >> "$QUOTA"
        echo "QUOTA SPENT: $provider is marked spent for 5 hours; start refuses until then." ;;
    esac
    : > "$RUN/$WORKER.collected"
  fi
  _requests_today today "$provider"
  echo "today: $today run(s) on $provider"
  return 0
}

cmd_stop() {
  [ -n "$WORKER" ] || die "stop needs --worker NAME."
  local f="$RUN/$WORKER.env"
  [ -f "$f" ] || die "no worker called $WORKER."
  local session='' pid='' line
  while IFS= read -r line || [ -n "$line" ]; do
    case ${line%%=*} in session) session=${line#*=} ;; pid) pid=${line#*=} ;; esac
  done < "$f"
  [ -n "$session" ] && claude stop "${session%%-*}" 2>&1 | head -1
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null   # the agy process under the launching subshell
    kill "$pid" 2>/dev/null
    echo "killed pid $pid"
  fi
  rm -f "$RUN/$WORKER.out" "$RUN/$WORKER.err" "$RUN/$WORKER.rc"
  # The guard directory holds only our pre-push and symlinks to the repo's own
  # hooks, so removing it takes nothing of the user's with it.
  rm -f "$RUN/$WORKER.hooks"/* 2>/dev/null
  rmdir "$RUN/$WORKER.hooks" 2>/dev/null
  rm -f "$f" "$RUN/$WORKER.collected" "$RUN/$WORKER.settings.json"
  echo "stopped $WORKER"
}

cmd_spend() {
  local line prof pname any_tokens=0 billing
  _anthropic_line line
  echo "$line"
  for prof in "$SELF_DIR"/providers/*.conf; do
    [ -f "$prof" ] || continue
    pname=${prof##*/}; pname=${pname%.conf}
    _provider_in_use "$pname" || continue
    # A reading first, so `spend` keeps the balance log fed.
    _sample_balance "$pname" 2>/dev/null
    _provider_line line "$pname"
    echo "$line"
    _conf billing "$prof" billing || billing=tokens
    [ "$billing" = tokens ] && any_tokens=1
  done
  if [ "$any_tokens" = 1 ]; then
    echo "  API est prices token counts against a table maintained by hand; billed is the"
    echo "  provider's own balance falling (needs two readings this month). A gap between"
    echo "  them is information, not a bug."
  fi
}

# The orchestrator's side of a provider's rules of engagement, on demand. The
# sidecar-mode hook injects the same section into every prompt while the mode
# is on; this is for reading it in full, or another provider's.
cmd_rules() {
  local profile="$SELF_DIR/providers/$PROVIDER.conf" model='' rules
  [ -f "$profile" ] || die "no profile at $profile."
  _conf model "$profile" model || model='?'
  echo "$PROVIDER ($model) — rules of engagement for the session that dispatches work to it:"
  if _rules_section rules "$SELF_DIR/providers/$PROVIDER.rules.md" Orchestrator; then
    printf '%s\n' "$rules"
  else
    echo "  none written. Add a \`## Orchestrator\` section to $SELF_DIR/providers/$PROVIDER.rules.md."
  fi
}

# /sidecar-on NAME and /sidecar-off call these rather than touching the flag
# themselves: the provider is checked against its profile before it is
# recorded, and the command files carry no shell redirect (a redirect target is
# permission-checked as a file write; a script call is a plain Bash rule).
cmd_on() {
  local profile="$SELF_DIR/providers/$PROVIDER.conf"
  [ -f "$profile" ] || die "no profile at $profile — sidecar mode left as it was."
  printf '%s\n' "$PROVIDER" > "$FLAG" || die "cannot write $FLAG"
  echo "sidecar mode on: provider $PROVIDER (recorded in $FLAG)"
}

cmd_off() {
  rm -f "$FLAG"
  echo "sidecar mode off"
}

# ---------------------------------------------------------------------------

TASK=''; WORKER=''; PROVIDER=''; MODEL=''; PERMISSION_MODE=auto
CMD=${1:-}; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case $1 in
    --task) TASK=${2:-}; shift 2 ;;
    --worker) WORKER=${2:-}; shift 2 ;;
    --provider) PROVIDER=${2:-}; shift 2 ;;
    --model) MODEL=${2:-}; shift 2 ;;
    --permission-mode) PERMISSION_MODE=${2:-}; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
# The provider: --provider, else the name /sidecar-on wrote into the flag file
# (`/sidecar-on kaggle-tpu`), else deepseek as before. Only a plain name is
# taken from the file, since it becomes a path under providers/.
if [ -z "$PROVIDER" ]; then
  if [ -f "$FLAG" ]; then
    IFS= read -r PROVIDER < "$FLAG" || true
    PROVIDER=${PROVIDER// /}
    case $PROVIDER in *[!A-Za-z0-9_-]*) PROVIDER='' ;; esac
  fi
  PROVIDER=${PROVIDER:-deepseek}
fi

case $CMD in
  start)   cmd_start ;;
  status)  cmd_status ;;
  collect) cmd_collect ;;
  stop)    cmd_stop ;;
  spend)   cmd_spend ;;
  rules)   cmd_rules ;;
  on)      cmd_on ;;
  off)     cmd_off ;;
  *) cat >&2 <<USAGE
sidecar.sh start  --task TEXT [--provider NAME] [--model SLUG] [--permission-mode MODE]
sidecar.sh status
sidecar.sh collect --worker NAME
sidecar.sh stop    --worker NAME
sidecar.sh spend
sidecar.sh rules   [--provider NAME]   the provider's rules of engagement for the dispatching session
sidecar.sh on      [--provider NAME]   what /sidecar-on runs: record the provider and switch the mode on
sidecar.sh off

--provider defaults to the name /sidecar-on was given (the flag file), else deepseek.
--model picks one of the slugs the profile's models= lists, for this run only.

--permission-mode defaults to auto, to match an orchestrator running in auto.
It is deliberately not narrowed: acceptEdits lets a worker write a file and then
stalls it on the commit with nobody there to answer.
USAGE
     exit 2 ;;
esac
