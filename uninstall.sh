#!/bin/bash
# Remove the drive skill from a Claude Code config directory.
# Leaves settings.json backups in place, deliberately.
#
# Needs bash and nothing else — see lib.sh.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

# shellcheck source=lib.sh
. "$SRC/lib.sh"

# Scheduled resumes first, while park.sh is still on disk to cancel them with.
# A launchd job left behind would fire into a machine with nothing to serve it.
if [ -x "$CLAUDE_DIR/drive-budget/park.sh" ]; then
  "$CLAUDE_DIR/drive-budget/park.sh" --cancel --all || true
fi

rm -f "$CLAUDE_DIR/drive-mode"                 # the standing-mode flag
rm -f "$CLAUDE_DIR/skills/drive/SKILL.md"
rmdir "$CLAUDE_DIR/skills/drive" 2>/dev/null || true
rm -f "$CLAUDE_DIR/commands/drive-on.md" "$CLAUDE_DIR/commands/drive-off.md"
rm -f "$CLAUDE_DIR/hooks/drive-mode.sh"

rm -f "$CLAUDE_DIR/budget-mode" "$CLAUDE_DIR/budget-state"
rm -f "$CLAUDE_DIR/commands/budget-on.md" "$CLAUDE_DIR/commands/budget-off.md"
rm -f "$CLAUDE_DIR/drive-budget/BUDGET.md" "$CLAUDE_DIR/drive-budget/sensor.sh" \
      "$CLAUDE_DIR/drive-budget/gate.sh" "$CLAUDE_DIR/drive-budget/park.sh" \
      "$CLAUDE_DIR/drive-budget/resume.sh"
rmdir "$CLAUDE_DIR/drive-budget" 2>/dev/null || true
rm -f "$CLAUDE_DIR/budget-run/parked-"* "$CLAUDE_DIR/budget-run/calls" \
      "$CLAUDE_DIR/budget-run/warned" 2>/dev/null || true
rmdir "$CLAUDE_DIR/budget-run" 2>/dev/null || true

rm -f "$CLAUDE_DIR/sidecar-mode" "$CLAUDE_DIR/statusline-extra"
rm -f "$CLAUDE_DIR/commands/sidecar-on.md" "$CLAUDE_DIR/commands/sidecar-off.md"
rm -f "$CLAUDE_DIR/drive-sidecar/sidecar.sh" "$CLAUDE_DIR/drive-sidecar/prices.conf" \
      "$CLAUDE_DIR/drive-sidecar/guard.sh"
rm -f "$CLAUDE_DIR/drive-sidecar/providers/"*.conf
rmdir "$CLAUDE_DIR/drive-sidecar/providers" "$CLAUDE_DIR/drive-sidecar" 2>/dev/null || true
rm -rf "$CLAUDE_DIR/sidecar-run/"*.hooks 2>/dev/null || true
rm -f "$CLAUDE_DIR/sidecar-run/"*.env "$CLAUDE_DIR/sidecar-run/"*.collected 2>/dev/null || true
rmdir "$CLAUDE_DIR/sidecar-run" 2>/dev/null || true
# sidecar-credentials, sidecar-ledger, sidecar-balance and sidecar-config stay,
# like budget-config
# and the
# settings backups: one holds a secret this script has no business deleting,
# the other is a record of money that was actually spent.
# budget-config and budget-resume.log stay, the same way settings.json backups
# do: one holds thresholds someone may have tuned, the other is the only record
# of what the unattended resumes did.
echo "Removed drive and budget files from $CLAUDE_DIR"

if [ -s "$SETTINGS" ]; then
  # Named, not globbed: the only backup this run may remove is the one this run
  # wrote. Every earlier backup stays, on purpose.
  BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BAK"
  set +e
  CHANGED=0; FAILED=0
  for spec in "UserPromptSubmit drive-mode.sh" "UserPromptSubmit gate.sh" "PreToolUse gate.sh" "PreToolUse guard.sh"; do
    settings_deregister_hook "$SETTINGS" "${spec#* }" "${spec%% *}"
    case $? in
      0) CHANGED=1 ;;
      2) ;;
      *) FAILED=1 ;;
    esac
  done
  # Only ever removes a statusLine whose command names our sensor.
  settings_unset_statusline "$SETTINGS" sensor.sh
  case $? in
    0) CHANGED=1 ;;
    2) ;;
    *) FAILED=1 ;;
  esac
  set -e
  if [ "$FAILED" = 1 ]; then
    cat >&2 <<'SNIP'

NOTE: part of settings.json could not be edited safely and was left alone. The
      entries are inert now that the scripts they name are deleted; remove the
      hooks naming drive-mode.sh or gate.sh, and any statusLine naming
      sensor.sh, by hand to tidy up.
SNIP
  elif [ "$CHANGED" = 1 ]; then
    echo "Deregistered the hooks and status line from settings.json (backup written)."
  else
    echo "Nothing of ours in settings.json — left unchanged."
    rm -f "$BAK"
  fi
fi
