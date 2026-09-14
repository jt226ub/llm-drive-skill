#!/bin/bash
# Test suite for the drive installer.
#
#   ./tests/run-tests.sh
#
# The reason this exists: install.sh edits settings.json with a JSON scanner
# written in bash rather than with jq. That trade buys a dependency-free
# install, and it is only defensible if the scanner is held to evidence. These
# tests are that evidence.
#
# Independent JSON validation uses python3 when it is present. It is a
# developer-machine convenience only — nothing in the installed product needs
# it — and when it is absent those checks report SKIP rather than passing
# quietly.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }
group(){ printf '\n%s\n' "$1"; }

HAVE_PY=0
command -v python3 >/dev/null 2>&1 && python3 -c '' 2>/dev/null && HAVE_PY=1

# assert_json FILE LABEL — the file parses as JSON.
assert_json() {
  if [ "$HAVE_PY" = 0 ]; then skip "$2 (no python3 to validate with)"; return; fi
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then
    ok "$2"
  else
    bad "$2" "$(cat "$1")"
  fi
}

# assert_eq EXPECTED ACTUAL LABEL
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$1] got [$2]"; fi
}

# hook_commands FILE — every UserPromptSubmit command, one per line.
hook_commands() {
  [ "$HAVE_PY" = 1 ] || return 1
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for g in d.get("hooks",{}).get("UserPromptSubmit",[]):
    for e in g.get("hooks",[]):
        print(e.get("command",""))
' "$1"
}

. "$ROOT/lib.sh"
CMD='"$HOME/.claude/hooks/drive-mode.sh"'

# ---------------------------------------------------------------------------
group "Dependency floor — the whole point of the rewrite"
# ---------------------------------------------------------------------------
# Comments in these files talk about jq and node constantly; executable lines
# may not. Truncating each line at the first # is approximate — it also cuts a
# literal # inside a string — but it only ever removes text from the search, and
# these scripts have no such string.
AUDIT_TOOLS="jq perl python python3 awk sed node"
for f in install.sh uninstall.sh lib.sh hooks/drive-mode.sh hooks/sidecar-mode.sh omniroute/install-omniroute.sh \
         modules/budget/sensor.sh modules/budget/gate.sh modules/budget/park.sh modules/budget/resume.sh; do
  found=""
  while IFS= read -r line; do
    line=${line%%#*}
    [ -n "$line" ] || continue
    for tool in $AUDIT_TOOLS; do
      # node is the interpreter for OmniRoute's own CLI, which that script
      # cannot work without; it is not a dependency this project introduces.
      if [ "$tool" = node ] && [ "$f" = omniroute/install-omniroute.sh ]; then continue; fi
      re="(^|[^A-Za-z0-9_./-])$tool([^A-Za-z0-9_-]|$)"
      if [[ $line =~ $re ]]; then found="$found $tool"; fi
    done
  done < "$ROOT/$f"
  if [ -z "$found" ]; then
    ok "$f invokes none of: $AUDIT_TOOLS"
  else
    bad "$f invokes$found"
  fi
done

# ---------------------------------------------------------------------------
group "Frontmatter — the hook and lib.sh must never drift"
# ---------------------------------------------------------------------------
hook_strip() {                     # exactly the loop inside hooks/drive-mode.sh
  local delims=0 line
  local re='^---[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$delims" -ge 2 ]; then printf '%s\n' "$line"
    elif [[ $line =~ $re ]]; then delims=$((delims + 1)); fi
  done < "$1"
}
# Pull the real loop out of the hook so this compares shipped code, not a copy
# of a copy: run the hook itself against a fake HOME.
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME/.claude/skills/drive"
run_hook() {
  cp "$1" "$FAKEHOME/.claude/skills/drive/SKILL.md"
  touch "$FAKEHOME/.claude/drive-mode"
  HOME="$FAKEHOME" bash "$ROOT/hooks/drive-mode.sh" | tail -n +2
}

printf -- '---\nname: x\n---\n\nbody line 1\n\n## head\nbody line 2\n' > "$WORK/fm-plain.md"
printf -- '---\nname: x\n---   \n\nbody\n--- \nstill body\n' > "$WORK/fm-inner-delim.md"
printf -- '---\nname: x\n---\n\nno trailing newline' > "$WORK/fm-no-nl.md"
printf -- '---\r\nname: x\r\n---\r\n\r\nbody crlf\r\n' > "$WORK/fm-crlf.md"
for f in "$WORK"/fm-*.md "$ROOT/skills/drive/SKILL.md"; do
  n="$(basename "$f")"
  a="$(strip_frontmatter "$f")"
  b="$(run_hook "$f")"
  assert_eq "$a" "$b" "lib.sh and the hook agree on $n"
done
# The blank line right after the closing --- is part of the body — the awk rule
# this replaced printed it too, and $( ) strips only trailing newlines.
assert_eq "
body line 1

## head
body line 2" "$(strip_frontmatter "$WORK/fm-plain.md")" "frontmatter body is exact"
assert_eq "
body
--- 
still body" "$(strip_frontmatter "$WORK/fm-inner-delim.md")" "a --- inside the body survives"

# ---------------------------------------------------------------------------
group "The hook survives an empty PATH"
# ---------------------------------------------------------------------------
# This is the bug the whole project exists to fix. The original hook piped
# through jq; where jq was missing the pipeline failed, the script still exited
# 0, and drive mode injected nothing while reporting nothing. So the guard is
# not "does the source mention jq" — the current hook names jq in a comment and
# a grep cannot tell the two apart — it is whether the hook still emits the
# contract with no external command available at all.
BARE="$FAKEHOME/.claude/skills/drive/SKILL.md"
mkdir -p "$FAKEHOME/.claude/skills/drive"
cp "$ROOT/skills/drive/SKILL.md" "$BARE"
touch "$FAKEHOME/.claude/drive-mode"
bare_out="$(HOME="$FAKEHOME" PATH="" /bin/bash "$ROOT/hooks/drive-mode.sh" 2>/dev/null)"
if [ "${#bare_out}" -gt 1000 ]; then
  ok "the hook injects the contract with PATH empty (${#bare_out} bytes)"
else
  bad "the hook injects the contract with PATH empty" "emitted ${#bare_out} bytes"
fi
case $bare_out in
  "DRIVE MODE IS ON"*) ok "its first line is the standing-mode header" ;;
  *) bad "its first line is the standing-mode header" "got: ${bare_out:0:60}" ;;
esac
rm -f "$FAKEHOME/.claude/drive-mode"
bare_off="$(HOME="$FAKEHOME" PATH="" /bin/bash "$ROOT/hooks/drive-mode.sh" 2>/dev/null)"
assert_eq "" "$bare_off" "with the flag removed it emits nothing"

# ---------------------------------------------------------------------------
group "json_escape"
# ---------------------------------------------------------------------------
json_escape E 'plain/path.sh'          ; assert_eq 'plain/path.sh' "$E" "leaves a plain path alone"
json_escape E 'a"b\c'                  ; assert_eq 'a\"b\\c'       "$E" "escapes quote and backslash"
json_escape E "$(printf 'a\tb')"       ; assert_eq 'a\tb'          "$E" "escapes a tab"
json_escape E 'a
b'                                     ; assert_eq 'a\nb'          "$E" "escapes a newline"
if json_escape E "$(printf 'a\001b')" 2>/dev/null; then
  bad "rejects a raw control character" "accepted it"
else
  ok "rejects a raw control character"
fi

# ---------------------------------------------------------------------------
group "settings.json — register"
# ---------------------------------------------------------------------------
fixture() { printf '%s' "$2" > "$WORK/$1.json"; echo "$WORK/$1.json"; }

f_empty=$(fixture empty '{}')
f_none=$(fixture none '{
  "model": "opus[1m]",
  "theme": "auto"
}
')
f_hooks_only=$(fixture hooksonly '{
  "hooks": {
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "echo hi" } ] }
    ]
  }
}
')
f_ups=$(fixture ups '{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "other.sh" } ] }
    ]
  }
}
')
f_min=$(fixture min '{"model":"opus","hooks":{"UserPromptSubmit":[]}}')
f_tabs=$(fixture tabs "$(printf '{\n\t"model": "opus",\n\t"hooks": {\n\t\t"UserPromptSubmit": []\n\t}\n}\n')")
# Modelled on a real settings.json: a long multi-line array of prose strings
# carrying quotes, backticks, parentheses and em dashes, sitting before the
# hooks key. This is the shape that first proved the scanner on real data.
f_prose=$(fixture prose '{
  "model": "opus[1m]",
  "autoMode": {
    "environment": [
      "### Org-wide",
      "**Repository visibility**: assume private unless the remote host says otherwise",
      "**Source control**: the trusted repo (this working directory) — no remotes yet",
      "**Sensitive remote targets**: any name carrying `prod` as a segment (e.g. `prod-db`, not `producer`)",
      "**Default branches**: unknown — origin/HEAD unset, and \"gh\" lookup unavailable"
    ]
  },
  "theme": "auto"
}
')
f_uni=$(fixture uni '{
  "note": "em—dash, curly “quotes”, emoji 🚀, backslash \\ and \"quoted\"",
  "model": "opus"
}
')

for pair in "empty:$f_empty" "none:$f_none" "hooksonly:$f_hooks_only" "ups:$f_ups" "min:$f_min" "tabs:$f_tabs" "uni:$f_uni" "prose:$f_prose"; do
  name=${pair%%:*}; file=${pair#*:}
  if settings_register_hook "$file" "$CMD" >/dev/null 2>&1; then
    assert_json "$file" "register into $name produces valid JSON"
    if [ "$HAVE_PY" = 1 ]; then
      if hook_commands "$file" | grep -qxF "$CMD"; then ok "register into $name lands the command"
      else bad "register into $name lands the command" "$(hook_commands "$file")"; fi
    fi
    if settings_hook_registered "$file" drive-mode.sh; then ok "register into $name is then detected"
    else bad "register into $name is then detected"; fi
  else
    bad "register into $name" "returned non-zero"
  fi
done

# The foreign entry must survive alongside ours.
if [ "$HAVE_PY" = 1 ]; then
  assert_eq "other.sh
$CMD" "$(hook_commands "$f_ups")" "an existing UserPromptSubmit entry is kept"
fi

# Unrelated settings must survive untouched.
if [ "$HAVE_PY" = 1 ]; then
  assert_eq 'em—dash, curly “quotes”, emoji 🚀, backslash \ and "quoted"' \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["note"])' "$f_uni")" \
    "unicode and escapes in an unrelated key survive"
fi

# ---------------------------------------------------------------------------
group "settings.json — deregister"
# ---------------------------------------------------------------------------
for pair in "empty:$f_empty" "none:$f_none" "hooksonly:$f_hooks_only" "ups:$f_ups" "min:$f_min" "tabs:$f_tabs" "uni:$f_uni" "prose:$f_prose"; do
  name=${pair%%:*}; file=${pair#*:}
  settings_deregister_hook "$file" drive-mode.sh >/dev/null 2>&1
  rc=$?
  assert_eq 0 "$rc" "deregister from $name reports a change"
  assert_json "$file" "deregister from $name leaves valid JSON"
  if settings_hook_registered "$file" drive-mode.sh; then
    bad "deregister from $name actually removes it"
  else
    ok "deregister from $name actually removes it"
  fi
done

if [ "$HAVE_PY" = 1 ]; then
  assert_eq "other.sh" "$(hook_commands "$f_ups")" "deregister keeps the foreign entry"
  assert_eq "echo hi" "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["hooks"]["PostToolUse"][0]["hooks"][0]["command"])' "$f_hooks_only")" \
    "deregister leaves an unrelated hook event alone"
fi

settings_deregister_hook "$f_none" drive-mode.sh >/dev/null 2>&1
assert_eq 2 "$?" "deregister with nothing to remove reports no-change"

if [ "$HAVE_PY" = 1 ]; then
  assert_eq '**Default branches**: unknown — origin/HEAD unset, and "gh" lookup unavailable' \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["autoMode"]["environment"][-1])' "$f_prose")" \
    "a long prose array survives register and deregister untouched"
fi

# ---------------------------------------------------------------------------
group "settings.json — refusals"
# ---------------------------------------------------------------------------
printf 'not json at all' > "$WORK/bad.json"
if settings_register_hook "$WORK/bad.json" "$CMD" >/dev/null 2>&1; then
  bad "refuses a non-JSON settings.json"
else
  assert_eq 'not json at all' "$(cat "$WORK/bad.json")" "refuses a non-JSON settings.json and leaves it byte-identical"
fi
printf '{"hooks": "surprise"}' > "$WORK/oddhooks.json"
if settings_register_hook "$WORK/oddhooks.json" "$CMD" >/dev/null 2>&1; then
  bad "refuses a hooks key that is not an object"
else
  assert_eq '{"hooks": "surprise"}' "$(cat "$WORK/oddhooks.json")" "refuses a hooks key that is not an object, leaving it alone"
fi

# ---------------------------------------------------------------------------
group "Invariants held by construction"
# ---------------------------------------------------------------------------
writers="$(grep -cE '^\s*JDOC=' "$ROOT/lib.sh")"
assert_eq 1 "$writers" "_j_set is the only assignment to JDOC (a stale chunk index would corrupt reads)"

# ---------------------------------------------------------------------------
group "install.sh / uninstall.sh end to end"
# ---------------------------------------------------------------------------
E2E="$WORK/claude"
mkdir -p "$E2E"
ORIGINAL='{
  "model": "opus[1m]",
  "permissions": { "allow": ["Bash(git status:*)"] }
}
'
printf '%s' "$ORIGINAL" > "$E2E/settings.json"

if CLAUDE_DIR="$E2E" bash "$ROOT/install.sh" > "$WORK/install.log" 2>&1; then
  ok "install.sh exits clean"
else
  bad "install.sh exits clean" "$(cat "$WORK/install.log")"
fi
for want in skills/drive/SKILL.md commands/drive-on.md commands/drive-off.md hooks/drive-mode.sh hooks/sidecar-mode.sh drive-sidecar/providers/deepseek.rules.md; do
  if [ -f "$E2E/$want" ]; then ok "install.sh placed $want"; else bad "install.sh placed $want"; fi
done
if [ -x "$E2E/hooks/drive-mode.sh" ]; then ok "the hook is executable"; else bad "the hook is executable"; fi
assert_json "$E2E/settings.json" "install.sh leaves valid JSON"
if settings_hook_registered "$E2E/settings.json" drive-mode.sh; then ok "install.sh registered the hook"; else bad "install.sh registered the hook"; fi
if settings_hook_registered "$E2E/settings.json" sidecar-mode.sh; then ok "install.sh registered the sidecar rules hook"; else bad "install.sh registered the sidecar rules hook"; fi
if ls "$E2E"/settings.json.bak.* >/dev/null 2>&1; then ok "install.sh wrote a backup"; else bad "install.sh wrote a backup"; fi
if [ "$HAVE_PY" = 1 ]; then
  assert_eq 'Bash(git status:*)' "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["permissions"]["allow"][0])' "$E2E/settings.json")" \
    "install.sh preserved an unrelated setting"
fi

SETTINGS_AFTER_FIRST="$(cat "$E2E/settings.json")"
CLAUDE_DIR="$E2E" bash "$ROOT/install.sh" > "$WORK/install2.log" 2>&1
# Asserted on the file rather than on the wording of a log line: the claim is
# that a re-run changes nothing, and a message can be reworded without that
# becoming false.
assert_eq "$SETTINGS_AFTER_FIRST" "$(cat "$E2E/settings.json")" "a second install.sh is a no-op on settings.json"
assert_eq 1 "$(ls "$E2E"/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')" "a second install.sh writes no second backup"
if [ "$(ls "$E2E"/settings.json.bak.* | wc -l | tr -d ' ')" = 1 ]; then ok "the no-op install writes no second backup"
else bad "the no-op install writes no second backup"; fi

if CLAUDE_DIR="$E2E" bash "$ROOT/uninstall.sh" > "$WORK/uninstall.log" 2>&1; then
  ok "uninstall.sh exits clean"
else
  bad "uninstall.sh exits clean" "$(cat "$WORK/uninstall.log")"
fi
for gone in skills/drive/SKILL.md commands/drive-on.md commands/drive-off.md hooks/drive-mode.sh drive-mode hooks/sidecar-mode.sh drive-sidecar/providers/deepseek.rules.md; do
  if [ -e "$E2E/$gone" ]; then bad "uninstall.sh removed $gone"; else ok "uninstall.sh removed $gone"; fi
done
if [ "$(cat "$E2E/settings.json")" = "$(printf '%s' "$ORIGINAL")" ]; then
  ok "install then uninstall restores settings.json byte for byte"
else
  bad "install then uninstall restores settings.json byte for byte" "$(cat "$E2E/settings.json")"
fi

# A clean machine: no settings.json at all.
CLEAN="$WORK/clean"; mkdir -p "$CLEAN"
if CLAUDE_DIR="$CLEAN" bash "$ROOT/install.sh" > "$WORK/clean.log" 2>&1; then
  ok "install.sh works with no settings.json to start from"
else
  bad "install.sh works with no settings.json to start from" "$(cat "$WORK/clean.log")"
fi
assert_json "$CLEAN/settings.json" "the settings.json it creates is valid JSON"
if ls "$CLEAN"/settings.json.bak.* >/dev/null 2>&1; then
  bad "no backup is written for a file that did not exist"
else
  ok "no backup is written for a file that did not exist"
fi

# ---------------------------------------------------------------------------
group "Size budget"
# ---------------------------------------------------------------------------
BUDGET="$WORK/budget"; mkdir -p "$BUDGET"
FATREPO="$WORK/fatrepo"
mkdir -p "$FATREPO/skills/drive" "$FATREPO/commands" "$FATREPO/hooks"
cp "$ROOT/lib.sh" "$FATREPO/"; cp "$ROOT/install.sh" "$FATREPO/"
cp "$ROOT/commands/"*.md "$FATREPO/commands/"; cp "$ROOT/hooks/drive-mode.sh" "$FATREPO/hooks/"
{ printf -- '---\nname: drive\n---\n\n'; i=0; while [ $i -lt 200 ]; do printf 'padding line to blow the budget wide open %d\n' $i; i=$((i + 1)); done; } > "$FATREPO/skills/drive/SKILL.md"
if CLAUDE_DIR="$BUDGET" bash "$FATREPO/install.sh" > "$WORK/fat.log" 2>&1; then
  bad "install.sh refuses an over-budget contract"
else
  if grep -q "over the 9,000 budget" "$WORK/fat.log"; then ok "install.sh refuses an over-budget contract"
  else bad "install.sh refuses an over-budget contract" "$(cat "$WORK/fat.log")"; fi
fi
if [ -e "$BUDGET/skills/drive/SKILL.md" ]; then bad "the refused install copied nothing"; else ok "the refused install copied nothing"; fi

BODY="$(strip_frontmatter "$ROOT/skills/drive/SKILL.md")"
if [ "${#BODY}" -le 9000 ]; then ok "the shipped contract is inside the budget (${#BODY} chars)"
else bad "the shipped contract is inside the budget" "${#BODY} chars"; fi

# ---------------------------------------------------------------------------
group "OmniRoute deployment against a stub gateway"
# ---------------------------------------------------------------------------
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/omniroute" <<'STUBEOF'
#!/bin/bash
# Stub OmniRoute CLI: stores a put payload, replays it on get, and surrounds the
# reply with the chatty notices the real CLI prints.
STORE="$OMNIROUTE_STUB_STORE"
case "$3" in
  put-api-settings-system-prompt) cp "${5#@}" "$STORE"; echo "ok" ;;
  get-api-settings-system-prompt)
    echo "note: using base url $OMNIROUTE_BASE_URL"
    cat "$STORE"
    echo
    echo "note: done" ;;
esac
STUBEOF
chmod +x "$STUB/omniroute"
export OMNIROUTE_STUB_STORE="$WORK/omni-store.json"
if PATH="$STUB:$PATH" bash "$ROOT/omniroute/install-omniroute.sh" > "$WORK/omni.log" 2>&1; then
  ok "install-omniroute.sh completes and verifies its own write"
else
  bad "install-omniroute.sh completes and verifies its own write" "$(cat "$WORK/omni.log")"
fi
assert_json "$OMNIROUTE_STUB_STORE" "the payload it sends is valid JSON"
if [ "$HAVE_PY" = 1 ]; then
  sent="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prefixPrompt"])' "$OMNIROUTE_STUB_STORE")"
  body="$(strip_frontmatter "$ROOT/skills/drive/SKILL.md")"
  body="${body#"${body%%[![:space:]]*}"}"
  if [ "${sent#*$'\n\n'}" = "$body" ]; then
    ok "the contract arrives at the gateway byte-identical to SKILL.md"
  else
    bad "the contract arrives at the gateway byte-identical to SKILL.md"
  fi
  if python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))["enabled"] is True else 1)' "$OMNIROUTE_STUB_STORE"; then
    ok "the payload enables the prompt"
  else
    bad "the payload enables the prompt"
  fi
fi
# A gateway that truncates must be caught, not reported as success.
cat > "$STUB/omniroute" <<'STUBEOF'
#!/bin/bash
STORE="$OMNIROUTE_STUB_STORE"
case "$3" in
  put-api-settings-system-prompt) cp "${5#@}" "$STORE"; echo ok ;;
  get-api-settings-system-prompt) echo '{"enabled": true, "prefixPrompt": "truncated", "suffixPrompt": ""}' ;;
esac
STUBEOF
if PATH="$STUB:$PATH" bash "$ROOT/omniroute/install-omniroute.sh" > "$WORK/omni2.log" 2>&1; then
  bad "a truncated read-back is reported as a failure"
else
  if grep -q "lengths differ" "$WORK/omni2.log"; then ok "a truncated read-back is reported as a failure"
  else bad "a truncated read-back is reported as a failure" "$(cat "$WORK/omni2.log")"; fi
fi

# ---------------------------------------------------------------------------
group "Budget sensor — reading the status line payload"
# ---------------------------------------------------------------------------
# The sensor is the only thing that knows the plan limits, so everything the
# gate does rests on it parsing this payload correctly. The shapes below are the
# ones the status line reference says actually occur: any window independently
# absent, the whole object absent, and no guaranteed key order.
BHOME="$WORK/bhome"; mkdir -p "$BHOME/.claude"
sensor() {                     # payload on stdin; prints the status line
  HOME="$BHOME" bash "$ROOT/modules/budget/sensor.sh"
}
state_get() {                  # state_get KEY
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "$BHOME/.claude/budget-state"
}

sensor >/dev/null <<'PAYLOAD'
{"model":{"id":"claude-opus-5","display_name":"Opus 5"},
 "workspace":{"current_dir":"/tmp/proj"},
 "rate_limits":{"seven_day":{"used_percentage":41.2,"resets_at":1738857600},
                "five_hour":{"used_percentage":97.6,"resets_at":1738425600},
                "spend_limit":{"used_percentage":62.8,"resets_at":1740787200}}}
PAYLOAD
assert_eq present    "$(state_get RATE_LIMITS)"  "sensor sees rate_limits"
assert_eq 97.6       "$(state_get FIVE_H_PCT)"   "five_hour percentage, listed after seven_day"
assert_eq 1738425600 "$(state_get FIVE_H_RESET)" "five_hour reset, listed after seven_day"
assert_eq 41.2       "$(state_get SEVEN_D_PCT)"  "seven_day percentage"
assert_eq 62.8       "$(state_get SPEND_PCT)"    "spend_limit percentage"

# The failure this bounding exists to prevent: with five_hour gone, a scan that
# just looked for the next "used_percentage" would report seven_day's number as
# the session window and the gate would never fire.
sensor >/dev/null <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},
 "rate_limits":{"seven_day":{"used_percentage":91,"resets_at":1738857600}}}
PAYLOAD
assert_eq ""   "$(state_get FIVE_H_PCT)"   "an absent five_hour window stays empty"
assert_eq ""   "$(state_get FIVE_H_RESET)" "an absent five_hour reset stays empty"
assert_eq 91   "$(state_get SEVEN_D_PCT)"  "the weekly window is still read"

# budget-state describes the account, not one session. A session with no
# rate_limits knows nothing about the account, so it must leave the file alone —
# every session's first status line runs before its first API response, and a
# session on an API key or a non-Anthropic endpoint never has them at all.
# Overwriting here would put the gate into fail-open while the real numbers were
# on disk a moment earlier.
sensor >/dev/null <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},
 "rate_limits":{"five_hour":{"used_percentage":88.0,"resets_at":1738425600}}}
PAYLOAD
BEFORE="$(cat "$BHOME/.claude/budget-state")"
sensor >/dev/null <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":8}}
PAYLOAD
assert_eq "$BEFORE" "$(cat "$BHOME/.claude/budget-state")" "a session with no rate_limits leaves budget-state untouched"
assert_eq 88.0 "$(state_get FIVE_H_PCT)" "so the account's real numbers survive a session that cannot see them"

rm -f "$BHOME/.claude/budget-state"
sensor >/dev/null <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":8}}
PAYLOAD
if [ -f "$BHOME/.claude/budget-state" ]; then
  bad "and no state file is invented when there was none"
else
  ok "and no state file is invented when there was none"
fi

OUT="$(sensor <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":8}}
PAYLOAD
)"
case $OUT in
  *"no plan limits"*) ok "the status line says so when there are no plan limits" ;;
  *) bad "the status line says so when there are no plan limits" "$OUT" ;;
esac

OUT="$(sensor <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},
 "rate_limits":{"five_hour":{"used_percentage":42.9,"resets_at":1738425600}}}
PAYLOAD
)"
case $OUT in
  *"5h 42%"*) ok "the status line truncates rather than rounds up (42.9 -> 42)" ;;
  *) bad "the status line truncates rather than rounds up (42.9 -> 42)" "$OUT" ;;
esac

# ---------------------------------------------------------------------------
group "Budget gate — thresholds, allowlist and failing open"
# ---------------------------------------------------------------------------
mkdir -p "$BHOME/.claude/drive-budget"
cp "$ROOT/modules/budget/BUDGET.md" "$BHOME/.claude/drive-budget/BUDGET.md"
NOW_T="$(date +%s)"

set_state() {                  # set_state 5H% 7D% [AGE_SECONDS] [present|absent]
  printf 'UPDATED=%s\nRATE_LIMITS=%s\nFIVE_H_PCT=%s\nFIVE_H_RESET=%s\nSEVEN_D_PCT=%s\nSEVEN_D_RESET=%s\n' \
    "$((NOW_T - ${3:-10}))" "${4:-present}" "$1" "$((NOW_T + 900))" "$2" "$((NOW_T + 90000))" \
    > "$BHOME/.claude/budget-state"
}
hook_json() {                  # hook_json TOOL [EXTRA_JSON]
  printf '{"session_id":"sess-1","cwd":"/tmp/proj","tool_name":"%s"%s}' "$1" "${2:-}"
}
gate() {                       # gate MODE TOOL [EXTRA_JSON]
  hook_json "$2" "${3:-}" | HOME="$BHOME" bash "$ROOT/modules/budget/gate.sh" "$1"
}
decision() {                   # decision from a PreToolUse result, via python3
  [ "$HAVE_PY" = 1 ] || return 1
  python3 -c '
import json,sys
s=sys.stdin.read().strip()
if not s: print("silent"); raise SystemExit
d=json.loads(s)["hookSpecificOutput"]
print(d.get("permissionDecision") or ("context" if "additionalContext" in d else "?"))'
}

rm -f "$BHOME/.claude/budget-mode"
set_state 99.9 99.9
assert_eq "" "$(gate prompt Bash)" "with the flag off the prompt hook says nothing"
assert_eq "" "$(gate tool Bash)"   "with the flag off the tool gate says nothing"

touch "$BHOME/.claude/budget-mode"
rm -rf "$BHOME/.claude/budget-run"
set_state 42.1 61.7
OUT="$(gate prompt Bash)"
case $OUT in
  "Budget: 5h 42%"*) ok "below the thresholds the prompt hook prints one status line" ;;
  *) bad "below the thresholds the prompt hook prints one status line" "$OUT" ;;
esac
assert_eq 1 "$(gate prompt Bash | wc -l | tr -d ' ')" "and only one line"
assert_eq "" "$(gate tool Bash)" "below the thresholds the tool gate is silent"

set_state 97.2 61.7
rm -rf "$BHOME/.claude/budget-run"
assert_eq context "$(gate tool Bash | decision)" "at the wrap threshold the tool gate adds context"
assert_eq silent  "$(gate tool Bash | decision)" "and does not repeat itself on the next call"
OUT="$(gate prompt Bash)"
case $OUT in
  *"nearly spent"*"⇒ NEXT"*) ok "the wrap directive carries the record schema" ;;
  *) bad "the wrap directive carries the record schema" "$OUT" ;;
esac

set_state 99.4 61.7
rm -rf "$BHOME/.claude/budget-run"
assert_eq context "$(gate tool Write | decision)" "at the hard threshold Write is still allowed through"
assert_eq context "$(gate tool Bash  | decision)" "and so is Bash, so the record can be committed"
assert_eq deny    "$(gate tool Task  | decision)" "but Task is denied — subagents spend the window fastest"
assert_eq deny    "$(gate tool WebFetch | decision)" "and so is anything else not needed to write the record"
if [ "$HAVE_PY" = 1 ]; then
  if gate tool Task | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "the deny it emits is valid JSON"
  else
    bad "the deny it emits is valid JSON" "$(gate tool Task)"
  fi
fi

# The allowance has to be bounded, or "write the record" is an open licence to
# keep calling Read. 25 is the default; the 26th call is refused.
rm -rf "$BHOME/.claude/budget-run"; mkdir -p "$BHOME/.claude/budget-run"
printf '%s 25\n' "$((NOW_T + 900))" > "$BHOME/.claude/budget-run/calls"
assert_eq deny "$(gate tool Read | decision)" "the record allowance is bounded at HANDOFF_CALLS"
# A new window starts the count over: the stamp no longer matches.
printf 'stale-window 25\n' > "$BHOME/.claude/budget-run/calls"
assert_eq context "$(gate tool Read | decision)" "a new window resets the allowance"

rm -rf "$BHOME/.claude/budget-run"
assert_eq deny "$(gate tool Read ',"agent_id":"ag-1","agent_type":"Explore"' | decision)" \
  "a subagent at the hard threshold is closed outright"
OUT="$(gate tool Read ',"agent_id":"ag-1"' )"
case $OUT in
  *"Return immediately"*) ok "and is told to return its findings, not to write files" ;;
  *) bad "and is told to return its findings, not to write files" "$OUT" ;;
esac

# Claude Code drops a window once it has reset, so the percentage is empty and
# the gate's whole-percent helper yields -1. Printing "5h -1%" reads as a broken
# meter rather than an empty window, which is what it did on the first reset.
set_state "" 28.0
rm -rf "$BHOME/.claude/budget-run"
OUT="$(gate prompt Bash)"
case $OUT in
  *"-1%"*) bad "a window that has just reset does not print as -1%" "$OUT" ;;
  *"window fresh"*) ok "a window that has just reset prints as fresh" ;;
  *) bad "a window that has just reset prints as fresh" "$OUT" ;;
esac
case $OUT in
  *"7d 28%"*) ok "and the weekly window is still reported beside it" ;;
  *) bad "and the weekly window is still reported beside it" "$OUT" ;;
esac

set_state 12.0 91.5
rm -rf "$BHOME/.claude/budget-run"
OUT="$(gate prompt Bash)"
case $OUT in
  *"weekly window is nearly spent"*) ok "the weekly window has its own, earlier documentation threshold" ;;
  *) bad "the weekly window has its own, earlier documentation threshold" "$OUT" ;;
esac
set_state 12.0 97.5
assert_eq deny "$(gate tool Task | decision)" "and its own hard threshold"

# Failing open, loudly. A gate that denied tools because it could not read its
# own state file would brick the session over its own bug.
set_state 99.9 99.9 7200
rm -rf "$BHOME/.claude/budget-run"
assert_eq silent "$(gate tool Task | decision)" "a stale state file leaves the tool gate open"
OUT="$(gate prompt Bash)"
case $OUT in
  *"NO USAGE DATA"*) ok "and the prompt hook says so rather than staying quiet" ;;
  *) bad "and the prompt hook says so rather than staying quiet" "$OUT" ;;
esac

set_state 99.9 50 10
mkdir -p "$BHOME/.claude/budget-run"
echo "$((NOW_T + 600))" > "$BHOME/.claude/budget-run/parked-sess-1"
assert_eq deny "$(gate tool Read | decision)" "a parked session is closed to every tool"
OUT="$(printf '{"session_id":"sess-2","tool_name":"Read"}' | HOME="$BHOME" bash "$ROOT/modules/budget/gate.sh" tool | decision)"
assert_eq context "$OUT" "but parking one session does not gate another out of writing its own record"

# The marker must expire on its own. Claude Code's own automatic continue
# resumes an interactive session the instant the limit resets — before the
# scheduled wake — and a marker only the wake job could clear would gate that
# continuation into uselessness. A parked session cannot un-park itself either.
echo "$((NOW_T - 5))" > "$BHOME/.claude/budget-run/parked-sess-1"
assert_eq context "$(gate tool Read | decision)" "a park whose wake time has passed no longer gates anything"
if [ ! -f "$BHOME/.claude/budget-run/parked-sess-1" ]; then
  ok "and the spent marker is removed rather than left to puzzle someone"
else
  bad "and the spent marker is removed rather than left to puzzle someone"
fi
: > "$BHOME/.claude/budget-run/parked-sess-1"
assert_eq context "$(gate tool Read | decision)" "a marker with no readable wake time fails open rather than gating forever"
rm -rf "$BHOME/.claude/budget-run"

# Thresholds come from the config file when it is there.
printf 'WRAP_PCT=50\nSTOP_PCT=60\n' > "$BHOME/.claude/budget-config"
set_state 65.0 10.0
assert_eq deny "$(gate tool Task | decision)" "budget-config overrides the built-in thresholds"
# A config value that is not a number is dropped, leaving the built-in default:
# at 98% with STOP_PCT back at 99 the level is wrap, not stop, so Task gets
# context rather than a deny. Obeying "oops" as a threshold would deny here.
printf 'STOP_PCT=oops\nWRAP_PCT=\n' > "$BHOME/.claude/budget-config"
set_state 98.0 10.0
rm -rf "$BHOME/.claude/budget-run"
assert_eq context "$(gate tool Task | decision)" "a non-numeric config value is ignored, not obeyed"
rm -f "$BHOME/.claude/budget-config"

# Every marker the gate asks BUDGET.md for must exist, or a directive silently
# comes back empty.
# A sidecar worker spends another provider's money and none of these windows, so
# gating it would stop work that costs nothing to continue. It is informed and
# never denied.
rm -rf "$BHOME/.claude/budget-run" "$BHOME/.claude/sidecar-run"
mkdir -p "$BHOME/.claude/sidecar-run"
printf 'worker=w1\nprovider=deepseek\nmodel=deepseek-flash\nsession=sess-1\nrepo=/tmp\n' \
  > "$BHOME/.claude/sidecar-run/w1.env"
set_state 99.9 50
assert_eq context "$(gate tool Task | decision)" "a sidecar worker is never denied at the five-hour limit"
OUT="$(gate prompt Bash)"
case $OUT in
  *"rate-limited"*"None of this is"*) ok "and is told the window is not its own" ;;
  *) bad "and is told the window is not its own" "$OUT" ;;
esac
case $OUT in
  *"cannot reply until"*) ok "and when the session that dispatched it can answer again" ;;
  *) bad "and when the session that dispatched it can answer again" "$OUT" ;;
esac
set_state 12.0 99.0
rm -rf "$BHOME/.claude/budget-run"
assert_eq context "$(gate tool Task | decision)" "nor at the weekly limit"
OUT="$(gate prompt Bash)"
case $OUT in
  *"Finish your task"*"do not need to stop"*) ok "at the weekly limit it writes the record but keeps working" ;;
  *) bad "at the weekly limit it writes the record but keeps working" "$OUT" ;;
esac
# And a worker's own subagents are on the same provider's money.
rm -rf "$BHOME/.claude/budget-run"
set_state 99.9 50
assert_eq context "$(gate tool Read ',"agent_id":"ag-1"' | decision)" \
  "a worker's own subagent is not closed either"
rm -rf "$BHOME/.claude/sidecar-run" "$BHOME/.claude/budget-run"
# With the worker records gone it is an ordinary session again, and gated.
assert_eq deny "$(gate tool Task | decision)" "an ordinary session at the same threshold is still gated"

for m in WRAP STOP WEEK_DOC WEEK_STOP SUBAGENT PARKED SCHEMA WORKER_FIVE_HOUR WORKER_WEEKLY; do
  if grep -q "^<!-- @$m -->$" "$ROOT/modules/budget/BUDGET.md"; then ok "BUDGET.md has the @$m section"
  else bad "BUDGET.md has the @$m section"; fi
done

# ---------------------------------------------------------------------------
group "Parking — what gets scheduled, and what refuses to be"
# ---------------------------------------------------------------------------
# launchctl is stubbed. The point is to assert the plist that would be loaded
# and the order of operations, without registering a job on the machine running
# the tests.
PHOME="$WORK/phome"; mkdir -p "$PHOME/.claude" "$PHOME/Library/LaunchAgents" "$PHOME/proj"
LSTUB="$WORK/lstub"; mkdir -p "$LSTUB"
cat > "$LSTUB/launchctl" <<'STUBEOF'
#!/bin/bash
echo "launchctl $*" >> "$LAUNCHCTL_LOG"
[ "${LAUNCHCTL_FAIL:-0}" = 1 ] && [ "$1" = bootstrap ] && exit 1
exit 0
STUBEOF
chmod +x "$LSTUB/launchctl"
export LAUNCHCTL_LOG="$WORK/launchctl.log"

park() { HOME="$PHOME" PATH="$LSTUB:$PATH" bash "$ROOT/modules/budget/park.sh" "$@"; }
RESET_AT=$(( $(date +%s) + 3600 ))
printf 'UPDATED=%s\nRATE_LIMITS=present\nFIVE_H_PCT=99.5\nFIVE_H_RESET=%s\nSEVEN_D_PCT=20\nSEVEN_D_RESET=\n' \
  "$(date +%s)" "$RESET_AT" > "$PHOME/.claude/budget-state"

if park --session "" >/dev/null 2>&1; then bad "park.sh refuses an empty session id"
else ok "park.sh refuses an empty session id"; fi
if park --session 'a b;rm -rf /' >/dev/null 2>&1; then bad "park.sh refuses a session id it cannot put in a label"
else ok "park.sh refuses a session id it cannot put in a label"; fi
if park --session ok-1 --window seven_day >/dev/null 2>&1; then bad "park.sh refuses a window with no known reset"
else ok "park.sh refuses a window with no known reset"; fi

if [ "$(uname -s)" != Darwin ]; then
  skip "park.sh writes a loadable plist (not macOS)"
  skip "park.sh sets the gate marker only after launchd accepts the job"
  skip "park.sh leaves nothing behind when launchd refuses"
  skip "park.sh --status lists what is parked"
  skip "park.sh --cancel removes the job, the plist and the marker"
else
  : > "$LAUNCHCTL_LOG"
  if park --session sess-1 --cwd "$PHOME/proj" > "$WORK/park.log" 2>&1; then
    ok "park.sh schedules a resume"
  else
    bad "park.sh schedules a resume" "$(cat "$WORK/park.log")"
  fi
  PLIST="$PHOME/Library/LaunchAgents/com.llmdrive.budget-resume.sess-1.plist"
  if [ -f "$PLIST" ]; then ok "park.sh wrote the launch agent"; else bad "park.sh wrote the launch agent"; fi
  # Rounded up to the minute, the same way park.sh does, because that is the
  # only granularity StartCalendarInterval has.
  WAKE=$((RESET_AT + 300))
  [ $((WAKE % 60)) -ne 0 ] && WAKE=$((WAKE + 60 - WAKE % 60))
  WANT_H=$(( 10#$(date -r "$WAKE" +%H) )); WANT_M=$(( 10#$(date -r "$WAKE" +%M) ))
  if grep -q "<key>Hour</key><integer>$WANT_H</integer>" "$PLIST" &&
     grep -q "<key>Minute</key><integer>$WANT_M</integer>" "$PLIST"; then
    ok "it fires RESUME_DELAY_S after the window resets"
  else
    bad "it fires RESUME_DELAY_S after the window resets" "wanted $WANT_H:$WANT_M in $(cat "$PLIST")"
  fi
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then ok "the plist parses"; else bad "the plist parses"; fi
  else
    skip "the plist parses (no plutil)"
  fi
  if [ -f "$PHOME/.claude/budget-run/parked-sess-1" ]; then
    ok "park.sh sets the gate marker only after launchd accepts the job"
  else
    bad "park.sh sets the gate marker only after launchd accepts the job"
  fi
  # The wake time it records must be the instant it actually scheduled, which
  # StartCalendarInterval can only express to the minute. Recording the odd
  # seconds made resume.sh think every firing was early, and a job that matches
  # one minute of one day gets no second chance.
  RECORDED=''
  while IFS= read -r line; do
    case $line in WAKE=*) RECORDED=${line#*=} ;; esac
  done < "$PHOME/.claude/budget-run/parked-sess-1.env"
  if [ -n "$RECORDED" ] && [ $((RECORDED % 60)) -eq 0 ]; then
    ok "the wake time it records sits on a whole minute, as the plist does"
  else
    bad "the wake time it records sits on a whole minute, as the plist does" "WAKE=$RECORDED"
  fi
  if [ -n "$RECORDED" ] && [ "$RECORDED" -ge $((RESET_AT + 300)) ]; then
    ok "and is never earlier than the reset plus its delay"
  else
    bad "and is never earlier than the reset plus its delay" "WAKE=$RECORDED reset=$RESET_AT"
  fi

  OUT="$(park --status)"
  case $OUT in
    *"parked  sess-1"*) ok "park.sh --status lists what is parked" ;;
    *) bad "park.sh --status lists what is parked" "$OUT" ;;
  esac

  park --cancel --session sess-1 >/dev/null 2>&1
  if [ ! -f "$PLIST" ] && [ ! -f "$PHOME/.claude/budget-run/parked-sess-1" ]; then
    ok "park.sh --cancel removes the job, the plist and the marker"
  else
    bad "park.sh --cancel removes the job, the plist and the marker"
  fi

  # A refused bootstrap must leave nothing: a marker with no job behind it is a
  # session gated shut with nothing coming to wake it.
  : > "$LAUNCHCTL_LOG"
  if LAUNCHCTL_FAIL=1 park --session sess-2 --cwd "$PHOME/proj" >/dev/null 2>&1; then
    bad "park.sh reports a refused bootstrap as a failure"
  else
    ok "park.sh reports a refused bootstrap as a failure"
  fi
  if [ ! -f "$PHOME/Library/LaunchAgents/com.llmdrive.budget-resume.sess-2.plist" ] &&
     [ ! -f "$PHOME/.claude/budget-run/parked-sess-2" ]; then
    ok "park.sh leaves nothing behind when launchd refuses"
  else
    bad "park.sh leaves nothing behind when launchd refuses"
  fi
fi

# ---------------------------------------------------------------------------
group "Resuming — nudge a live session, relaunch a dead one, never unbounded"
# ---------------------------------------------------------------------------
# The regression: the first live firing hung for 35 minutes because
# `claude --bg --resume <id>` does not return while that session is still
# running — and a parked session is idle-but-alive, so that is the normal case.
# These assert the shape of what resume.sh runs, not just that it runs.
RHOME="$WORK/rhome"; mkdir -p "$RHOME/.claude/budget-run" "$RHOME/Library/LaunchAgents" "$RHOME/proj"
RSTUB="$WORK/rstub"; mkdir -p "$RSTUB"
cat > "$RSTUB/launchctl" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
# The stub answers `agents --json` from CLAUDE_STUB_ALIVE, so a test can say
# whether the parked session is still running, and records every other argv so a
# test can assert the shape of what resume.sh would have launched.
cat > "$RSTUB/claude" <<'STUBEOF'
#!/bin/bash
if [ "$1" = agents ]; then
  printf '[{"sessionId": "%s"}]\n' "${CLAUDE_STUB_ALIVE:-none}"
  exit 0
fi
printf '%s\n' "$@" > "$CLAUDE_STUB_ARGV"
[ -n "${CLAUDE_STUB_SLEEP:-}" ] && sleep "$CLAUDE_STUB_SLEEP"
exit 0
STUBEOF
# osascript is stubbed for the same reason launchctl is, and it matters more:
# resume.sh posts a real macOS notification on the live-session branch, so an
# unstubbed run put a notification — with a sound — into the Notification Centre
# of whoever ran the suite, once per run. A test suite may not do that. Recording
# the call instead turns the side effect into coverage.
cat > "$RSTUB/osascript" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$@" > "$OSASCRIPT_STUB_ARGV"
exit 0
STUBEOF
chmod +x "$RSTUB/launchctl" "$RSTUB/claude" "$RSTUB/osascript"
export CLAUDE_STUB_ARGV="$WORK/claude-argv.txt"
export OSASCRIPT_STUB_ARGV="$WORK/osascript-argv.txt"

run_resume() {                 # run_resume SESSION_ID
  # Separate statements on purpose: bash expands the whole word list of one
  # `local` before it assigns any of it, so a later item cannot read an earlier
  # one and `set -u` aborts on the reference.
  local sid=$1
  local env="$RHOME/.claude/budget-run/parked-$sid.env"
  local plist="$RHOME/Library/LaunchAgents/com.llmdrive.budget-resume.$sid.plist"
  : > "$plist"
  touch "$RHOME/.claude/budget-run/parked-$sid"
  printf 'SESSION=%s\nCWD=%s\nPROMPT=%s\nWAKE=%s\nLABEL=%s\nPLIST=%s\n' \
    "$sid" "$RHOME/proj" "Read HANDOFF.md and continue" "$(( $(date +%s) - 10 ))" \
    "com.llmdrive.budget-resume.$sid" "$plist" > "$env"
  HOME="$RHOME" PATH="$RSTUB:$PATH" bash "$ROOT/modules/budget/resume.sh" "$env" \
    >> "$RHOME/.claude/budget-resume.log" 2>&1
}

# The parked session is STILL ALIVE — the normal case, since parking ends a turn
# and gates the tools rather than exiting anything. Its context is the expensive
# thing and must not be thrown away: clear the gate, tell the person, launch
# nothing.
rm -f "$CLAUDE_STUB_ARGV" "$OSASCRIPT_STUB_ARGV"; : > "$RHOME/.claude/budget-resume.log"
CLAUDE_STUB_ALIVE=sess-alive run_resume sess-alive
if [ -f "$OSASCRIPT_STUB_ARGV" ]; then
  case "$(cat "$OSASCRIPT_STUB_ARGV")" in
    *"display notification"*"drive budget"*) ok "it notifies the person, since nothing can type into a live session for them" ;;
    *) bad "it notifies the person" "$(cat "$OSASCRIPT_STUB_ARGV")" ;;
  esac
else
  bad "it notifies the person, since nothing can type into a live session for them" "osascript was never called"
fi
if [ ! -f "$CLAUDE_STUB_ARGV" ]; then
  ok "a session that is still running is not relaunched"
else
  bad "a session that is still running is not relaunched" "$(cat "$CLAUDE_STUB_ARGV" | tr '\n' ' ')"
fi
if [ ! -f "$RHOME/.claude/budget-run/parked-sess-alive" ]; then
  ok "and its gate is cleared, so one keystroke continues it with its context intact"
else
  bad "and its gate is cleared, so one keystroke continues it with its context intact"
fi
if grep -q "still running" "$RHOME/.claude/budget-resume.log"; then
  ok "and the log says why nothing was launched"
else
  bad "and the log says why nothing was launched" "$(cat "$RHOME/.claude/budget-resume.log")"
fi

# The parked session is GONE — unattended continuation is still wanted, and
# HANDOFF.md is what carries the work across.
rm -f "$CLAUDE_STUB_ARGV"; : > "$RHOME/.claude/budget-resume.log"
run_resume sess-r1
if [ -f "$CLAUDE_STUB_ARGV" ]; then
  ARGV="$(cat "$CLAUDE_STUB_ARGV")"
  case $ARGV in
    *--resume*) bad "resume.sh does not pass --resume" "argv was: $(echo "$ARGV" | tr '\n' ' ')" ;;
    *) ok "resume.sh does not pass --resume" ;;
  esac
  case $ARGV in
    *--bg*) ok "resume.sh starts a background session" ;;
    *) bad "resume.sh starts a background session" "$ARGV" ;;
  esac
  case $ARGV in
    *HANDOFF.md*) ok "the prompt it starts with names HANDOFF.md, which carries the work across" ;;
    *) bad "the prompt it starts with names HANDOFF.md" "$ARGV" ;;
  esac
else
  bad "resume.sh invoked claude at all"
  bad "resume.sh starts a background session"
  bad "the prompt it starts with names HANDOFF.md"
fi
RLOG="$RHOME/.claude/budget-resume.log"
if grep -q "claude exited 0" "$RLOG"; then ok "it logs the exit status it saw"
else bad "it logs the exit status it saw" "$(cat "$RLOG")"; fi
if [ ! -f "$RHOME/.claude/budget-run/parked-sess-r1" ]; then ok "it clears the gate marker"
else bad "it clears the gate marker"; fi
if [ ! -f "$RHOME/Library/LaunchAgents/com.llmdrive.budget-resume.sess-r1.plist" ]; then
  ok "it removes its own launch agent so it cannot fire twice"
else
  bad "it removes its own launch agent so it cannot fire twice"
fi
if [ ! -f "$RHOME/.claude/budget-run/parked-sess-r1.env" ]; then ok "it removes its env file"
else bad "it removes its env file"; fi

# The poll loop's normal path: a command that takes a moment is waited for, not
# abandoned. The 60s ceiling itself is deliberately not exercised here — a test
# that waits a minute would not get run.
: > "$RLOG"; rm -f "$CLAUDE_STUB_ARGV"
CLAUDE_STUB_SLEEP=3 run_resume sess-r2
if grep -q "claude exited 0" "$RLOG"; then ok "a slow start is waited for rather than killed"
else bad "a slow start is waited for rather than killed" "$(cat "$RLOG")"; fi

# A firing too early to be clock jitter starts nothing and leaves the gate shut.
: > "$RLOG"; rm -f "$CLAUDE_STUB_ARGV"
early_fire() {                 # early_fire SESSION SECONDS_EARLY
  local sid=$1
  local secs=$2
  local env="$RHOME/.claude/budget-run/parked-$sid.env"
  touch "$RHOME/.claude/budget-run/parked-$sid"
  printf 'SESSION=%s\nCWD=%s\nPROMPT=Read HANDOFF.md\nWAKE=%s\nLABEL=l\nPLIST=\n' \
    "$sid" "$RHOME/proj" "$(( $(date +%s) + secs ))" > "$env"
  HOME="$RHOME" PATH="$RSTUB:$PATH" bash "$ROOT/modules/budget/resume.sh" "$env" >> "$RLOG" 2>&1
}
early_fire sess-r3 600
if [ ! -f "$CLAUDE_STUB_ARGV" ] && [ -f "$RHOME/.claude/budget-run/parked-sess-r3" ]; then
  ok "a firing too early to be jitter starts nothing and leaves the gate closed"
else
  bad "a firing too early to be jitter starts nothing and leaves the gate closed" "$(cat "$RLOG")"
fi

# A firing early by seconds waits it out. Exiting here is what stranded the work
# on the first live firing: launchd's StartCalendarInterval has minute
# granularity, so it fires at the top of the minute and never fires again.
: > "$RLOG"; rm -f "$CLAUDE_STUB_ARGV"
early_fire sess-r4 4
if [ -f "$CLAUDE_STUB_ARGV" ]; then
  ok "a firing early by seconds is waited out rather than abandoned"
else
  bad "a firing early by seconds is waited out rather than abandoned" "$(cat "$RLOG")"
fi

# ---------------------------------------------------------------------------
group "Sidecar — pricing a run without floating point"
# ---------------------------------------------------------------------------
# The money helpers are pure and are pulled straight out of the shipped script,
# so these test the code that runs rather than a copy of it.
SC="$ROOT/modules/sidecar/sidecar.sh"
SCHOME="$WORK/schome"; mkdir -p "$SCHOME/.claude"
sc_fns() {
  SELF_DIR="$ROOT/modules/sidecar" LEDGER="$SCHOME/.claude/sidecar-ledger" \
  bash -c '
    set -u
    SELF_DIR="'"$ROOT/modules/sidecar"'"; LEDGER="'"$SCHOME/.claude/sidecar-ledger"'"; BALANCE="'"$SCHOME/.claude/sidecar-balance"'"
    die() { echo "die: $1" >&2; exit 9; }
    eval "$(/usr/bin/sed -n "/^_conf()/,/^}/p;/^_price()/,/^}/p;/^_to_micro()/,/^}/p;/^_billed_mtd()/,/^}/p;/^_price_age()/,/^}/p;/^_usage()/,/^}/p;/^_field()/,/^}/p;/^_usd()/,/^}/p;/^_month_to_date()/,/^}/p" "'"$SC"'")"
    '"$1"'
  '
}

# The collision that the first version of this had: the obvious call names the
# caller's variables miss/cached/out, which are exactly what the function used
# for its own locals, so eval assigned the locals and the caller got nothing.
printf '{"x":1,"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":7}}\n{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":2,"output_tokens":3}}\n' > "$WORK/tr.jsonl"
assert_eq "16 102 10" "$(sc_fns '_usage miss cached out "'"$WORK/tr.jsonl"'"; echo "$miss $cached $out"')" \
  "token counts survive being returned into the caller's own variable names"

# A transcript records the same assistant message more than once — 21 usage
# records against 13 distinct ids in the run that exposed this — so summing
# every "usage" billed several responses twice and the first ledger figures were
# about double. The number failed a sniff test before any test did: a one-line
# function does not cost 1.35 million tokens.
{ printf '{"message":{"id":"msg_A","usage":{"input_tokens":10,"cache_read_input_tokens":100,"output_tokens":7}}}\n'
  printf '{"message":{"id":"msg_A","usage":{"input_tokens":10,"cache_read_input_tokens":100,"output_tokens":7}}}\n'
  printf '{"message":{"id":"msg_B","usage":{"input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3}}}\n'
} > "$WORK/tr-dup.jsonl"
assert_eq "11 102 10" "$(sc_fns '_usage m c o "'"$WORK/tr-dup.jsonl"'"; echo "$m $c $o"')" \
  "a response recorded twice is billed once"
# Dropping an id-less record would understate, and understating spend is worse.
{ printf '{"message":{"id":"msg_A","usage":{"input_tokens":10,"cache_read_input_tokens":0,"output_tokens":1}}}\n'
  printf '{"usage":{"input_tokens":5,"cache_read_input_tokens":0,"output_tokens":1}}\n'
} > "$WORK/tr-noid.jsonl"
assert_eq "15 0 2" "$(sc_fns '_usage m c o "'"$WORK/tr-noid.jsonl"'"; echo "$m $c $o"')" \
  "a record with no message id is still counted, since understating spend is worse"

assert_eq "300000 6000 1200000" "$(sc_fns '_price a b c deepseek deepseek-flash; echo "$a $b $c"')" \
  "a price is read out of prices.conf"

# Nothing can fetch prices: the provider's /models returns only id, object and
# owned_by, and every billing or usage endpoint probed returns 404. So the table
# is maintained by hand, and its age is the only defence against believing a
# stale number.
AGE_SHIPPED="$(sc_fns "_price_age a; echo \$a")"
case $AGE_SHIPPED in ""|-1|*[!0-9]*) bad "the shipped price table carries a parseable checked date" "got [$AGE_SHIPPED]" ;; *) ok "the shipped price table carries a parseable checked date ($AGE_SHIPPED days)" ;; esac
SCT="$WORK/prices-stale"; mkdir -p "$SCT"
/usr/bin/sed 's/^checked .*/checked 2026-01-01/' "$ROOT/modules/sidecar/prices.conf" > "$SCT/prices.conf"
assert_eq 253 "$(SELF_DIR="$SCT" bash -c '
  SELF_DIR="'"$SCT"'"; die(){ exit 1; }
  eval "$(/usr/bin/sed -n "/^_price_age()/,/^}/p" "'"$SC"'")"
  _price_age a; echo $a')" "an older stamp reports its age in days"
/usr/bin/sed '/^checked/d' "$SCT/prices.conf" > "$SCT/p2" && mv "$SCT/p2" "$SCT/prices.conf"
assert_eq -1 "$(SELF_DIR="$SCT" bash -c '
  SELF_DIR="'"$SCT"'"; die(){ exit 1; }
  eval "$(/usr/bin/sed -n "/^_price_age()/,/^}/p" "'"$SC"'")"
  _price_age a; echo $a')" "and a table with no stamp reports unknown rather than fresh"
assert_eq 9 "$(sc_fns '_price a b c deepseek nope 2>/dev/null; echo ok' >/dev/null 2>&1; echo $?)" \
  "an unpriced model is refused rather than guessed at"

for pair in "0 0.00" "4999 0.00" "5000 0.01" "999500 1.00" "1000000 1.00" "1999999 2.00" "80000001 80.00"; do
  set -- $pair
  assert_eq "$2" "$(sc_fns "_usd d $1; echo \$d")" "micro-USD $1 renders as \$$2"
done

printf '%s deepseek deepseek-flash 1 2 3 1500000 s1\n2026-08-01T10:00:00 deepseek deepseek-flash 1 2 3 9000000 s0\n' \
  "$(date +%Y-%m)-12T10:00:00" > "$SCHOME/.claude/sidecar-ledger"
assert_eq 1500000 "$(sc_fns '_month_to_date t; echo $t')" "the ledger totals this month and ignores older rows"

# The provider exposes no cost endpoint, so what was really spent can only be
# learned by watching the balance fall. These are the sums that turns readings
# into a figure.
for pair in "4.99 4990000" "5 5000000" "0.003 3000" "10.000001 10000001" "4.9 4900000"; do
  set -- $pair
  assert_eq "$2" "$(sc_fns "_to_micro m $1; echo \$m")" "a balance of $1 reads as $2 micro-USD"
done
BM="$(date +%Y-%m)"
printf '%s-01T10:00:00 deepseek 5000000\n%s-02T10:00:00 deepseek 4970000\n%s-03T10:00:00 deepseek 9970000\n%s-04T10:00:00 deepseek 9900000\n' \
  "$BM" "$BM" "$BM" "$BM" > "$SCHOME/.claude/sidecar-balance"
# Falls only. First-minus-last would read the top-up as the month costing less.
assert_eq 100000 "$(sc_fns '_billed_mtd t; echo $t')" "spend counts the falls, so a top-up does not read as negative"
printf '%s-01T10:00:00 deepseek 5000000\n' "$BM" > "$SCHOME/.claude/sidecar-balance"
assert_eq 1 "$(sc_fns '_billed_mtd t >/dev/null; echo $?' 2>/dev/null)" \
  "one reading is refused, because one reading is a number and not a measurement"
rm -f "$SCHOME/.claude/sidecar-balance"

# ---------------------------------------------------------------------------
group "Sidecar — refusals, and the credential never reaching a command line"
# ---------------------------------------------------------------------------
SCSTUB="$WORK/scstub"; mkdir -p "$SCSTUB" "$SCHOME/repo"
# start calls claude twice — once to launch, then `agents --json` to learn the
# session id — so the stub records only the launch. Recording both overwrote the
# launch argv with "agents --json" and the assertions below tested nothing.
cat > "$SCSTUB/claude" <<'STUBEOF'
#!/bin/bash
if [ "$1" = agents ]; then echo '[]'; exit 0; fi
printf '%s\n' "$@" > "$CLAUDE_ARGV"
env > "$CLAUDE_ENV"
echo "backgrounded · abcd1234 · $3"
exit 0
STUBEOF
chmod +x "$SCSTUB/claude"
# curl is stubbed because start now checks the credential against the provider
# before launching anything. CURL_CODE is the HTTP status the provider "returns".
cat > "$SCSTUB/curl" <<'STUBEOF'
#!/bin/bash
printf '%s' "${CURL_CODE:-200}"
exit 0
STUBEOF
chmod +x "$SCSTUB/curl"
export CLAUDE_ARGV="$WORK/sc-argv.txt" CLAUDE_ENV="$WORK/sc-env.txt" CURL_CODE=200
sc() { ( cd "${SC_CWD:-$SCHOME/repo}" && HOME="$SCHOME" PATH="$SCSTUB:$PATH" bash "$SC" "$@" ) 2>&1; }

rm -f "$SCHOME/.claude/sidecar-mode"
case "$(sc start --task x)" in
  *"sidecar mode is off"*) ok "start refuses while the module is switched off" ;;
  *) bad "start refuses while the module is switched off" "$(sc start --task x)" ;;
esac
touch "$SCHOME/.claude/sidecar-mode"
case "$(sc start)" in
  *"needs --task"*) ok "start refuses without a task" ;;
  *) bad "start refuses without a task" ;;
esac
case "$(sc start --task x --provider nosuch)" in
  *"no profile at"*) ok "start refuses a provider it has no profile for" ;;
  *) bad "start refuses a provider it has no profile for" ;;
esac
rm -f "$SCHOME/.claude/sidecar-credentials"
case "$(sc start --task x)" in
  *"no credential file"*) ok "start refuses when the credential file is missing" ;;
  *) bad "start refuses when the credential file is missing" ;;
esac
printf 'DEEPSEEK_API_KEY=sk-test-not-a-real-key\n' > "$SCHOME/.claude/sidecar-credentials"
case "$(sc start --task x)" in
  *"not in a git repository"*) ok "start refuses outside a git repository, since work comes back as a branch" ;;
  *) bad "start refuses outside a git repository" "$(sc start --task x)" ;;
esac

git -C "$SCHOME/repo" init -q 2>/dev/null

# One worker at a time, by decision: with one, the orchestrator reviews each
# result before the next task starts. It was a decision nothing enforced.
mkdir -p "$SCHOME/.claude/sidecar-run"
printf 'worker=already-out\nsession=s\n' > "$SCHOME/.claude/sidecar-run/already-out.env"
rm -f "$CLAUDE_ARGV"
OUT="$(sc start --task x)"
case $OUT in
  *"already out"*"One at a time"*) ok "a second worker is refused while one is still out" ;;
  *) bad "a second worker is refused while one is still out" "$OUT" ;;
esac
if [ ! -f "$CLAUDE_ARGV" ]; then ok "and nothing is launched"; else bad "and nothing is launched"; fi
rm -f "$SCHOME/.claude/sidecar-run/already-out.env"

# A real hook of the repository's own, so the carry-over assertion below has
# something to carry and cannot pass vacuously.
printf '#!/bin/sh\nexit 0\n' > "$SCHOME/repo/.git/hooks/pre-commit" 2>/dev/null
chmod +x "$SCHOME/repo/.git/hooks/pre-commit" 2>/dev/null

# The guard the module rests on. A background worker whose credential the
# provider rejects does NOT fail: Claude Code retries and falls back to the
# saved claude.ai login, finishing the work on the subscription and spending the
# windows this module exists to protect. Measured — a worker launched with a
# deliberately wrong key logged three 401s and completed the task anyway. So the
# credential is checked before anything is launched, and a launch that cannot be
# checked is refused rather than risked.
rm -f "$CLAUDE_ARGV"
CURL_CODE=401 sc start --task x >/dev/null 2>&1
if [ ! -f "$CLAUDE_ARGV" ]; then ok "a credential the provider rejects stops the launch"
else bad "a credential the provider rejects stops the launch" "it launched anyway"; fi
case "$(CURL_CODE=401 sc start --task x)" in
  *"finishes the work on your claude.ai subscription"*) ok "and says why, in terms of what it would have cost" ;;
  *) bad "and says why" "$(CURL_CODE=401 sc start --task x)" ;;
esac
rm -f "$CLAUDE_ARGV"
CURL_CODE=000 sc start --task x >/dev/null 2>&1
if [ ! -f "$CLAUDE_ARGV" ]; then ok "an unreachable provider stops the launch too, rather than risking it"
else bad "an unreachable provider stops the launch too"; fi
rm -f "$CLAUDE_ARGV"
CURL_CODE=500 sc start --task x >/dev/null 2>&1
if [ ! -f "$CLAUDE_ARGV" ]; then ok "so does any answer that is not a plain 200"
else bad "so does any answer that is not a plain 200"; fi

rm -f "$CLAUDE_ARGV" "$CLAUDE_ENV"
sc start --task 'write a thing' >/dev/null
if [ -f "$CLAUDE_ARGV" ]; then
  # The credential must travel in the environment and nowhere else. On the
  # command line it would sit in `ps` for every account on the machine to read.
  if grep -q 'sk-test-not-a-real-key' "$CLAUDE_ARGV"; then
    bad "the credential never reaches claude's command line" "$(cat "$CLAUDE_ARGV")"
  else
    ok "the credential never reaches claude's command line"
  fi
  if grep -q 'ANTHROPIC_AUTH_TOKEN=sk-test-not-a-real-key' "$CLAUDE_ENV"; then
    ok "it travels in the environment instead"
  else
    bad "it travels in the environment instead"
  fi
  if grep -q 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' "$CLAUDE_ENV"; then
    ok "and the base URL comes from the provider profile"
  else
    bad "and the base URL comes from the provider profile"
  fi
  # The same pair also rides in a settings file, because a --bg session does not
  # always take it from the environment (measured 2026-09-13, D14). A file and
  # not a JSON literal, so the command-line assertion above still holds.
  SETTINGS_ARG=$(/usr/bin/grep -A1 -x -- '--settings' "$CLAUDE_ARGV" 2>/dev/null | tail -1)
  case $SETTINGS_ARG in
    "$SCHOME/.claude/sidecar-run/sidecar-"*.settings.json)
      ok "--settings names a file beside the worker's records, since a --bg session may ignore its environment" ;;
    *) bad "--settings names a file beside the worker's records" "got [$SETTINGS_ARG]" ;;
  esac
  if [ -f "$SETTINGS_ARG" ] \
     && grep -q '"ANTHROPIC_AUTH_TOKEN":"sk-test-not-a-real-key"' "$SETTINGS_ARG" \
     && grep -q '"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic"' "$SETTINGS_ARG"; then
    ok "and that file carries the credential and the base URL in a settings env block"
  else
    bad "the settings file carries the credential and the base URL" "$(cat "$SETTINGS_ARG" 2>/dev/null)"
  fi
  [ -f "$SETTINGS_ARG" ] && assert_json "$SETTINGS_ARG" "and it is valid JSON"
  SETTINGS_MODE=$(stat -f '%Lp' "$SETTINGS_ARG" 2>/dev/null || stat -c '%a' "$SETTINGS_ARG" 2>/dev/null)
  assert_eq 600 "$SETTINGS_MODE" "and it is readable by this user alone"
  # A value with a quote or a backslash in it must not break the file. Written by
  # the same helper the launcher uses, read back by an independent parser.
  if [ "$HAVE_PY" = 1 ]; then
    ESC_FN=$(/usr/bin/sed -n '/^_json_string() {/,/^}/p' "$SC")
    printf '{"env":{"K":"%s"}}\n' "$(bash -c "$ESC_FN"'; _json_string "$1"' _ 'a"b\\c')" > "$WORK/esc.json"
    ESC_BACK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["env"]["K"])' "$WORK/esc.json" 2>/dev/null)
    assert_eq 'a"b\\c' "$ESC_BACK" "a credential with a quote and a backslash survives the JSON escaping"
  else
    skip "the JSON escaping round trip (no python3 to validate with)"
  fi
  ARGV="$(cat "$CLAUDE_ARGV" | tr '\n' ' ')"
  case $ARGV in
    *"--model sonnet"*) ok "--model is the provider profile's Claude alias, never its own model id" ;;
    *) bad "--model is the provider profile's Claude alias" "$ARGV" ;;
  esac
  case $ARGV in
    *"--permission-mode auto"*) ok "and the permission mode is not narrowed below the orchestrator's" ;;
    *) bad "and the permission mode is not narrowed" "$ARGV" ;;
  esac
  # The value of --model specifically, not "anywhere in argv": the brief names
  # the real model on purpose now, so a whole-argv search would find it there.
  MODEL_ARG=$(/usr/bin/grep -A1 -x -- '--model' "$CLAUDE_ARGV" 2>/dev/null | tail -1)
  case $MODEL_ARG in
    sonnet) ok "the value of --model is a Claude alias, never the provider's own id" ;;
    *) bad "the value of --model is a Claude alias" "got [$MODEL_ARG]" ;;
  esac
  # Workers told "Commit it. Nothing else." attempted git push four times each.
  # Only the absence of a remote made that harmless; a worker inherits the
  # orchestrator's permissions, so in a real repository it would have published
  # unreviewed work unattended.
  # Asserted as "passed", not as "works". A worker with the colon-form rule
  # `Bash(git push:*)` pushed to a real remote anyway — verified against a bare
  # repository, which received the commit — so the flag's effect is UNPROVEN and
  # the brief below is what this actually relies on. Do not upgrade this wording
  # without a test that puts a remote in front of a worker and finds it empty.
  case $ARGV in
    *'--disallowed-tools Bash(git push'*) ok "a deny rule for push is passed (its effect is unproven — see DESIGN §10c)" ;;
    *) bad "a deny rule for push is passed" "$ARGV" ;;
  esac
  case $ARGV in
    *"--append-system-prompt"*"deepseek-flash"*"Do not describe yourself as a Claude model"*"Do not push"*)
      ok "the brief names the real model and rides in the system prompt, not in front of the task" ;;
    *) bad "the hand-off brief rides in the system prompt (prepending it left the session with an empty prompt)" "$ARGV" ;;
  esac
  case $ARGV in
    *"--append-system-prompt"*"Do not push"*"Rules of engagement for deepseek-flash on deepseek:"*"Run the tests you touch"*)
      ok "the provider's Worker rules follow the brief in the system prompt" ;;
    *) bad "the provider's Worker rules follow the brief in the system prompt" "$ARGV" ;;
  esac
  # The guard that actually holds. GIT_CONFIG_* is inherited by any git process
  # however it is spelled, so unlike a permission rule it is not defeated by
  # `git -C .`, `git -c …`, an absolute path, or `sh -c`.
  if grep -q 'GIT_CONFIG_KEY_0=core.hooksPath' "$CLAUDE_ENV" 2>/dev/null; then
    ok "a hooks path is injected into the worker's environment"
  else
    bad "a hooks path is injected into the worker's environment"
  fi
  GUARD=$(/usr/bin/sed -n 's/^GIT_CONFIG_VALUE_0=//p' "$CLAUDE_ENV" 2>/dev/null)
  if [ -n "$GUARD" ] && [ -x "$GUARD/pre-push" ] && ! "$GUARD/pre-push" 2>/dev/null; then
    ok "and it holds an executable pre-push that refuses"
  else
    bad "and it holds an executable pre-push that refuses" "guard=$GUARD"
  fi
  # stop takes the settings file with the worker's other records: it holds the
  # credential, and nothing reads it once the session is gone. On a record of
  # its own, because the next group inspects the launched worker's guard dir.
  printf 'worker=w-stop\nprovider=deepseek\nmodel=deepseek-flash\nsession=\nrepo=%s\n' "$SCHOME/repo" \
    > "$SCHOME/.claude/sidecar-run/w-stop.env"
  printf '{"env":{}}\n' > "$SCHOME/.claude/sidecar-run/w-stop.settings.json"
  sc stop --worker w-stop >/dev/null 2>&1
  if [ ! -e "$SCHOME/.claude/sidecar-run/w-stop.settings.json" ] && [ ! -e "$SCHOME/.claude/sidecar-run/w-stop.env" ]; then
    ok "stop removes the settings file along with the worker's record"
  else
    bad "stop removes the settings file along with the worker's record" "$(ls "$SCHOME/.claude/sidecar-run")"
  fi
fi

# ---------------------------------------------------------------------------
group "Sidecar — the push guard, against the forms a permission rule misses"
# ---------------------------------------------------------------------------
# The permissions reference names Bash(git push *) as its own example of a
# rule's limits: it misses `git -C . push`, `git -c … push` and `git 'push'`.
# A worker did push past that rule to a real remote. These are the same forms,
# against the git-level guard.
if [ -n "${GUARD:-}" ] && [ -x "$GUARD/pre-push" ]; then
  GW="$WORK/gitguard"; mkdir -p "$GW"
  ( cd "$GW" && git init -q && git init -q --bare r.git && git remote add origin "$GW/r.git" \
      && printf 'x\n' > a && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) 2>/dev/null
  pushed=0
  for form in "git push origin HEAD:main" \
              "git -C $GW push origin HEAD:main" \
              "$(command -v git) push origin HEAD:main" \
              "sh -c 'git push origin HEAD:main'" \
              "git -c push.default=current push origin HEAD:main"; do
    ( cd "$GW" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$GUARD" \
        eval "$form" ) >/dev/null 2>&1
    n=$(git -C "$GW/r.git" log --oneline --all 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" != 0 ] && pushed=1
  done
  if [ "$pushed" = 0 ]; then
    ok "every invocation form a permission rule misses is still refused"
  else
    bad "every invocation form a permission rule misses is still refused" "something reached the remote"
  fi
  # The repo's own hooks must survive, because core.hooksPath replaces the hooks
  # directory rather than adding to it. Asserted by following the link to a real
  # file: the first version of this test asked "does the guard have a pre-commit
  # OR does the repo lack one", which this repository satisfies trivially, and it
  # passed while every carried-over link was in fact dangling.
  if [ -e "$GUARD/pre-commit" ]; then
    ok "the repository's own hooks are carried into the guard directory"
  else
    bad "the repository's own hooks are carried into the guard directory" "no pre-commit in $GUARD"
  fi
  if [ -s "$GUARD/pre-commit" ]; then
    ok "and the link resolves to the real hook rather than dangling"
  else
    bad "and the link resolves to the real hook rather than dangling" "$(ls -l "$GUARD/pre-commit" 2>&1)"
  fi
else
  skip "every invocation form a permission rule misses is still refused (no guard dir)"
  skip "the repository's own hooks are carried into the guard directory"
fi

# ---------------------------------------------------------------------------
group "Sidecar — the PreToolUse guard on worker sessions"
# ---------------------------------------------------------------------------
GHOME="$WORK/ghome"; mkdir -p "$GHOME/.claude/sidecar-run"
printf 'worker=w1\nprovider=deepseek\nmodel=deepseek-flash\nsession=sess-worker\nrepo=/tmp\n' \
  > "$GHOME/.claude/sidecar-run/w1.env"
guard() {                      # guard SESSION TOOL COMMAND
  printf '{"session_id":"%s","tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2" "$3" \
    | HOME="$GHOME" bash "$ROOT/modules/sidecar/guard.sh"
}
gdecision() {
  [ "$HAVE_PY" = 1 ] || return 1
  python3 -c '
import json,sys
s=sys.stdin.read().strip()
print("silent" if not s else json.loads(s)["hookSpecificOutput"].get("permissionDecision","?"))'
}
assert_eq deny   "$(guard sess-worker Bash 'git push origin main' | gdecision)"  "a worker pushing is denied"
assert_eq deny   "$(guard sess-worker Bash 'git -C . push origin x' | gdecision)" "and so is the form the permission rule misses"
assert_eq silent "$(guard sess-worker Bash 'git commit -m x' | gdecision)"       "a worker committing is left alone"
assert_eq silent "$(guard sess-worker Read 'anything' | gdecision)"              "non-Bash tools are left alone"
# The gate must do nothing in an ordinary session. It runs in every one.
assert_eq silent "$(guard some-other-session Bash 'git push origin main' | gdecision)" \
  "a session that is not a worker pushes freely — this hook runs in all of them"
rm -f "$GHOME/.claude/sidecar-run/w1.env"
assert_eq silent "$(guard sess-worker Bash 'git push origin main' | gdecision)" \
  "and with no worker records at all it stays silent rather than guessing"
# The launch assertions above are inside `if [ -f "$CLAUDE_ARGV" ]`, which is
# closed there. If the launch never happened, none of them ran, so say so once
# rather than leaving a silently short run.
if [ ! -f "$CLAUDE_ARGV" ]; then
  bad "the worker was launched at all (every launch assertion above was skipped)"
fi

# A credential can also stop working part-way through a run, which the preflight
# cannot see. collect refuses to price such a run rather than record the
# subscription's tokens as the provider's pennies.
mkdir -p "$SCHOME/.claude/projects/p"
printf '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":5}}}\n{"error":"authentication_error"}\n' \
  > "$SCHOME/.claude/projects/p/sess-401.jsonl"
printf 'worker=w401\nprovider=deepseek\nmodel=deepseek-flash\nsession=sess-401\nrepo=%s\n' "$SCHOME/repo" \
  > "$SCHOME/.claude/sidecar-run/w401.env" 2>/dev/null || { mkdir -p "$SCHOME/.claude/sidecar-run"; printf 'worker=w401\nprovider=deepseek\nmodel=deepseek-flash\nsession=sess-401\nrepo=%s\n' "$SCHOME/repo" > "$SCHOME/.claude/sidecar-run/w401.env"; }
OUT="$(sc collect --worker w401)"
case $OUT in
  *"authentication error"*) ok "collect refuses to price a run that hit an authentication error" ;;
  *) bad "collect refuses to price a run that hit an authentication error" "$OUT" ;;
esac
if [ ! -s "$SCHOME/.claude/sidecar-ledger" ] || ! grep -q sess-401 "$SCHOME/.claude/sidecar-ledger" 2>/dev/null; then
  ok "and writes no ledger row for it"
else
  bad "and writes no ledger row for it"
fi

# ---------------------------------------------------------------------------
group "Sidecar — a provider that is not DeepSeek, and does not bill in money"
# ---------------------------------------------------------------------------
# The whole module is meant to be provider-agnostic, and the case that proves it
# is a self-hosted model: a different endpoint, a different model id, and no cost
# per token at all. `collect` used to die on "no price for …" for exactly this,
# which made a self-hosted endpoint unusable however agnostic everything else was.
SCP="$SCHOME/.claude/providers-alt"; mkdir -p "$SCP"
cat > "$SCP/selfhosted.conf" <<'PROF'
base_url=http://127.0.0.1:8080/anthropic
cred_var=ANTHROPIC_API_KEY
cred_key=SELFHOSTED_TOKEN
model=my-local-model
model_alias=sonnet
billing=none
PROF
assert_eq "http://127.0.0.1:8080/anthropic" \
  "$(sc_fns '_conf u "'"$SCP/selfhosted.conf"'" base_url; echo "$u"')" \
  "a profile with its own base URL reads back"
assert_eq none "$(sc_fns '_conf b "'"$SCP/selfhosted.conf"'" billing; echo "$b"')" \
  "and can declare that it does not bill per token"
# No balance endpoint either: the keys are simply absent and sampling degrades.
assert_eq 1 "$(sc_fns '_conf x "'"$SCP/selfhosted.conf"'" balance_url >/dev/null; echo $?')" \
  "a provider with no balance endpoint reports absence rather than failing"

# The cap is no longer baked into the script, because a provider billed in
# machine time rather than dollars is the case this is meant to grow into.
printf 'CAP_USD=25\n' > "$SCHOME/.claude/sidecar-config"
assert_eq 25 "$(HOME="$SCHOME" bash -c 'eval "$(/usr/bin/sed -n "/^CONFIG=/,/^fi$/p" "'"$SC"'")"; echo $CAP_USD')" \
  "the spend cap is read from sidecar-config"
printf 'CAP_USD=not-a-number\n' > "$SCHOME/.claude/sidecar-config"
assert_eq 80 "$(HOME="$SCHOME" bash -c 'eval "$(/usr/bin/sed -n "/^CONFIG=/,/^fi$/p" "'"$SC"'")"; echo $CAP_USD')" \
  "and a non-numeric cap falls back to the default rather than breaking arithmetic"
rm -f "$SCHOME/.claude/sidecar-config"

# End to end, because the config read alone would not have caught the bug: the
# module is copied somewhere its SELF_DIR resolves to a provider set with no
# DeepSeek in it at all, and collect is run against a self-hosted provider that
# bills nothing.
ALT="$WORK/altmod"; mkdir -p "$ALT/providers"
cp "$SC" "$ALT/sidecar.sh"; cp "$ROOT/modules/sidecar/prices.conf" "$ALT/prices.conf"
cp "$SCP/selfhosted.conf" "$ALT/providers/selfhosted.conf"
mkdir -p "$SCHOME/.claude/projects/alt" "$SCHOME/.claude/sidecar-run"
printf '{"type":"assistant","message":{"id":"msg_A","usage":{"input_tokens":11,"cache_read_input_tokens":22,"output_tokens":33}}}\n' \
  > "$SCHOME/.claude/projects/alt/sess-alt.jsonl"
printf 'worker=walt\nprovider=selfhosted\nmodel=my-local-model\nsession=sess-alt\nrepo=%s\n' "$SCHOME/repo" \
  > "$SCHOME/.claude/sidecar-run/walt.env"
OUT="$(cd "$SCHOME/repo" && HOME="$SCHOME" PATH="$SCSTUB:$PATH" bash "$ALT/sidecar.sh" collect --worker walt 2>&1)"
case $OUT in
  *"no per-token cost"*) ok "collect reports a self-hosted run instead of dying on a missing price" ;;
  *) bad "collect reports a self-hosted run instead of dying on a missing price" "$OUT" ;;
esac
case $OUT in
  *"in 11 (+22 cached)"*"out 33"*) ok "and still counts the tokens, which are the part that transfers" ;;
  *) bad "and still counts the tokens" "$OUT" ;;
esac
if ! grep -q selfhosted "$SCHOME/.claude/sidecar-ledger" 2>/dev/null; then
  ok "and writes no money row for a provider that charges none"
else
  bad "and writes no money row for a provider that charges none"
fi
rm -f "$SCHOME/.claude/sidecar-run/walt.env"

# ---------------------------------------------------------------------------
group "Sidecar — rules of engagement per provider"
# ---------------------------------------------------------------------------
RULES_FIX="$WORK/fixture.rules.md"
printf '# title\n\nprose nobody reads\n\n## Orchestrator\n\n- first rule\n- second rule\n\n\n## Worker\n- be terse\n\n## Notes\nignored\n' > "$RULES_FIX"
rules_fn() { bash -c 'set -u; eval "$(/usr/bin/sed -n "/^_rules_section()/,/^}/p" "'"$SC"'")"; '"$1"; }
assert_eq "- first rule
- second rule" "$(rules_fn '_rules_section r "'"$RULES_FIX"'" Orchestrator; printf "%s" "$r"')" \
  "the Orchestrator section is read up to the next heading, blank lines trimmed"
assert_eq "- be terse" "$(rules_fn '_rules_section r "'"$RULES_FIX"'" Worker; printf "%s" "$r"')" "and the Worker section likewise"
assert_eq 1 "$(rules_fn '_rules_section r "'"$RULES_FIX"'" Nope; echo $?')" "a missing section returns 1 rather than an empty string"
assert_eq 1 "$(rules_fn '_rules_section r "'"$WORK/absent.md"'" Worker; echo $?')" "and so does a missing file, so a provider without rules changes nothing"
printf '## Orchestrator\n\n\n## Worker\nx\n' > "$WORK/empty.rules.md"
assert_eq 1 "$(rules_fn '_rules_section r "'"$WORK/empty.rules.md"'" Orchestrator; echo $?')" "an empty section counts as absent"

# Every shipped rules file: both sections, and the per-prompt one short enough to ride every turn.
SHIPPED="$ROOT/modules/sidecar/providers/deepseek.rules.md"
for rf in "$ROOT"/modules/sidecar/providers/*.rules.md; do
  rname=${rf##*/}
  ORCH_LINES=$(rules_fn '_rules_section r "'"$rf"'" Orchestrator; printf "%s\n" "$r"' | wc -l | tr -d ' ')
  if [ "$ORCH_LINES" -ge 1 ] && [ "$ORCH_LINES" -le 15 ]; then ok "$rname: Orchestrator section is 1–15 lines ($ORCH_LINES)"
  else bad "$rname: Orchestrator section is 1–15 lines" "got $ORCH_LINES"; fi
  if rules_fn '_rules_section r "'"$rf"'" Worker' >/dev/null; then ok "$rname: has a Worker section"; else bad "$rname: has a Worker section"; fi
done

# `rules` prints the Orchestrator section; a provider without a profile is refused.
case "$(sc rules)" in
  *"deepseek (deepseek-flash)"*"One worker at a time is enforced"*) ok "rules prints the provider's Orchestrator section" ;;
  *) bad "rules prints the provider's Orchestrator section" "$(sc rules)" ;;
esac
case "$(sc rules --provider nosuch)" in
  *"no profile at"*) ok "rules refuses a provider with no profile" ;;
  *) bad "rules refuses a provider with no profile" "$(sc rules --provider nosuch)" ;;
esac

# on/off: the flag file carries the provider, and on refuses an unknown one.
case "$(sc on --provider nosuch)" in
  *"no profile at"*) ok "on refuses a provider with no profile" ;;
  *) bad "on refuses a provider with no profile" "$(sc on --provider nosuch)" ;;
esac
sc on --provider deepseek >/dev/null
assert_eq deepseek "$(cat "$SCHOME/.claude/sidecar-mode")" "on records the provider in the flag file"
sc on --provider '' >/dev/null
assert_eq deepseek "$(cat "$SCHOME/.claude/sidecar-mode")" "on with an empty name records the default"
# The flag's provider is the default for start and rules; a malformed line falls back.
printf 'kaggle-tpu\n' > "$SCHOME/.claude/sidecar-mode"
case "$(sc start --task x)" in
  *"no profile at"*"kaggle-tpu.conf"*) ok "start takes the provider from the flag file when --provider is absent" ;;
  *) bad "start takes the provider from the flag file" "$(sc start --task x)" ;;
esac
printf '../evil\n' > "$SCHOME/.claude/sidecar-mode"
case "$(sc rules)" in
  *"deepseek (deepseek-flash)"*) ok "a malformed flag line falls back to deepseek rather than becoming a path" ;;
  *) bad "a malformed flag line falls back to deepseek" "$(sc rules)" ;;
esac
sc off >/dev/null
if [ ! -e "$SCHOME/.claude/sidecar-mode" ]; then ok "off removes the flag"; else bad "off removes the flag"; fi
touch "$SCHOME/.claude/sidecar-mode"

# The hook: silent when off; header + Orchestrator section when on; names a worker that is out.
HHOME="$WORK/hhome"; mkdir -p "$HHOME/.claude/drive-sidecar/providers" "$HHOME/.claude/sidecar-run"
cp "$SHIPPED" "$HHOME/.claude/drive-sidecar/providers/deepseek.rules.md"
cp "$RULES_FIX" "$HHOME/.claude/drive-sidecar/providers/fix.rules.md"
assert_eq "" "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" "the sidecar hook prints nothing while the mode is off"
printf 'fix\n' > "$HHOME/.claude/sidecar-mode"
HOOK_OUT="$(HOME="$HHOME" PATH="" /bin/bash "$ROOT/hooks/sidecar-mode.sh" 2>/dev/null)"
assert_eq "SIDECAR MODE IS ON (provider fix; no worker out; turn off with /sidecar-off). Rules of engagement for dispatching to fix:
- first rule
- second rule" "$HOOK_OUT" "on: the hook names the provider and injects its Orchestrator section (bare PATH, pure bash)"
assert_eq "$(rules_fn '_rules_section r "'"$RULES_FIX"'" Orchestrator; printf "%s\n" "$r"')" "$(printf '%s\n' "$HOOK_OUT" | tail -n +2)" \
  "the hook's section reader agrees with sidecar.sh's on the same fixture"
printf 'worker=w-42\n' > "$HHOME/.claude/sidecar-run/w-42.env"
case "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" in
  "SIDECAR MODE IS ON (provider fix; worker w-42 is out"*) ok "with a worker out, the header says so" ;;
  *) bad "with a worker out, the header says so" "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" ;;
esac
printf 'roster=an other model, for the record\n' > "$HHOME/.claude/drive-sidecar/providers/other.conf"
printf 'model=x\n' > "$HHOME/.claude/drive-sidecar/providers/quiet.conf"
case "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" in
  *"- second rule"*"Other providers (start --provider NAME [--model SLUG]):"*"- other: an other model, for the record"*) ok "after the rules the hook lists the other providers' roster lines" ;;
  *) bad "after the rules the hook lists the other providers' roster lines" "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" ;;
esac
case "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" in *"- quiet:"*|*"- fix:"*) bad "a profile without roster=, and the active provider, are not listed" ;; *) ok "a profile without roster=, and the active provider, are not listed" ;; esac
rm -f "$HHOME/.claude/drive-sidecar/providers/other.conf" "$HHOME/.claude/drive-sidecar/providers/quiet.conf"
printf 'nosuch\n' > "$HHOME/.claude/sidecar-mode"
case "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" in
  *"no rules written for nosuch"*) ok "a provider without a rules file gets the header and a pointer, not a failure" ;;
  *) bad "a provider without a rules file gets the header and a pointer" ;;
esac
: > "$HHOME/.claude/sidecar-mode"
case "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" in
  "SIDECAR MODE IS ON (provider deepseek;"*"One worker at a time is enforced"*) ok "an empty flag means deepseek, the shipped rules" ;;
  *) bad "an empty flag means deepseek" "$(HOME="$HHOME" bash "$ROOT/hooks/sidecar-mode.sh")" ;;
esac

# ---------------------------------------------------------------------------
group "Sidecar — the Antigravity CLI as the worker (headless, in a worktree)"
# ---------------------------------------------------------------------------
# A stub `agy` that records argv and env, does a commit in its cwd (the
# worktree), prints the JSON envelope the real CLI prints for --output-format
# json (measured on agy 1.2.2), and exits 0. AGY_STUB_SLEEP makes it hang
# instead, for the stop test; AGY_STUB_QUOTA makes it fail with a quota error.
cat > "$SCSTUB/agy" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$@" > "$AGY_ARGV"
env > "$AGY_ENV"
pwd > "$AGY_CWD"
if [ -n "${AGY_STUB_SLEEP:-}" ]; then sleep "$AGY_STUB_SLEEP"; exit 0; fi
if [ -n "${AGY_STUB_NOUSAGE:-}" ]; then
  printf '%s\n' '{"conversation_id":"c3","status":"ERROR","response":"","error":"quota exceeded for this window"}'
  exit 1
fi
if [ -n "${AGY_STUB_STDERR:-}" ]; then
  echo "Error: model quota exhausted (stderr)" >&2
  exit 1
fi
if [ -n "${AGY_STUB_QUOTA:-}" ]; then
  printf '%s\n' '{"conversation_id":"c2","status":"ERROR","response":"","error":"model quota exhausted for this window; it refreshes at 18:00","duration_seconds":0.4,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}'
  exit 1
fi
echo "stub work" > done.txt
git add done.txt && git -c user.email=s@s -c user.name=stub commit -q -m "stub work"
printf '%s\n' '{"conversation_id":"c1","status":"SUCCESS","response":"Added done.txt and committed.\nTests: ok","error":"","duration_seconds":20.9,"num_turns":1,"usage":{"input_tokens":13051,"output_tokens":59,"thinking_tokens":58,"cache_read_tokens":20,"total_tokens":13110}}'
exit 0
STUBEOF
chmod +x "$SCSTUB/agy"
export AGY_ARGV="$WORK/a-argv.txt" AGY_ENV="$WORK/a-env.txt" AGY_CWD="$WORK/a-cwd.txt"
GREPO="$SCHOME/grepo"; mkdir -p "$GREPO"; git -C "$GREPO" init -q; git -C "$GREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# git answers with the physical path (/private/var on macOS), so compare against that
GREPO_P=$(cd "$GREPO" && pwd -P)
gsc() { ( cd "$GREPO" && HOME="$SCHOME" PATH="$SCSTUB:$PATH" bash "$SC" "$@" ) 2>&1; }
AGYDIR="$SCHOME/.gemini/antigravity-cli"
rm -rf "$AGYDIR"; rm -f "$SCHOME/.claude/sidecar-run"/*.env "$SCHOME/.claude/sidecar-requests" "$SCHOME/.claude/sidecar-quota"; touch "$SCHOME/.claude/sidecar-mode"

case "$(gsc start --provider antigravity-cli --task x)" in
  *"not signed in"*) ok "start refuses when there is no Antigravity CLI login (the CLI's oauth token file)" ;;
  *) bad "start refuses when there is no Antigravity CLI login" "$(gsc start --provider antigravity-cli --task x)" ;;
esac
mkdir -p "$AGYDIR"; printf 'tok\n' > "$AGYDIR/antigravity-oauth-token"
printf '{ "useG1Credits": true }\n' > "$AGYDIR/settings.json"
case "$(gsc start --provider antigravity-cli --task x)" in *"useG1Credits=true"*"money"*) ok "start refuses while the CLI may fall back to purchased AI credits (money)" ;; *) bad "start refuses while the CLI may fall back to purchased AI credits" "$(gsc start --provider antigravity-cli --task x)" ;; esac
printf '{}\n' > "$AGYDIR/settings.json"
rm -f "$AGY_ARGV"
OUT="$(gsc start --provider antigravity-cli --task 'add done.txt and commit')"
GW=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
case $OUT in *"Antigravity CLI, headless"*) ok "start launches the Antigravity CLI worker shape" ;; *) bad "start launches the Antigravity CLI worker shape" "$OUT" ;; esac
if [ "$(cat "$AGYDIR/settings.json")" = '{}' ]; then ok "and leaves the CLI's settings file alone (an absent useG1Credits is off)"; else bad "and leaves the CLI's settings file alone" "$(cat "$AGYDIR/settings.json")"; fi
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW.rc" ] && break; sleep 0.5; done
if [ -d "$GREPO/.claude/worktrees/$GW" ] && git -C "$GREPO" branch --list "$GW" | grep -q "$GW"; then ok "a worktree on a branch named after the worker was created under .claude/worktrees"
else bad "a worktree on a branch named after the worker was created" "$(git -C "$GREPO" worktree list)"; fi
assert_eq "$GREPO_P/.claude/worktrees/$GW" "$(cat "$AGY_CWD" 2>/dev/null)" "the CLI ran inside that worktree"
GARGV=$(tr '\n' ' ' < "$AGY_ARGV" 2>/dev/null)
case $GARGV in *"-p "*"Antigravity CLI headless inside a git worktree at $GREPO_P/.claude/worktrees/$GW "*"commit it on this branch and stop there"*"Rules of engagement for gemini-3.8-flash-high on antigravity-cli:"*"Commit on the current branch and stop"*"TASK: add done.txt and commit"*)
  ok "the prompt carries the brief with the worktree's absolute path, the provider's Worker rules and the task, in that order" ;;
  *) bad "the prompt carries the brief, the Worker rules and the task" "$GARGV" ;; esac
case $GARGV in *"--output-format json "*"--dangerously-skip-permissions "*"--print-timeout 2h"*) ok "headless flags: --output-format json, --dangerously-skip-permissions, --print-timeout from the profile" ;; *) bad "headless flags" "$GARGV" ;; esac
case $GARGV in *"--model gemini-3.8-flash-high"*) ok "the profile's model reaches the CLI as --model" ;; *) bad "the profile's model reaches the CLI as --model" "$GARGV" ;; esac
if grep -q 'GIT_CONFIG_KEY_0=core.hooksPath' "$AGY_ENV" 2>/dev/null; then ok "the push guard reaches the CLI's git through GIT_CONFIG_*"; else bad "the push guard reaches the CLI's git"; fi
GUARD=$(sed -n 's/^GIT_CONFIG_VALUE_0=//p' "$AGY_ENV")
if [ -x "$GUARD/pre-push" ] && ! "$GUARD/pre-push" 2>/dev/null; then ok "and the guard's pre-push refuses"; else bad "and the guard's pre-push refuses" "$GUARD"; fi
case "$(cat "$SCHOME/.claude/sidecar-run/$GW.env")" in *"harness=antigravity-cli"*"pid="*"worktree=$GREPO_P/.claude/worktrees/$GW"*) ok "the run record carries harness, pid and worktree" ;; *) bad "the run record carries harness, pid and worktree" "$(cat "$SCHOME/.claude/sidecar-run/$GW.env")" ;; esac
case "$(gsc status)" in *"exited(0)  $GW  antigravity-cli/gemini-3.8-flash-high"*) ok "status reports the exited worker with its exit code" ;; *) bad "status reports the exited worker" "$(gsc status)" ;; esac
COLL="$(gsc collect --worker "$GW")"
case $COLL in *"stub work"*"1 turn(s), status SUCCESS, 20s"*"in 13051 (+20 cached), out 59 (+58 thinking), ~5 output tok/s over the run"*"Added done.txt"*"today: 1 run(s) on antigravity-cli"*)
  ok "collect shows the commit, the turn and token counts from the envelope, the response, and today's runs" ;;
  *) bad "collect shows the commit, turns, tokens and the response" "$COLL" ;; esac
COLL2="$(gsc collect --worker "$GW")"
case $COLL2 in *"already collected once"*"today: 1 run(s)"*) ok "a second collect does not count the run again" ;; *) bad "a second collect does not count again" "$COLL2" ;; esac
case "$(gsc spend)" in *"antigravity-cli: 1 run(s) today on the plan's quota"*) ok "spend shows the day's runs for a quota-billed provider" ;; *) bad "spend shows the day's runs" "$(gsc spend)" ;; esac
gsc stop --worker "$GW" >/dev/null
if [ ! -f "$SCHOME/.claude/sidecar-run/$GW.env" ] && [ ! -f "$SCHOME/.claude/sidecar-run/$GW.out" ]; then ok "stop removes the record and the CLI's output files"; else bad "stop removes the record"; fi
if [ -d "$GREPO/.claude/worktrees/$GW" ]; then ok "and leaves the worktree with the work in it"; else bad "and leaves the worktree"; fi

# --model: one of the profile's listed slugs for this run; anything else refuses (D19)
case "$(gsc start --provider antigravity-cli --task x --model gemini-9-ultra)" in *"does not offer model gemini-9-ultra"*"gemini-3.1-pro-high"*) ok "start refuses a model the profile does not list, naming the ones it does" ;; *) bad "start refuses a model the profile does not list" "$(gsc start --provider antigravity-cli --task x --model gemini-9-ultra)" ;; esac
case "$(sc start --task x --model gemini-3.1-pro-high)" in *"deepseek takes no --model"*) ok "a profile without models= takes no --model" ;; *) bad "a profile without models= takes no --model" "$(sc start --task x --model gemini-3.1-pro-high)" ;; esac
rm -f "$AGY_ARGV"
export GEMINI_API_KEY=leak-me
OUT="$(gsc start --provider antigravity-cli --task 'review it' --model gemini-3.1-pro-high)"
unset GEMINI_API_KEY
GWM=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GWM.rc" ] && break; sleep 0.5; done
case "$(tr '\n' ' ' < "$AGY_ARGV")" in *"Rules of engagement for gemini-3.1-pro-high on antigravity-cli:"*"--model gemini-3.1-pro-high"*) ok "a listed --model reaches the CLI and the brief names it" ;; *) bad "a listed --model reaches the CLI and the brief names it" "$(tr '\n' ' ' < "$AGY_ARGV" | cut -c1-200)" ;; esac
case "$(gsc status)" in *"$GWM  antigravity-cli/gemini-3.1-pro-high"*) ok "status shows the model chosen for that run" ;; *) bad "status shows the model chosen for that run" "$(gsc status)" ;; esac
if grep -q '^GEMINI_API_KEY=' "$AGY_ENV" 2>/dev/null; then bad "an API key in the environment does not reach the CLI (it would bill the key, not the plan)"; else ok "an API key in the environment does not reach the CLI (it would bill the key, not the plan)"; fi
gsc stop --worker "$GWM" >/dev/null

# A worker that is still running: status says live, stop kills it.
# exported, not prefixed: a prefix assignment on a shell function does not reach the processes it spawns
export AGY_STUB_SLEEP=60
T_START=$(date +%s)
OUT="$(gsc start --provider antigravity-cli --task 'hang')"
unset AGY_STUB_SLEEP
if [ $(( $(date +%s) - T_START )) -lt 5 ]; then ok "start returns at once while the worker runs on (descriptors detached)"
else bad "start returns at once while the worker runs on" "took $(( $(date +%s) - T_START )) s"; fi
GW2=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
sleep 0.5
case "$(gsc status)" in *"live  $GW2  antigravity-cli/gemini-3.8-flash-high"*) ok "a running CLI worker shows as live" ;; *) bad "a running CLI worker shows as live" "$(gsc status) | stub env: $(grep AGY_STUB "$AGY_ENV" 2>/dev/null || echo 'no AGY_STUB var') | argv: $(tr '\n' ' ' < "$AGY_ARGV" | cut -c1-80)" ;; esac
case "$(gsc collect --worker "$GW2")" in *"still running (pid"*) ok "collect on a running worker says so and prices nothing" ;; *) bad "collect on a running worker says so" ;; esac
GPID=$(sed -n 's/^pid=//p' "$SCHOME/.claude/sidecar-run/$GW2.env")
gsc stop --worker "$GW2" >/dev/null; sleep 0.5
if ! kill -0 "$GPID" 2>/dev/null; then ok "stop kills the running CLI worker"; else bad "stop kills the running CLI worker" "pid $GPID alive"; kill "$GPID" 2>/dev/null; fi
case "$(gsc status)" in *"No workers."*) ok "and status is empty again" ;; *) bad "and status is empty again" "$(gsc status)" ;; esac

# A run that hits the plan's quota marks the provider spent for 5 h: spend says so, start refuses, an old mark does not.
export AGY_STUB_QUOTA=1
OUT="$(gsc start --provider antigravity-cli --task 'x')"
unset AGY_STUB_QUOTA
GW3=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW3.rc" ] && break; sleep 0.5; done
COLL3="$(gsc collect --worker "$GW3")"
case $COLL3 in *"status ERROR"*"quota exhausted for this window"*"QUOTA SPENT: antigravity-cli is marked spent for 5 hours"*) ok "collect shows the CLI's error and marks a quota-out run" ;; *) bad "collect shows the CLI's error and marks a quota-out run" "$COLL3" ;; esac
case "$(gsc spend)" in *"antigravity-cli: 2 run(s) today on the plan's quota"*"CAP REACHED (the plan's quota ran out at "*"; it refreshes within 5 h); start refuses"*) ok "spend marks a quota-billed provider whose last run hit the quota" ;; *) bad "spend marks a quota-billed provider whose last run hit the quota" "$(gsc spend)" ;; esac
gsc stop --worker "$GW3" >/dev/null
NWT=$(git -C "$GREPO" worktree list | wc -l | tr -d ' ')
case "$(gsc start --provider antigravity-cli --task x)" in *"antigravity-cli has reached its cap"*"refreshes within 5 h"*) ok "start refuses a quota-billed provider within 5 h of a quota-out run" ;; *) bad "start refuses a quota-billed provider within 5 h of a quota-out run" "$(gsc start --provider antigravity-cli --task x)" ;; esac
assert_eq "$NWT" "$(git -C "$GREPO" worktree list | wc -l | tr -d ' ')" "and makes no worktree"
printf '%s antigravity-cli quota exhausted long ago\n' "$(( $(date +%s) - 20000 ))" > "$SCHOME/.claude/sidecar-quota"
OUT="$(gsc start --provider antigravity-cli --task 'again')"
case $OUT in *"Antigravity CLI, headless"*) ok "a quota mark older than 5 h no longer refuses" ;; *) bad "a quota mark older than 5 h no longer refuses" "$OUT" ;; esac
GW4=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW4.rc" ] && break; sleep 0.5; done
gsc stop --worker "$GW4" >/dev/null

# From the reviews both Gemini models wrote of this path (2026-09-14): the
# parsers must not be fooled by the string fields, the last field of an
# envelope has no `","` after it, and a run that dies before printing usage
# (or prints only to stderr) must still mark a quota-out.
agy_fn() { bash -c 'set -u; eval "$(/usr/bin/sed -n "/^_agy_stats()/,/^}/p;/^_agy_seconds()/,/^}/p;/^_agy_field()/,/^}/p" "'"$SC"'")"; '"$1"; }
printf '%s\n' '{"status":"ERROR","error":"quota exceeded"}' > "$WORK/env-last.json"
assert_eq "quota exceeded" "$(agy_fn '_agy_field e "'"$WORK/env-last.json"'" error; printf "%s" "$e"')" "_agy_field reads the last field of an envelope (no \",\" after it)"
printf '%s\n' '{"status":"ERROR","error":""}' > "$WORK/env-empty.json"
assert_eq "" "$(agy_fn '_agy_field e "'"$WORK/env-empty.json"'" error; printf "%s" "$e"')" "and an empty last field is empty, not a stray quote-brace"
printf '%s\n' '{"conversation_id":"c","status":"SUCCESS","response":"Here is an example envelope: {\"num_turns\": 9, \"duration_seconds\": 1, \"usage\": {\"input_tokens\": 5}} — note \"status\":\"ERROR\" would differ","error":"","duration_seconds":42.5,"num_turns":1,"usage":{"input_tokens":13051,"output_tokens":59,"thinking_tokens":58,"cache_read_tokens":20,"total_tokens":13110}}' > "$WORK/env-hijack.json"
assert_eq "1 13051 59 20 58 42" "$(agy_fn '_agy_stats t i o c h "'"$WORK/env-hijack.json"'"; _agy_seconds s "'"$WORK/env-hijack.json"'"; printf "%s %s %s %s %s %s" "$t" "$i" "$o" "$c" "$h" "$s"')" "_agy_stats and _agy_seconds read the real counts, not the ones quoted in the response text"
assert_eq "SUCCESS" "$(agy_fn '_agy_field s "'"$WORK/env-hijack.json"'" status; printf "%s" "$s"')" "and _agy_field takes the first status, which is the envelope's own"
rm -f "$SCHOME/.claude/sidecar-quota"
export AGY_STUB_NOUSAGE=1
OUT="$(gsc start --provider antigravity-cli --task 'x')"; unset AGY_STUB_NOUSAGE
GW5=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW5.rc" ] && break; sleep 0.5; done
case "$(gsc collect --worker "$GW5")" in *"no usage in"*"status ERROR"*"quota exceeded for this window"*"QUOTA SPENT"*) ok "an envelope without usage still reaches the error and marks a quota-out" ;; *) bad "an envelope without usage still reaches the error and marks a quota-out" "start: $OUT | collect: $(gsc collect --worker "$GW5")" ;; esac
gsc stop --worker "$GW5" >/dev/null; rm -f "$SCHOME/.claude/sidecar-quota"
export AGY_STUB_STDERR=1
OUT="$(gsc start --provider antigravity-cli --task 'x')"; unset AGY_STUB_STDERR
GW6=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW6.rc" ] && break; sleep 0.5; done
case "$(gsc collect --worker "$GW6")" in *"no usage in"*"model quota exhausted (stderr)"*"QUOTA SPENT"*) ok "a run that printed only to stderr is read from stderr and marks a quota-out" ;; *) bad "a run that printed only to stderr is read from stderr and marks a quota-out" "start: $OUT | collect: $(gsc collect --worker "$GW6")" ;; esac
gsc stop --worker "$GW6" >/dev/null; rm -f "$SCHOME/.claude/sidecar-quota"
# a repository path with a space in it (the reviews' bonus finding: `read -r wt _` split it)
SPREPO="$SCHOME/sp ace/repo"; mkdir -p "$SPREPO"; git -C "$SPREPO" init -q; git -C "$SPREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SPREPO_P=$(cd "$SPREPO" && pwd -P)
gsp() { ( cd "$SPREPO" && HOME="$SCHOME" PATH="$SCSTUB:$PATH" bash "$SC" "$@" ) 2>&1; }
OUT="$(gsp start --provider antigravity-cli --task 'add done.txt and commit')"
GW7=$(printf '%s\n' "$OUT" | sed -n 's/^worker \(sidecar-[0-9-]*\) .*/\1/p' | head -1)
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCHOME/.claude/sidecar-run/$GW7.rc" ] && break; sleep 0.5; done
case "$(gsp collect --worker "$GW7")" in *"worktree: $SPREPO_P/.claude/worktrees/$GW7"*"stub work"*) ok "collect lists a worktree whose path contains a space (porcelain listing)" ;; *) bad "collect lists a worktree whose path contains a space" "start: $OUT | $(gsp collect --worker "$GW7" | head -4)" ;; esac
gsp stop --worker "$GW7" >/dev/null
rm -f "$SCHOME/.claude/sidecar-run"/*.env "$SCHOME/.claude/sidecar-requests" "$SCHOME/.claude/sidecar-quota"

# ---------------------------------------------------------------------------
group "Sidecar — three kinds of cost in spend, and the caps that stop a provider"
# ---------------------------------------------------------------------------
BM="$(date +%Y-%m)"; TODAY="$(date +%Y-%m-%d)"
rm -f "$SCHOME/.claude/sidecar-run"/*.env "$SCHOME/.claude/sidecar-requests" "$SCHOME/.claude/sidecar-config" "$SCHOME/.claude/budget-state"
: > "$SCHOME/.claude/sidecar-ledger"; rm -f "$SCHOME/.claude/sidecar-balance"
case "$(sc spend)" in
  "Anthropic: no plan-limit reading yet"*) ok "spend leads with Anthropic even when the sensor has written nothing" ;;
  *) bad "spend leads with Anthropic even when the sensor has written nothing" "$(sc spend | head -1)" ;;
esac
printf 'UPDATED=1\nRATE_LIMITS=present\nFIVE_H_PCT=28.4\nFIVE_H_RESET=1789407600\nSEVEN_D_PCT=89\nSEVEN_D_RESET=1789776000\n' > "$SCHOME/.claude/budget-state"
case "$(sc spend | head -1)" in
  "Anthropic: 5h 28% used (resets "??:??") · 7d 89% used") ok "spend renders the 5h and 7d windows from the sensor's state" ;;
  *) bad "spend renders the 5h and 7d windows" "$(sc spend | head -1)" ;;
esac
SPEND="$(sc spend)"
case $SPEND in *deepseek:*|*antigravity-cli:*|*selfhosted:*) bad "a provider with no worker and no spend this period is not listed" "$SPEND" ;; *) ok "a provider with no worker and no spend this period is not listed" ;; esac
printf '%s-12T10:00:00 deepseek deepseek-flash 1 2 3 1500000 s1\n' "$BM" > "$SCHOME/.claude/sidecar-ledger"
case "$(sc spend)" in *"deepseek: API est \$1.50 / \$80 this month"*) ok "a token-billed provider with spend this month is listed with est / cap" ;; *) bad "a token-billed provider with spend this month is listed" "$(sc spend)" ;; esac
# selfhosted's profile lives in the ALT module copy (no balance_url, billing=none), so ask that copy;
# a requests-billed profile (no shipped provider bills that way since D18) lives there too
alt() { ( cd "$SCHOME/repo" && HOME="$SCHOME" PATH="$SCSTUB:$PATH" bash "$ALT/sidecar.sh" "$@" ) 2>&1; }
printf 'base_url=https://example.invalid\ncred_var=ANTHROPIC_AUTH_TOKEN\ncred_key=DEEPSEEK_API_KEY\nmodel=m\nmodel_alias=sonnet\nbilling=requests\ndaily_requests=1500\n' > "$ALT/providers/reqprov.conf"
printf '%s reqprov 12\n' "$TODAY" > "$SCHOME/.claude/sidecar-requests"
case "$(alt spend)" in *"reqprov: 12 of 1500 model requests today"*) ok "a requests-billed provider with requests today is listed" ;; *) bad "a requests-billed provider with requests today is listed" "$(alt spend)" ;; esac
printf 'worker=w1\nprovider=selfhosted\nmodel=m\nsession=s\nrepo=%s\n' "$SCHOME/repo" > "$SCHOME/.claude/sidecar-run/w1.env"
case "$(alt spend)" in *"selfhosted: in use, unmetered"*) ok "a provider with a worker out is listed even with nothing metered" ;; *) bad "a provider with a worker out is listed" "$(alt spend)" ;; esac
rm -f "$SCHOME/.claude/sidecar-run/w1.env"

# Money cap: the higher of estimate and billed against CAP_USD; start refuses.
printf 'CAP_USD=1\n' > "$SCHOME/.claude/sidecar-config"
case "$(sc spend)" in *"deepseek: API est \$1.50 / \$1 this month — CAP REACHED (\$1.50 of the \$1 monthly cap; it resets on the 1st); start refuses"*) ok "spend marks a token-billed provider at its monthly cap" ;; *) bad "spend marks a token-billed provider at its cap" "$(sc spend)" ;; esac
rm -f "$CLAUDE_ARGV"
case "$(sc start --task x)" in *"deepseek has reached its cap"*"resets on the 1st"*) ok "start refuses a provider at its monthly cap" ;; *) bad "start refuses a provider at its monthly cap" "$(sc start --task x)" ;; esac
if [ ! -f "$CLAUDE_ARGV" ]; then ok "and launches nothing"; else bad "and launches nothing"; fi
rm -f "$SCHOME/.claude/sidecar-config"
# Requests cap: today's count against daily_requests; start refuses; the worktree is never made.
printf '%s reqprov 1500\n' "$TODAY" > "$SCHOME/.claude/sidecar-requests"
case "$(alt spend)" in *"reqprov: 1500 of 1500 model requests today"*"CAP REACHED (1500 of 1500 model requests today; it resets at midnight); start refuses"*) ok "spend marks a requests-billed provider at its daily cap" ;; *) bad "spend marks a requests-billed provider at its daily cap" "$(alt spend)" ;; esac
rm -f "$CLAUDE_ARGV"
case "$(alt start --provider reqprov --task x)" in *"reqprov has reached its cap"*"resets at midnight"*) ok "start refuses a requests-billed provider at its daily cap" ;; *) bad "start refuses a requests-billed provider at its cap" "$(alt start --provider reqprov --task x)" ;; esac
if [ ! -f "$CLAUDE_ARGV" ]; then ok "and launches nothing"; else bad "and launches nothing"; fi
rm -f "$SCHOME/.claude/sidecar-requests" "$ALT/providers/reqprov.conf"
# Time cap: a time-billed provider (a Kaggle session) whose last reading says 0 minutes.
cat > "$ALT/providers/timeprov.conf" <<'EOF'
base_url=https://example.invalid
cred_var=ANTHROPIC_AUTH_TOKEN
cred_key=DEEPSEEK_API_KEY
model=m
model_alias=sonnet
balance_url=https://example.invalid/session/quota
balance_field=session_remaining_min
billing=none
EOF
printf '%sT01:00:00 timeprov 0\n' "$TODAY" > "$SCHOME/.claude/sidecar-balance"
case "$(alt spend)" in *"timeprov: 0 min of session time left at the last reading — CAP REACHED (the session's time is up"*) ok "spend marks a time-billed provider whose session is over" ;; *) bad "spend marks a time-billed provider whose session is over" "$(alt spend)" ;; esac
case "$(alt start --provider timeprov --task x)" in *"timeprov has reached its cap: the session's time is up"*) ok "start refuses a time-billed provider whose session is over" ;; *) bad "start refuses a time-billed provider whose session is over" "$(alt start --provider timeprov --task x)" ;; esac
printf '%sT01:00:00 timeprov 34000000\n' "$TODAY" > "$SCHOME/.claude/sidecar-balance"
case "$(alt spend)" in *"timeprov: 34 min of session time left"*"CAP REACHED"*) bad "a session with time left is not capped" "$(alt spend)" ;; *"timeprov: 34 min of session time left at the last reading"*) ok "a session with time left is listed with its minutes and not capped" ;; *) bad "a session with time left is listed" "$(alt spend)" ;; esac
rm -f "$SCHOME/.claude/sidecar-balance" "$SCHOME/.claude/budget-state" "$ALT/providers/timeprov.conf"

# ---------------------------------------------------------------------------
group "Sidecar — the status line segment the budget sensor prints"
# ---------------------------------------------------------------------------
rm -f "$BHOME/.claude/statusline-extra"
OUT="$(sensor <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/p"},
 "rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1738425600}}}
PAYLOAD
)"
case $OUT in
  *"API"*) bad "no segment appears when no module has written one" "$OUT" ;;
  *) ok "no segment appears when no module has written one" ;;
esac
printf 'API $1.23/$80\n' > "$BHOME/.claude/statusline-extra"
OUT="$(sensor <<'PAYLOAD'
{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/p"},
 "rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1738425600}}}
PAYLOAD
)"
case $OUT in
  *"5h 20%"*"API \$1.23/\$80"*) ok "a module's segment is appended after the windows" ;;
  *) bad "a module's segment is appended after the windows" "$OUT" ;;
esac
rm -f "$BHOME/.claude/statusline-extra"

# ---------------------------------------------------------------------------
group "Installing the budget module"
# ---------------------------------------------------------------------------
B2E="$WORK/b2e"; mkdir -p "$B2E"
printf '%s' '{
  "model": "opus[1m]",
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "/usr/local/bin/somebody-else.sh" } ] }
    ]
  }
}
' > "$B2E/settings.json"
B2E_ORIGINAL="$(cat "$B2E/settings.json")"
if CLAUDE_DIR="$B2E" bash "$ROOT/install.sh" > "$WORK/binstall.log" 2>&1; then
  ok "install.sh installs the budget module alongside an unrelated PreToolUse hook"
else
  bad "install.sh installs the budget module alongside an unrelated PreToolUse hook" "$(cat "$WORK/binstall.log")"
fi
for want in drive-budget/sensor.sh drive-budget/gate.sh drive-budget/park.sh drive-budget/resume.sh \
            drive-budget/BUDGET.md commands/budget-on.md commands/budget-off.md budget-config; do
  if [ -f "$B2E/$want" ]; then ok "install.sh placed $want"; else bad "install.sh placed $want"; fi
done
assert_json "$B2E/settings.json" "settings.json is still valid JSON"
if settings_hook_registered "$B2E/settings.json" gate.sh PreToolUse; then ok "the tool gate is registered on PreToolUse"
else bad "the tool gate is registered on PreToolUse"; fi
if settings_hook_registered "$B2E/settings.json" gate.sh UserPromptSubmit; then ok "the prompt hook is registered on UserPromptSubmit"
else bad "the prompt hook is registered on UserPromptSubmit"; fi
if settings_hook_registered "$B2E/settings.json" somebody-else.sh PreToolUse; then ok "the unrelated PreToolUse hook survived"
else bad "the unrelated PreToolUse hook survived"; fi
if settings_statusline_command SLC "$B2E/settings.json"; then
  case $SLC in *sensor.sh*) ok "the sensor is registered as the status line" ;;
               *) bad "the sensor is registered as the status line" "$SLC" ;; esac
else
  bad "the sensor is registered as the status line"
fi

# An edited threshold must survive a reinstall.
printf 'WRAP_PCT=80\n' > "$B2E/budget-config"
CLAUDE_DIR="$B2E" bash "$ROOT/install.sh" >/dev/null 2>&1
assert_eq 'WRAP_PCT=80' "$(cat "$B2E/budget-config")" "a reinstall does not overwrite budget-config"

CLAUDE_DIR="$B2E" bash "$ROOT/uninstall.sh" > "$WORK/buninstall.log" 2>&1
assert_eq "$B2E_ORIGINAL" "$(cat "$B2E/settings.json")" "uninstall restores settings.json byte for byte"
for gone in drive-budget/sensor.sh drive-budget/gate.sh commands/budget-on.md commands/budget-off.md; do
  if [ -f "$B2E/$gone" ]; then bad "uninstall removed $gone"; else ok "uninstall removed $gone"; fi
done
if [ -f "$B2E/budget-config" ]; then ok "uninstall keeps budget-config, like the settings backups"
else bad "uninstall keeps budget-config, like the settings backups"; fi

# A status line someone else wrote is reported, never taken over.
S3="$WORK/s3"; mkdir -p "$S3"
printf '%s' '{
  "statusLine": { "type": "command", "command": "~/my-own-line.sh" }
}
' > "$S3/settings.json"
S3_ORIGINAL="$(cat "$S3/settings.json")"
if CLAUDE_DIR="$S3" bash "$ROOT/install.sh" > "$WORK/s3.log" 2>&1; then
  bad "install.sh reports an existing statusLine as a failure rather than replacing it"
else
  ok "install.sh reports an existing statusLine as a failure rather than replacing it"
fi
if settings_statusline_command SLC "$S3/settings.json" && [ "$SLC" = '"~/my-own-line.sh"' ]; then
  ok "the existing status line is untouched"
else
  bad "the existing status line is untouched" "$SLC"
fi
CLAUDE_DIR="$S3" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
if settings_statusline_command SLC "$S3/settings.json" && [ "$SLC" = '"~/my-own-line.sh"' ]; then
  ok "uninstall leaves a status line it did not install"
else
  bad "uninstall leaves a status line it did not install" "$SLC"
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "-----------------------------------------------"
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
