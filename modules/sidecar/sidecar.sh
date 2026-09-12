#!/bin/bash
# Delegate coding work to a model on another provider, inside Claude Code.
#
#   sidecar.sh start  --task TEXT [--provider NAME] [--permission-mode MODE]
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
EXTRA="$HOME/.claude/statusline-extra"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_USD=80

die() { echo "sidecar: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Every local here is __-prefixed for the reason spelled out above _price: these
# return by `eval "$1=..."`, so a local sharing a name with the variable the
# caller asked for gets assigned instead, and the caller silently receives
# nothing. _credential had exactly that — called as `_credential key KEY` while
# declaring `local key=$2` — and it shipped an empty credential without a word.

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

# _price VAR_MISS VAR_CACHED VAR_OUT PROVIDER MODEL
_price() {
  local __p __m __i __c __o __found=0
  while read -r __p __m __i __c __o; do
    case $__p in \#*|'') continue ;; esac
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

# _month_to_date VARNAME — micro-USD spent this calendar month.
_month_to_date() {
  local __month __total=0 __ts __a __b __c __d __e __micro __rest
  __month=$(date +%Y-%m)
  if [ -f "$LEDGER" ]; then
    while read -r __ts __a __b __c __d __e __micro __rest; do
      case $__ts in "$__month"*) ;; *) continue ;; esac
      case $__micro in ''|*[!0-9]*) continue ;; esac
      __total=$((__total + __micro))
    done < "$LEDGER"
  fi
  eval "$1=\$__total"
}

# Rewrite the status line segment. The budget sensor prints the first line of
# this file when it exists, which is how a second module reaches a status line
# that settings.json only has one slot for.
_write_extra() {
  local micro dollars tmp text
  _month_to_date micro
  _usd dollars "$micro"
  text="API \$$dollars/\$$CAP_USD"
  # Over the cap is a colour change and nothing else. The cap is advisory by
  # decision: it says the month has cost more than intended, it does not decide
  # that the work should stop.
  if [ "$micro" -gt $((CAP_USD * 1000000)) ]; then
    text="$(printf '\033[31m%s\033[0m' "$text")"
  fi
  tmp="$EXTRA.tmp.$$"
  printf '%s\n' "$text" > "$tmp" 2>/dev/null && mv -f "$tmp" "$EXTRA" 2>/dev/null || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_start() {
  [ -f "$FLAG" ] || die "sidecar mode is off. Switch it on with /sidecar-on."
  [ -n "$TASK" ] || die "start needs --task TEXT."
  local profile="$SELF_DIR/providers/$PROVIDER.conf"
  [ -f "$profile" ] || die "no profile at $profile."

  local base cred_var cred_key model alias key
  _conf base      "$profile" base_url    || die "$profile has no base_url."
  _conf cred_var  "$profile" cred_var    || die "$profile has no cred_var."
  _conf cred_key  "$profile" cred_key    || die "$profile has no cred_key."
  _conf model     "$profile" model       || die "$profile has no model."
  _conf alias     "$profile" model_alias || die "$profile has no model_alias."
  _credential key "$cred_key"
  # An empty credential is the one failure that costs real money in the wrong
  # place. Claude Code treats it as no credential at all and falls back to the
  # saved claude.ai login, so the worker runs on the subscription — spending the
  # rate-limit windows this module exists to protect, while the ledger records
  # it as the provider's cheap tokens. It happened: a returned-by-eval helper
  # shadowed its own output variable and shipped an empty string in silence.
  [ -n "$key" ] || die "the credential for $cred_key came back empty. Refusing to launch: an empty credential silently runs the worker on your claude.ai subscription instead of $PROVIDER."

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
  local brief="Your work will be reviewed as a branch by the session that sent you this task, so commit it and stop there. Do not push, and do not merge into any other branch. If you cannot finish, commit what you have and say what is left.

"
  local out
  out=$(env "$cred_var=$key" ANTHROPIC_BASE_URL="$base" \
        claude --bg --name "$worker" --model "$alias" \
               --permission-mode "$PERMISSION_MODE" \
               --disallowed-tools "Bash(git push *)" \
               "$brief$TASK" < /dev/null 2>&1) \
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

cmd_status() {
  local f found=0 blob
  _agents blob
  for f in "$RUN"/*.env; do
    [ -f "$f" ] || continue
    found=1
    local worker='' provider='' model='' repo='' line state=gone
    while IFS= read -r line || [ -n "$line" ]; do
      case ${line%%=*} in
        worker) worker=${line#*=} ;; provider) provider=${line#*=} ;;
        model) model=${line#*=} ;; repo) repo=${line#*=} ;;
      esac
    done < "$f"
    case $blob in *"\"name\": \"$worker\""*) state=live ;; esac
    echo "$state  $worker  $provider/$model  $repo"
  done
  [ "$found" = 1 ] || echo "No workers."
  cmd_spend
}

cmd_collect() {
  [ -n "$WORKER" ] || die "collect needs --worker NAME."
  local f="$RUN/$WORKER.env"
  [ -f "$f" ] || die "no worker called $WORKER. Try: sidecar.sh status"
  local provider='' model='' session='' repo='' line
  while IFS= read -r line || [ -n "$line" ]; do
    case ${line%%=*} in
      provider) provider=${line#*=} ;; model) model=${line#*=} ;;
      session) session=${line#*=} ;; repo) repo=${line#*=} ;;
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

  local miss cached out pm pc po micro dollars
  _usage miss cached out "$tr"
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

cmd_stop() {
  [ -n "$WORKER" ] || die "stop needs --worker NAME."
  local f="$RUN/$WORKER.env"
  [ -f "$f" ] || die "no worker called $WORKER."
  local session='' line
  while IFS= read -r line || [ -n "$line" ]; do
    case ${line%%=*} in session) session=${line#*=} ;; esac
  done < "$f"
  [ -n "$session" ] && claude stop "${session%%-*}" 2>&1 | head -1
  rm -f "$f" "$RUN/$WORKER.collected"
  echo "stopped $WORKER"
}

cmd_spend() {
  local micro dollars
  _month_to_date micro
  _usd dollars "$micro"
  if [ "$micro" -gt $((CAP_USD * 1000000)) ]; then
    echo "spend this month: \$$dollars of \$$CAP_USD — over the cap (advisory; nothing is stopped)"
  else
    echo "spend this month: \$$dollars of \$$CAP_USD"
  fi
}

# ---------------------------------------------------------------------------

TASK=''; WORKER=''; PROVIDER=deepseek; PERMISSION_MODE=auto
CMD=${1:-}; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case $1 in
    --task) TASK=${2:-}; shift 2 ;;
    --worker) WORKER=${2:-}; shift 2 ;;
    --provider) PROVIDER=${2:-}; shift 2 ;;
    --permission-mode) PERMISSION_MODE=${2:-}; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

case $CMD in
  start)   cmd_start ;;
  status)  cmd_status ;;
  collect) cmd_collect ;;
  stop)    cmd_stop ;;
  spend)   cmd_spend ;;
  *) cat >&2 <<USAGE
sidecar.sh start  --task TEXT [--provider NAME] [--permission-mode MODE]
sidecar.sh status
sidecar.sh collect --worker NAME
sidecar.sh stop    --worker NAME
sidecar.sh spend

--permission-mode defaults to auto, to match an orchestrator running in auto.
It is deliberately not narrowed: acceptEdits lets a worker write a file and then
stalls it on the commit with nobody there to answer.
USAGE
     exit 2 ;;
esac
