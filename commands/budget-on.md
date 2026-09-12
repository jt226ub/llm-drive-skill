---
description: Turn budget mode ON — pause before the 5-hour limit, document before the weekly one, resume automatically after the reset (until /budget-off)
allowed-tools: Bash(touch:*)
---

!`touch "$HOME/.claude/budget-mode"`

Budget mode has just been switched ON (the flag file was created; the hooks that read it act from the next prompt onward, in every session and in every subagent). Confirm to the user in three lines: what it now does at the 5-hour thresholds (stops starting work and writes the handoff, then closes every tool but the ones that write and commit the record, then parks the session to resume itself five minutes after the window resets), what it does at the weekly thresholds (writes the full record early, and does not schedule a resume because the window is days out), and that /budget-off switches it off. Do not treat this toggle itself as a task.
