---
description: Turn budget mode OFF — no rate-limit gating, no automatic parking
allowed-tools: Bash(rm:*)
---

!`rm -f "$HOME/.claude/budget-mode"`

Budget mode has just been switched OFF (the flag file was removed). Confirm to the user in two lines: the gate no longer reads the rate-limit windows, so nothing will pause or document itself before a limit; and any resume that was already scheduled still stands — list what is scheduled by running `"$HOME/.claude/drive-budget/park.sh" --status`, and tell them `--cancel --all` drops it. The status line keeps showing usage either way.
