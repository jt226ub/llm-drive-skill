---
description: Turn sidecar mode ON for a provider (default deepseek) — delegate coding work to a model on a third-party API, running inside its own Claude Code session (until /sidecar-off)
allowed-tools: Bash(~/.claude/drive-sidecar/sidecar.sh:*)
---

!`~/.claude/drive-sidecar/sidecar.sh on --provider "$ARGUMENTS"`

Sidecar mode has just been switched ON for the provider the command above printed (the argument, or deepseek when none was given; the flag file `~/.claude/sidecar-mode` now holds that name, `sidecar.sh start` refuses to launch a worker while the mode is off, and from the next prompt on a UserPromptSubmit hook injects that provider's rules of engagement — its `## Orchestrator` section — into every turn). If the command printed "no profile at", the mode did not switch on: say so and stop. Otherwise confirm to the user in three lines: which provider is active and that `"$HOME/.claude/drive-sidecar/sidecar.sh" start --task "..."` now launches a worker on it, which spends that provider's money and none of the claude.ai rate-limit windows; that `status`, `collect --worker NAME`, `stop --worker NAME` and `rules` are the rest of the lifecycle, and `collect` is what shows the diff and prices the run into the ledger; and that /sidecar-off switches it off. Mention that a provider key must be in `$HOME/.claude/sidecar-credentials` at mode 0600 or `start` will refuse. Do not treat this toggle itself as a task.
