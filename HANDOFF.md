# Handoff — session record, and a brief for the next session

## ⇒ NEXT: **decide whether the sidecar earns its keep, before adding to it**

The module is built, installed and exercised against a live provider. Nothing in
it is half-finished. What has *not* happened is a real piece of work being
delegated and the result being good enough to merge — every run so far has been
a probe written to test the machinery.

So the next session should use it in anger once, on something small and real,
and answer two things the tests cannot:

1. **Is the output worth reviewing?** A cheaper model doing work that the
   orchestrator must re-derive is a loss. Delegate something whose output is
   cheap to check — a mechanical refactor, a test to write, a doc sweep — and
   see whether reviewing it took less than doing it.
2. **Does the one-worker limit bite?** It is enforced now. If the answer is that
   you spend the time waiting, that is a finding about the design and not about
   the code.

Only then is it worth building more. The obvious candidates, in order, are
auto-collect when a worker goes idle (spend is silently unrecorded if you forget
to collect), and the `billing=time` provider once a Kaggle endpoint exists —
§10d of `modules/sidecar/DESIGN.md` says what that needs and what was already
settled about its shape.


## What this session did

**Budget module: built, installed, live.** Sensor, gate, park and resume, with
`/budget-on` and `/budget-off`. Installed over the live configuration and
verified against real numbers rather than fixtures: the sensor parsed an actual
status line payload (5h 63%, 7d 25%), the gate rendered it, `settings.json` kept
every pre-existing setting, and one backup was written. **This handoff exists
because the gate fired at 98% and told the session to write it** — the feature
verifying itself.

**One defect found and fixed in that module.** The sensor wrote `budget-state`
unconditionally, so any session without `rate_limits` — an API-key session, or
any session before its first API response — overwrote the account's real numbers
with `RATE_LIMITS=absent` and silently put the gate into fail-open. Reproduced
against the committed version, fixed, and covered by a regression test.
`DECISIONS.md` D1 carries the correction, dated. Later confirmed live inside the
DeepSeek worker, which printed `no plan limits in this session` and left the
file alone.

**Repository restructured to a core plus modules** (`DECISIONS.md` D5).
`budget/` became `modules/budget/`; installed paths deliberately did not move,
because `~/.claude/drive-budget/` is named in `settings.json` on every machine
that has this.

**Sidecar module designed and proved against a live provider.** Two background
Claude Code sessions were run on DeepSeek's Anthropic-shaped endpoint. Verified:
the session starts and does real work; `ListAgents` sees it as a peer from an
Anthropic session; messages reach it **and it answers back unprompted**; its
commit (`a5abbfa`) was checked independently rather than taken on its word; the
transcript records thinking blocks. Refuted: Claude Code's cost figure, its
transcript `model` field, and `/user/balance` are all unusable for metering.

**Tests: 193 passing**, from 107 at the start of the session. Dependency floor
held — no jq, python, perl, awk, sed or node in any shipped script.

## The first live resume failed, and is fixed

Both parked jobs fired at 14:45:05, on time, and then hung for thirty-five
minutes. `claude --bg --resume <id>` does not return while that session is still
running, and a parked session is always still running — parking ends a turn and
gates the tools, it exits nothing. The mechanism could only have worked for a
session that had already exited.

`resume.sh` now **branches on whether the parked session is still alive**. If it
is — the normal case — it clears the gate and posts a macOS notification, so the
session continues in one keystroke with its context intact; nothing outside a
session can type into it, so the person is the nudge. If the session is gone, it
starts a new one from `HANDOFF.md`, so an unattended overnight park still gets
picked up. Both paths are watchdogged.

A live test of that fix then found a second fault: `StartCalendarInterval` has
minute granularity, so every firing was "early" against a wake time recorded to
the second, and the early path exited — stranding the job, which never fires
again. `park.sh` now rounds the wake up to a whole minute and `resume.sh` waits
out gaps under two minutes.

`DECISIONS.md` D4 carries both corrections. The parked marker now holds its own
wake time and the gate expires it, so a session can no longer be left gated with
no way out — the trap that made a parked session unable to un-park itself.

## Claude Code has a built-in wait, and it has never armed on this machine

Since v2.1.234, an interactive session on a claude.ai subscription is supposed to
show `Usage limit reached · continuing automatically at 3:45pm · esc to cancel`,
wait, and continue with its context intact. On by default.

**It has never happened here.** Every transcript on this machine was searched:
zero occurrences of `continuing automatically` or `Automatic continue` outside
the session that was quoting the documentation, against **20 `five_hour`
rejections and 6 `seven_day` ones**. The installed version is well past the
requirement.

The documented exclusion that fits is *"Remote Control and agent team teammate
sessions: Claude Code doesn't start the wait on its own"*, and this machine's
sessions are Remote-Control connected. **That is a fit, not a proof.**

⇒ **The test worth running:** at the next limit, run `/rate-limit-options` and
see whether it offers **Wait here, then continue automatically**. That is the
documented manual path for exactly these sessions, and the answer decides
whether park and resume are load-bearing here or only cover the weekly case.
Until then, assume load-bearing.

`DECISIONS.md` D6 and its correction carry this. The module stays out of the
built-in's way regardless: the gate never exits non-zero so it cannot block the
continuation prompt, and the parked marker expires on its own so a continuation
cannot land on a closed gate.

## The sidecar module, built 2026-09-12

`sidecar.sh start | status | collect | stop | spend` delegates a task to a worker
on a third-party endpoint, running inside its own Claude Code session. Verified
live against DeepSeek: it wrote correct code in the surrounding style, committed
to a worktree it made itself, and handed it back.

Guards, each proved by a live run rather than by reading:

- **The credential is proved before launch.** A worker whose credential is
  rejected does not fail — Claude Code retries and falls back to the claude.ai
  login, so the work lands on the subscription and is priced as pennies.
  Measured: three 401s and the task completed anyway.
- **Pushing is refused** by a `pre-push` reached through `GIT_CONFIG_*`, which
  holds against every invocation form a permission rule misses. A worker told
  "pushing is part of the task" was refused twice and left the remote empty.
- **The budget gate does not shut workers down.** They spend another provider's
  money, so they are informed rather than denied.
- **One worker at a time**, enforced.

Cost is an estimate — the provider exposes no pricing or usage endpoint (D11 has
the 404 list) — reconciled against balance readings kept in an append-only log.
Both figures are shown, because a gap between them is information.


## What is in the way

- **The DeepSeek balance is $5.00, not the $80/month cap.** Keep probes small
  until the owner tops it up or rotates to a funded key.
- **Three questions remain open, none of them structural** — whether Claude Code
  renders MCP progress notifications in the tool panel, whether the Anthropic
  shim surfaces cache hit counts on a *warm* prefix (both probes read zero, but
  both were cold, so nothing is settled), and whether any provider other than
  DeepSeek behaves. `modules/sidecar/DESIGN.md` §11 has them.
- **The worker cannot tell what it is.** It reported `claude-sonnet-5` in good
  faith. Anything that needs the real model must be told by the launcher, and the
  ledger must never ask the worker.
- **The worker carries the orchestrator's permissions wherever it is pointed.**
  That is the decision, not an oversight — but point it deliberately, and never
  route work through it that the orchestrator's own permissions would refuse.
- **Branch `budget-mode` is unmerged**, five commits ahead of `main`. The
  repository's convention is a merge commit from a feature branch:
  `git checkout main && git merge --no-ff budget-mode`. Not done, because
  merging was never asked for.
- **Three project folders vanished from `Coding Projects` during this session** —
  `_model-eval`, `Google TPU`, `Re-Kernel`. Nothing here touched them and the
  volume is healthy; most likely archived by the owner, but it was never
  confirmed.
