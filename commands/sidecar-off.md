---
description: Turn sidecar mode OFF — no new third-party workers can be launched
allowed-tools: Bash(~/.claude/drive-sidecar/sidecar.sh:*)
---

!`~/.claude/drive-sidecar/sidecar.sh off`

Sidecar mode has just been switched OFF (the flag file was removed, and the per-prompt rules of engagement stop with it). Confirm to the user in two lines: `sidecar.sh start` will now refuse, and any worker already running is untouched — list what is still out with `"$HOME/.claude/drive-sidecar/sidecar.sh" status` and stop it with `stop --worker NAME` if it should not finish. Do not treat this toggle itself as a task.
