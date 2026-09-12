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

**Correction, 2026-09-12 — it resumes nothing; it starts a new session.** The
first live firing scheduled two jobs, both fired at 14:45:05 exactly on time,
and both then hung for thirty-five minutes without logging an exit or removing
their launch agents. The scheduling half of this decision was right; the resume
half was wrong at the level of the idea.

`claude --bg --resume <id>` does not return while that session is still running.
And a parked session *is* still running: parking ends a turn and gates the
tools, it does not exit anything, so an interactive session is idle-but-alive at
wake time and "already running" is the normal case rather than an edge one. The
mechanism could only ever have worked for a session that had exited, which is
not the case it was built for. Measured on this machine afterwards:
`claude --bg "<prompt>"` on a fresh session returns in 0s with exit 0 and no
TTY, while the same command with `--resume` against a live session never returns
at all.

So the resume starts a **new** session in the parked directory and hands it
`HANDOFF.md`, which is what the gate already forces the session to write before
parking and is the only thing that needed to cross the gap. The parked session
stays gated and untouched. This is also simply better: a fresh session reading a
written brief beats the exhausted context that hit the wall in the first place,
and the session id is no longer load-bearing for anything but the marker.

Two smaller things came out of the same failure. Nothing launchd starts may be
unbounded, so the call is now watchdogged at 60 seconds and killed with a log
line if it overruns — a job that hangs forever is worse than one that fails,
because it fails silently. And the gate printed `5h -1%` on the reset, because a
window Claude Code has dropped yields -1 from the whole-percent helper; it now
says the window is fresh, since a meter that looks broken is not a meter.

Both are covered by regression tests that fail against the committed version:
the argv assertion catches `--resume`, and the reset case catches `-1%`.

**Second correction, same day — the first correction was too blunt, and a live
firing found one more fault.**

*It nudges a live session; it only relaunches a dead one.* Replacing the resume
with an unconditional fresh session threw away the thing worth keeping. A
session is left open with its context for a reason, and that context is the
expensive part; starting fresh was chosen because it worked, not because it was
right. Nothing outside a session can type into it — there is no messaging
subcommand, `--continue` refuses a session that is still running, and the only
transport is a private per-session socket this project will not depend on for
the same reason it would not read the Keychain. So the behaviour now branches on
a fact rather than a preference: if `claude agents --json` still lists the
parked session, clear the gate and post a notification, because the person can
continue it in one keystroke with everything intact; if it is gone, start a new
session from `HANDOFF.md`, so an unattended overnight park still gets picked up.
Choosing fresh context stays the person's call — `/clear` and read the handoff —
which is the right place for it.

*A firing is always early, and exiting stranded the work.* The live test of the
first correction fired and then refused to act: `woke 49s early — leaving the
job scheduled`. `StartCalendarInterval` has minute granularity, so it fires at
the top of the minute while `park.sh` had recorded the wake time to the second;
every firing was early by the seconds component. Worse, a job matching one
minute of one day never fires again, so "leave it scheduled" meant the work was
stranded with nothing to say so — the same silent-failure shape this project
exists to prevent, arrived at from a new direction. `park.sh` now rounds the
wake up to a whole minute so the recorded instant is the scheduled one, and
`resume.sh` waits out a gap of two minutes or less instead of exiting. Only a
gap too large to be clock jitter leaves the job alone.

The comment that said "launchd fired early, which it should not" was simply
wrong. It always does. Five regression tests cover this correction and all five
fail against the version before it.

---

## D5 — The contract is the core; everything else is a module in this repository

**Date** 2026-09-12 · **Status** accepted

**Context.** Budget mode was built as the only addition to the contract, and a
second addition — delegating work to a model on a third-party API — was being
designed as a separate project. Two additions with the same shape is the point
at which the shape should be named.

**Decision.** The drive contract is the core. Everything around it is a module:
off by default, switched on by its own standing flag, adding context to a turn
only when its own conditions are met, and living in `modules/<name>/` in this
repository. `budget/` became `modules/budget/`; `modules/sidecar/DESIGN.md` is
the second module, designed and not built.

Modules are Claude Code-specific by nature — they read its status line and drive
its hooks — so none of them touch `skills/drive/SKILL.md`, which stays
harness-agnostic and ships unchanged to any gateway.

**Rejected.**

- *A separate repository per module.* It would have meant a second installer, a
  second test suite, a second document, and two projects both wanting the single
  `statusLine` slot with no agreed owner. The seam between them would have been
  an accident rather than a design.
- *Renaming the installed paths to match.* `~/.claude/drive-budget/` is named in
  `settings.json` on every machine that has this and in the README's own check
  commands. Renaming it to `~/.claude/modules/budget/` for symmetry would break
  working installs to tidy a layout nobody reads. The source tree moved; the
  installed tree did not, and the installer says why at the copy.
- *`3rdPartyAgents` as the second module's name.* It says what the module does,
  which is why it belongs in the README headline where people search for it. As
  a name it fights the convention in three places at once: `/3rdpartyagents-on`
  as a command, mixed case beside lowercase `budget`, and a leading digit in a
  path. `sidecar` is one lowercase word like `drive` and `budget`.

**Consequences.** One installer, one test suite, one document, one owner of the
status line. A module that needs a status line segment gets it through an
extension point in the budget sensor rather than by competing for the slot.
Adding a third module is a directory, a flag, two commands and an installer
stanza. The cost is that this repository now carries design documents for things
that are not built, which has to be marked plainly — `modules/sidecar/DESIGN.md`
opens by saying so.
