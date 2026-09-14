#!/bin/bash
# UserPromptSubmit hook for sidecar mode.
# When the flag file exists (toggled by /sidecar-on and /sidecar-off), tell the
# session which provider is active, whether a worker is out, and inject that
# provider's rules of engagement — the `## Orchestrator` section of
# ~/.claude/drive-sidecar/providers/NAME.rules.md. The flag file's first line
# is the provider name /sidecar-on was given; empty means deepseek.
#
# Same shape as drive-mode.sh: plain stdout, nothing but bash, exit 0 always —
# a hook that fails must not take the prompt with it. The section reader is a
# copy of _rules_section in sidecar.sh (this file is installed standalone and
# cannot source it); tests/run-tests.sh asserts the two agree on a fixture.

FLAG="$HOME/.claude/sidecar-mode"
RUN="$HOME/.claude/sidecar-run"
PROVIDERS="$HOME/.claude/drive-sidecar/providers"

[ -f "$FLAG" ] || exit 0

provider=''
IFS= read -r provider < "$FLAG" || true
provider=${provider// /}
case $provider in ""|*[!A-Za-z0-9_-]*) provider=deepseek ;; esac

worker=''
for f in "$RUN"/*.env; do
  [ -f "$f" ] || continue
  worker=${f##*/}; worker=${worker%.env}
  break
done

if [ -n "$worker" ]; then
  echo "SIDECAR MODE IS ON (provider $provider; worker $worker is out — collect it before starting another; turn off with /sidecar-off). Rules of engagement for dispatching to $provider:"
else
  echo "SIDECAR MODE IS ON (provider $provider; no worker out; turn off with /sidecar-off). Rules of engagement for dispatching to $provider:"
fi

rules="$PROVIDERS/$provider.rules.md"
if [ -f "$rules" ]; then
  in=0; body=''
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in" = 1 ]; then
      case $line in "## "*) break ;; esac
      body="$body$line"$'\n'
    elif [ "$line" = "## Orchestrator" ]; then
      in=1
    fi
  done < "$rules"
  while [ "${body#$'\n'}" != "$body" ]; do body=${body#$'\n'}; done
  while [ "${body%$'\n'}" != "$body" ]; do body=${body%$'\n'}; done
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    echo "  (no ## Orchestrator section in $rules)"
  fi
else
  echo "  (no rules written for $provider: $rules is absent)"
fi

# The rest of the roster, one line each, so the session can pick per task
# (`start --provider NAME [--model SLUG]` works whatever the mode's provider is).
others=''
for conf in "$PROVIDERS"/*.conf; do
  [ -f "$conf" ] || continue
  name=${conf##*/}; name=${name%.conf}
  [ "$name" = "$provider" ] && continue
  roster=''
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in roster=*) roster=${line#roster=} ;; esac
  done < "$conf"
  [ -n "$roster" ] || continue
  others="$others- $name: $roster"$'\n'
done
if [ -n "$others" ]; then
  echo "Other providers (start --provider NAME [--model SLUG]):"
  printf '%s' "$others"
fi

exit 0
