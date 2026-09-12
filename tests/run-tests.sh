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
for f in install.sh uninstall.sh lib.sh hooks/drive-mode.sh omniroute/install-omniroute.sh \
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
for want in skills/drive/SKILL.md commands/drive-on.md commands/drive-off.md hooks/drive-mode.sh; do
  if [ -f "$E2E/$want" ]; then ok "install.sh placed $want"; else bad "install.sh placed $want"; fi
done
if [ -x "$E2E/hooks/drive-mode.sh" ]; then ok "the hook is executable"; else bad "the hook is executable"; fi
assert_json "$E2E/settings.json" "install.sh leaves valid JSON"
if settings_hook_registered "$E2E/settings.json" drive-mode.sh; then ok "install.sh registered the hook"; else bad "install.sh registered the hook"; fi
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
for gone in skills/drive/SKILL.md commands/drive-on.md commands/drive-off.md hooks/drive-mode.sh drive-mode; do
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
mkdir -p "$BHOME/.claude/budget-run"; touch "$BHOME/.claude/budget-run/parked-sess-1"
assert_eq deny "$(gate tool Read | decision)" "a parked session is closed to every tool"
OUT="$(printf '{"session_id":"sess-2","tool_name":"Read"}' | HOME="$BHOME" bash "$ROOT/modules/budget/gate.sh" tool | decision)"
assert_eq context "$OUT" "but parking one session does not gate another out of writing its own record"
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
for m in WRAP STOP WEEK_DOC WEEK_STOP SUBAGENT PARKED SCHEMA; do
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
chmod +x "$RSTUB/launchctl" "$RSTUB/claude"
export CLAUDE_STUB_ARGV="$WORK/claude-argv.txt"

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
rm -f "$CLAUDE_STUB_ARGV"; : > "$RHOME/.claude/budget-resume.log"
CLAUDE_STUB_ALIVE=sess-alive run_resume sess-alive
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
