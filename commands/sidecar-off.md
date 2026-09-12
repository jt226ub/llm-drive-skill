---
description: Turn sidecar mode OFF — no new third-party workers can be launched
allowed-tools: Bash(rm:*)
---

!`rm -f "$HOME/.claude/sidecar-mode"`

Sidecar mode has just been switched OFF (the flag file was removed). Confirm to the user in two lines: `sidecar.sh start` will now refuse, and any worker already running is untouched — list what is still out there with `"$HOME/.claude/drive-sidecar/sidecar.sh" status` and stop one with `stop --worker NAME`. The spend segment on the status line stays, because the ledger is a record of money already spent.
