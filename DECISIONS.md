# Decision record

Append-only. A superseded decision is marked superseded, never deleted. Each
entry says what was decided, what it beat, and what would reverse it.

The README says what the project is and how to run it; this says why it is that
and not something else.

---

## D1 — The status line is the sensor for plan rate limits

**Date** 2026-09-12 · **Status** accepted

**Context.** Budget mode has to know how much of the 5-hour and 7-day windows is
spent *before* they are spent, from a local script, on every turn, for the main
session and every subagent.

**Decision.** Read it from the JSON Claude Code pipes to the `statusLine`
command — `rate_limits.five_hour` and `rate_limits.seven_day`, each carrying
`used_percentage` and `resets_at`. `budget/sensor.sh` is that status line: it
prints the usage bar and writes `~/.claude/budget-state` for the gate to parse.

**Rejected.**

- *Hook input.* Checked against the hooks reference: **no hook event carries
  rate-limit data**, on any event. This was the first choice and it does not
  exist.
- *The transcript's `quotaLimits` record.* Real, and it carries an exact
  `resetsAt` and `rateLimitType` — but it is only written when a request has
  already been **rejected** with a 429. Six of them sit in this machine's
  transcripts. By the time it appears the work has stopped, which is the
  outcome the module exists to prevent. Kept in mind as ground truth for a
  future cross-check, used for nothing today.
- *`/api/oauth/usage`.* The endpoint exists in the Claude Code binary and is
  where the `/usage` dialog gets its numbers. It needs the Keychain OAuth token.
  A tool that scrapes the user's credentials to call an undocumented endpoint is
  the wrong foundation for something that runs on every prompt, and the machine
  it was investigated on refused the credential read on exactly those grounds.

**Consequences.** The sensor costs no tokens, makes no network call and touches
no credentials — but it claims the one `statusLine` slot in `settings.json`, so
`install.sh` refuses rather than replace an existing status line. Resolution is
only as fine as the status line's own refresh, which is every new assistant
message: one very large turn can cross a threshold and the wall together. The
data is also absent entirely for API-key sessions and before a session's first
API response, which the gate reports rather than treating as zero.

**Reversed by** a hook event gaining the same fields, which would make the
status line slot unnecessary.

**Correction, 2026-09-12.** The sensor originally wrote `budget-state` on every
run, including runs with no `rate_limits` in the payload, where it wrote
`RATE_LIMITS=absent`. That was wrong in a way the first day's testing did not
reach: `budget-state` describes the *account*, and a session with no
`rate_limits` knows nothing about the account, so writing from one destroys what
a session that does know just wrote. Two real cases hit it — every session's
first status line runs before its first API response, and any session pointed at
an API key or a non-Anthropic endpoint never carries the field at all, which a
planned DeepSeek sidecar would have triggered constantly. The result either way
is the gate reading `unknown` and failing open with the real numbers on disk a
moment earlier. The sensor now leaves the file alone unless it has limits to
report, and the gate's staleness check — which is the part that actually knows
how old is too old — decides what to do about silence. Reproduced against the
committed version and covered by a regression test.

---

## D2 — The hard threshold denies tools, with an allowlist for writing the record

**Date** 2026-09-12 · **Status** accepted

**Context.** At the hard threshold the session must actually stop. An injected
instruction to stop is exactly the kind of thing the drive contract exists
because models do not reliably follow.

**Decision.** A `PreToolUse` hook denies every tool except the set needed to
write and commit the record — Read, Write, Edit, MultiEdit, NotebookEdit, Glob,
Grep, TodoWrite, Bash — and that allowance is capped at `HANDOFF_CALLS` (25)
calls, keyed to the window's reset so a new window starts it over. Subagents get
no allowance at all: they have no record to write, so their tools close outright
and they are told to return their findings.

**Rejected.**

- *Instruction only.* Relies on compliance at precisely the moment there is a
  short-term incentive to keep going.
- *Deny everything.* Guarantees the stop and guarantees no record, which inverts
  the point.
- *An unbounded allowlist.* "Write the record" becomes an open licence to keep
  calling Read and Bash. The cap is what makes the allowance an allowance.

**Consequences.** The gate never returns `allow` — only `deny` or plain
additional context — because a hook that granted permission as a side effect of
budget accounting would be a worse bug than the one it prevents. The allowance
is shared across concurrent sessions, because the window is. And the gate
**fails open**: a missing or stale `budget-state` allows every tool and makes
the prompt hook say so on every turn, because a gate that denied tools over its
own bug would brick the session.

---

## D3 — Two thresholds per window, 97/99 and 90/97, not one

**Date** 2026-09-12 · **Status** accepted

**Context.** The original ask was to pause "within 1% of the remaining 5-hour
session" — a single threshold at 99%.

**Decision.** Two stages per window. Five-hour: wrap up at 97%, close the gate
at 99%. Weekly: write the full record at 90%, close the gate at 97%.

**Rejected.** *A single 99% threshold.* A large turn moves several percent, so
the session can cross from 97% straight into a 429 without ever landing on 99 —
losing exactly the handoff the feature exists to protect. The gap between the
two thresholds is the reserve the record gets written from.

**Consequences.** Roughly 2% of each 5-hour window is reserved rather than
spent. The weekly thresholds are deliberately much earlier than the 5-hour ones,
because hitting the weekly limit costs days rather than hours and takes every
session on the account with it. All five numbers live in `~/.claude/budget-config`,
which `install.sh` writes once and never overwrites. Percentages are truncated
rather than rounded, so the error is always on the side of acting later.

---

## D4 — The resume is a launchd agent, macOS only, and says so

**Date** 2026-09-12 · **Status** accepted

**Context.** A parked session has to restart itself five minutes after its
window resets, across a closed lid and possibly a reboot.

**Decision.** `budget/park.sh` writes a `StartCalendarInterval` LaunchAgent that
runs `budget/resume.sh`, which starts `claude --bg --resume <id>` and then
removes its own job. The per-session marker that closes the gate is written
**only after** `launchctl bootstrap` has accepted the job.

**Rejected.**

- *A backgrounded `sleep`.* Portable, and dies on reboot — the case most likely
  to happen during a five-hour wait.
- *Notify and let the user restart.* No unattended autonomy, and no resumption
  either; the feature was asked for as a resume, not a reminder.

**Consequences.** Automatic resume is macOS-only. On anything else `park.sh`
refuses and names what is missing; the gate and the record still work, and the
scheduling is the only platform-specific part, so a second trigger can be added
beside it without touching sensor, state or gate. The resumed session runs
unattended in the background and can stall on a permission prompt with nobody
there to answer — `claude agents` lists it and `claude logs <id>` shows what it
did. Ordering the marker after the bootstrap is what prevents the one failure
worse than not parking: a session gated shut with nothing coming to wake it.
