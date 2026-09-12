#!/bin/bash
# Install the drive skill into a Claude Code config directory.
#
#   ./install.sh                 # install into ~/.claude
#   CLAUDE_DIR=/path ./install.sh
#
# Idempotent: re-running overwrites the shipped files and leaves the
# settings.json registrations alone if they are already there. Neither standing
# mode is switched on by install — run /drive-on and /budget-on in Claude Code
# for those.
#
# Needs bash and nothing else. There is no jq, node, perl, python or awk in
# this project; lib.sh explains why at length, but the short version is that a
# missing tool is the most common way an install fails, and jq's absence used
# to fail silently.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

# shellcheck source=lib.sh
. "$SRC/lib.sh"

# In standing mode the contract rides on every prompt, so its length is a
# context cost paid per turn. This is a self-imposed budget, not a harness cap:
# the old 10,000-character additionalContext ceiling no longer applies now that
# the hook writes to stdout, but the per-turn cost was always the better reason
# to keep the contract tight. OmniRoute's own ceiling is 50,000 — one SKILL.md
# has to fit both targets, so the tighter number wins.
BODY="$(strip_frontmatter "$SRC/skills/drive/SKILL.md")"
if [ "${#BODY}" -gt 9000 ]; then
  echo "ERROR: contract body is ${#BODY} chars, over the 9,000 budget." >&2
  echo "       Trim SKILL.md — it is injected into every prompt." >&2
  exit 1
fi

mkdir -p "$CLAUDE_DIR/skills/drive" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/drive-budget"
cp "$SRC/skills/drive/SKILL.md"  "$CLAUDE_DIR/skills/drive/SKILL.md"
cp "$SRC/commands/drive-on.md"   "$CLAUDE_DIR/commands/drive-on.md"
cp "$SRC/commands/drive-off.md"  "$CLAUDE_DIR/commands/drive-off.md"
cp "$SRC/hooks/drive-mode.sh"    "$CLAUDE_DIR/hooks/drive-mode.sh"
chmod +x "$CLAUDE_DIR/hooks/drive-mode.sh"

# The budget module. Its parts go in together and are gated at runtime by
# $HOME/.claude/budget-mode, the same shape as drive mode: install puts them in
# place, /budget-on switches them on, and it is on for every session or none.
#
# Source lives in modules/budget/; it installs to $CLAUDE_DIR/drive-budget/.
# The installed path is deliberately not modules/budget/ to match: it is named
# in settings.json on every machine that has this, and in the README's checks,
# so renaming it to tidy the layout would break working installs for nothing.
cp "$SRC/modules/budget/BUDGET.md" "$SRC/modules/budget/sensor.sh" \
   "$SRC/modules/budget/gate.sh"   "$SRC/modules/budget/park.sh" \
   "$SRC/modules/budget/resume.sh" "$CLAUDE_DIR/drive-budget/"
chmod +x "$CLAUDE_DIR/drive-budget/sensor.sh" "$CLAUDE_DIR/drive-budget/gate.sh" \
         "$CLAUDE_DIR/drive-budget/park.sh"   "$CLAUDE_DIR/drive-budget/resume.sh"
cp "$SRC/commands/budget-on.md"  "$CLAUDE_DIR/commands/budget-on.md"
cp "$SRC/commands/budget-off.md" "$CLAUDE_DIR/commands/budget-off.md"

# Written once and never overwritten, so a tuned threshold survives a reinstall.
if [ ! -f "$CLAUDE_DIR/budget-config" ]; then
  cat > "$CLAUDE_DIR/budget-config" <<'CFG'
# Thresholds for the budget module, as whole percentages of a window used.
# Edit freely — install.sh writes this file once and never overwrites it.
#
# Five-hour window: stop starting work at WRAP_PCT, close the tool gate at
# STOP_PCT. The gap between them is the reserve the record gets written from.
WRAP_PCT=97
STOP_PCT=99
#
# Weekly window: start the record much earlier, because hitting this one costs
# days rather than hours and takes every session on the account with it.
WEEK_DOC_PCT=90
WEEK_STOP_PCT=97
#
# How many tool calls the gate allows for writing and committing the record
# once it has closed. Shared across concurrent sessions, because the window is.
HANDOFF_CALLS=25
#
# Seconds after a window resets before a parked session resumes itself.
RESUME_DELAY_S=300
CFG
  echo "Wrote $CLAUDE_DIR/budget-config with the default thresholds."
fi

echo "Installed skill, commands, hook and budget module into $CLAUDE_DIR"

# The hook script and the two slash commands resolve their paths from $HOME, so
# the portable command string only works for the default location; anywhere
# else needs the literal path.
if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then
  HOOK_CMD='"$HOME/.claude/hooks/drive-mode.sh"'
  GATE_CMD='"$HOME/.claude/drive-budget/gate.sh"'
  SENSOR_CMD='"$HOME/.claude/drive-budget/sensor.sh"'
else
  HOOK_CMD="\"$CLAUDE_DIR/hooks/drive-mode.sh\""
  GATE_CMD="\"$CLAUDE_DIR/drive-budget/gate.sh\""
  SENSOR_CMD="\"$CLAUDE_DIR/drive-budget/sensor.sh\""
  echo "NOTE: non-default CLAUDE_DIR — the hooks and the /drive-on, /drive-off,"
  echo "      /budget-on and /budget-off commands still read their flags, the"
  echo "      skill and the budget state from \$HOME/.claude. Edit those files"
  echo "      if that is wrong."
fi

# A missing or empty settings.json becomes an empty object first, so there is
# one registration path rather than a special case for the clean-machine
# install and another for everyone else.
EXISTED=1
if [ ! -s "$SETTINGS" ]; then
  EXISTED=0
  printf '{}\n' > "$SETTINGS"
fi

# One backup for the whole run, written before the first edit that lands. A
# re-run that changes nothing writes no backup at all.
BACKED_UP=0
backup_once() {
  [ "$BACKED_UP" = 0 ] || return 0
  BACKED_UP=1
  [ "$EXISTED" = 1 ] || return 0
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backed up settings.json."
}

# register EVENT COMMAND SUBSTRING LABEL
register() {
  if settings_hook_registered "$SETTINGS" "$3" "$1"; then
    echo "Already registered: $4 — settings.json left unchanged."
    return 0
  fi
  backup_once
  if settings_register_hook "$SETTINGS" "$2" "$1"; then
    echo "Registered $4 in settings.json."
    return 0
  fi
  # settings_register_hook refuses rather than guesses when the file is not
  # JSON, or when the container it needs holds something other than what it
  # must. It has already said which; all that is left is to show what to paste.
  json_escape CMD_JSON "$2"
  cat >&2 <<SNIP

      settings.json was left untouched. Add this yourself, merging into an
      existing "hooks" key rather than replacing it:

  "hooks": {
    "$1": [
      { "hooks": [ { "type": "command", "command": "$CMD_JSON" } ] }
    ]
  }

      Files are in place; that edit is all that is missing.
SNIP
  return 1
}

# The match is on the script name alone, scoped to one event: each event holds
# at most one gate entry, so the name is unambiguous there, and matching a
# longer string would have to reproduce the backslash escaping that the command
# carries in the file.
RC=0
register UserPromptSubmit "$HOOK_CMD"        drive-mode.sh "the drive hook"           || RC=1
register UserPromptSubmit "$GATE_CMD prompt" gate.sh       "the budget prompt hook"   || RC=1
register PreToolUse       "$GATE_CMD tool"   gate.sh       "the budget tool gate"     || RC=1

# The status line is the sensor, and settings.json holds only one. Ours goes in
# only when the slot is free; an existing status line — anyone's, including an
# older copy of this one — is left alone and reported, because silently taking
# over a line someone wrote is worse than not installing.
if settings_statusline_command EXISTING_SL "$SETTINGS"; then
  case $EXISTING_SL in
    *sensor.sh*) echo "The budget sensor is already the status line — left unchanged." ;;
    *) cat >&2 <<SL

NOTE: settings.json already has a statusLine, so the budget sensor was not
      installed as one:
          $EXISTING_SL
      The sensor is the only thing that reads plan rate limits, so until it
      runs, /budget-on has nothing to act on. Either point statusLine at
          $SENSOR_CMD
      or have your own status line invoke it and print its output.
SL
      RC=1 ;;
  esac
else
  backup_once
  if settings_set_statusline "$SETTINGS" "$SENSOR_CMD"; then
    echo "Registered the budget sensor as the status line."
  else
    echo "ERROR: could not write the statusLine into settings.json." >&2
    RC=1
  fi
fi

[ "$RC" = 0 ] || exit 1

echo
echo "Done. Restart Claude Code, then:"
echo "  /drive       run one task under the contract"
echo "  /drive-on    standing mode until /drive-off"
echo "  /budget-on   pause and document before a rate limit, until /budget-off"
