---
description: Turn sidecar mode ON — delegate coding work to a model on a third-party API, running inside its own Claude Code session (until /sidecar-off)
allowed-tools: Bash(touch:*)
---

!`touch "$HOME/.claude/sidecar-mode"`

Sidecar mode has just been switched ON (the flag file was created; `sidecar.sh start` refuses to launch a worker while it is off). Confirm to the user in three lines: that `"$HOME/.claude/drive-sidecar/sidecar.sh" start --task "..."` now launches a worker on a third-party API, which spends that provider's money and none of the claude.ai rate-limit windows; that `status`, `collect --worker NAME` and `stop --worker NAME` are the rest of the lifecycle, and `collect` is what shows the diff and prices the run into the ledger; and that /sidecar-off switches it off. Mention that a provider key must be in `$HOME/.claude/sidecar-credentials` at mode 0600 or `start` will refuse. Do not treat this toggle itself as a task.
