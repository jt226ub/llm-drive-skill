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

---

## D6 — The module defers to Claude Code's own automatic continue, and never blocks it

**Date** 2026-09-12 · **Status** accepted

**Context.** Claude Code has waited out a usage limit and continued the task by
itself since v2.1.234, **on by default** in interactive sessions signed in with a
claude.ai subscription. It shows `Usage limit reached · continuing automatically
at 3:45pm · esc to cancel`, keeps the conversation, and resumes at the reset.
That is most of what this module's park-and-resume half was built to do, found
after building it.

**Decision.** The module does not compete with it. It never blocks the
continuation prompt, and the parked marker now carries its own expiry so a
continuation cannot land on a closed gate.

The marker holds the wake time and the gate removes it once that passes, without
consulting the sensor. Two reasons, either sufficient. The built-in resumes at
the reset, which is *earlier* than the scheduled wake, so a marker only the wake
job could clear would gate that continuation into uselessness. And a parked
session cannot un-park itself — the gate denies the very tools it would need —
so a marker that outlives its window with no way to clear itself is the worst
state this module can produce. A marker with no readable timestamp is treated as
spent, which is the fail-open direction.

**Rejected.**

- *Deleting park and resume.* The built-in covers the five-hour case in an open
  interactive session and nothing else. It explicitly does not start a wait for
  a reset more than 24 hours away — "a weekly limit can reset days out" — nor in
  Remote Control or agent-team teammate sessions, and "the wait doesn't restart
  when you resume the session" after exiting. Those are the cases park still
  serves.
- *Having the gate block to force the handoff.* A `UserPromptSubmit` hook that
  blocks the continuation prompt ends the built-in's wait outright. The gate
  never exits non-zero and never will.

**Consequences.** The module's centre of gravity moves to the half that has no
built-in equivalent: stopping *before* the wall with a written record, closing
subagents, and showing the windows on the status line. The built-in is reactive
— it acts once you have already hit the limit, mid-task, with nothing written
down. Park and resume are now the minority case rather than the headline, and
the README should say so rather than implying this is the only way to survive a
limit.

**Reversed by** the built-in gaining a weekly-limit wait and surviving a session
exit, which would leave park with nothing to do.

**Correction, 2026-09-12 — the built-in has never actually armed on this
machine, so park is not redundant after all.**

D6 was written from the documentation an hour after reading it, and the owner
said he had never seen automatic continue happen. He was right. Searched every
transcript on this machine: **zero** occurrences of `continuing automatically`
or `Automatic continue` outside the session that was quoting the documentation,
against **20 `five_hour` rejections and 6 `seven_day` ones**. The feature is on
by default, the installed version is well past the v2.1.234 it requires, and it
has still never started a wait here.

The documented exclusion that fits is *"Remote Control and agent team teammate
sessions: Claude Code doesn't start the wait on its own"* — and this machine's
sessions are Remote-Control connected, which the harness reports when they
message one another. That is a fit, not a proof: the definitive test is to run
`/rate-limit-options` at the next limit and see whether the menu offers to start
a wait, which is the documented manual path for exactly these sessions.

So the conclusion in D6 stands as written about the *feature* and was wrong
about *this machine*. Park and resume cover the five-hour case here in practice,
not only the weekly one. Nothing in the decision changes — the gate still must
never block the continuation prompt, and the marker still must expire on its own
— because if the built-in ever does arm, all of that is exactly what keeps the
two from colliding. What changes is the emphasis: park is load-bearing here
until `/rate-limit-options` shows otherwise.

Twice today a conclusion of mine needed correcting by evidence rather than
reasoning, both times in this decision's neighbourhood. The lesson worth keeping
is the cheap one: a documented default is a claim about the software, not about
the machine in front of you, and the transcripts were one grep away.

---

## D7 — The delegate is a skill over bash, not an MCP server

**Date** 2026-09-12 · **Status** accepted

**Context.** `modules/sidecar/DESIGN.md` drew the delegate as an MCP tool, so
that delegating would appear in the transcript as a typed tool call.

**Decision.** It is a shell script the orchestrator runs with Bash. A Bash call
is already a tool call in the transcript, which was most of what MCP bought.

**Rejected.** *An MCP server.* Speaking MCP means JSON-RPC framing and parsing,
and this project ships no JSON runtime on principle — jq was removed because a
missing tool failed silently. Hand-writing the protocol in bash is a worse
version of the same bet: several hundred lines of parser whose failure mode is
a wedged stdio loop. MCP remains open if the transcript ergonomics ever justify
that cost.

**Consequences.** No live progress inside a tool panel; watching a worker means
`claude attach`. The module gains nothing to maintain beyond five small files,
and `sidecar.sh` is runnable and debuggable by hand, which an MCP server is not.

---

## D8 — A worker's credential is proved before launch, because a rejected one does not fail

**Date** 2026-09-12 · **Status** accepted

**Context.** The module's entire claim is that a worker spends the provider's
money and none of the claude.ai subscription's rate-limit windows. Setting
`ANTHROPIC_BASE_URL` and a credential variable was assumed to be enough.

It is not, and the measurement is unambiguous. A background worker launched with
a deliberately wrong key logged **three 401s from the provider and then completed
the task anyway** — Claude Code retries a rejected credential and falls back to
the saved claude.ai login. The work lands on the subscription while the ledger
prices it as the provider's pennies: the module silently spends the exact thing
it exists to protect, and under-reports it by a factor of hundreds.

`claude -p` does not do this — a wrong key there returns a synthetic result with
zero tokens. The fallback belongs to the background/interactive path, which is
the path this module uses.

**Decision.** `start` proves the credential against the provider's own endpoint
before launching anything: one request, one token, and the launch is refused
unless it answers HTTP 200. A rejection, an unreachable host and any other status
all refuse. `collect` additionally refuses to price a run whose transcript shows
an authentication error, which is the case a preflight cannot see because the
credential stopped working part-way through.

**Rejected.**

- *Trusting the environment variables.* That is what was done, and it is how the
  bug shipped through a live end-to-end test that looked like a success: the
  worker produced a correct commit, so every visible signal said it worked.
- *Detecting it afterwards from the transcript's message ids.* Tried, and wrong:
  Claude Code stamps its own `msg_...` ids regardless of which endpoint served
  the request, so a known-DeepSeek transcript and a suspected-Anthropic one look
  identical. A conclusion was drawn from that and had to be retracted within the
  hour. The provider's own HTTP status is the only signal that cannot lie.
- *`--bare`, which never reads OAuth and so cannot fall back.* It would give the
  guarantee structurally, but it also skips hooks, skills and CLAUDE.md — the
  worker would lose the drive contract and the inherited permissions that D6's
  neighbours established as the point of running a real session. Worth
  revisiting if the preflight ever proves insufficient.

**Consequences.** `curl` becomes a dependency of this module, and its absence is
a refusal rather than a skipped check — an unverifiable launch is the failure the
guard exists to prevent. Every launch costs a handful of provider tokens before
any work starts. In exchange, "delegated" stops being an assumption.

**The lesson worth keeping:** a live end-to-end test that produces the right
artefact proves the work happened, not where it happened. Money moved is a
different claim from work done, and it needs its own evidence.

---

## D9 — Two push guards that fail differently, because the permission rule alone does not hold

**Date** 2026-09-12 · **Status** accepted

**Context.** A sidecar worker hands work back as a branch for the dispatching
session to review and merge. Pushing skips that review and does it unattended.
`--disallowed-tools "Bash(git push *)"` was assumed to prevent it; a worker
pushed to a real remote anyway, verified against a bare repository that received
the commit.

**Decision.** Three layers, and only the first two are relied on.

1. *A refusing `pre-push`, reached through `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0`
   setting `core.hooksPath` at launch.* Environment is inherited by every git
   process however it is spelled, so the invocation form is irrelevant. The
   repository's own hooks are symlinked in beside it, because `core.hooksPath`
   replaces the hooks directory rather than adding to it and a repo's
   `pre-commit` would otherwise stop running inside the worker.
2. *A `PreToolUse` hook that denies a worker's Bash calls mentioning a git
   push.* The permissions reference recommends exactly this — "to inspect the
   full command text with your own logic before it runs, use a PreToolUse hook".
   It identifies a worker by matching the session id against the launcher's own
   records, and does nothing at all otherwise, because it runs in every session.
3. *The permission rule*, kept because it costs nothing, and the brief telling
   the worker what the hand-off looks like.

**Rejected.**

- *The permission rule as the guarantee.* The reference names `Bash(git push *)`
  as its own example of a rule's limits, listing `git -C . push`,
  `git -c … push` and `git 'push'` among what it misses. The original rule was
  also simply the wrong syntax — `Bash(git push:*)` matches a command starting
  literally with `git push:`, which never occurs.
- *Sandbox network isolation.* Enforces regardless of command text, but the
  worker needs the provider's API, so it means an allowlist — and it does
  nothing about a filesystem-path remote.
- *Giving the worker a clone with no remote.* Absolute, and it replaces the
  worktree hand-off with a fetch-from-the-worker model: the most machinery, and
  it discards a worktree that Claude Code currently provides free.

**Consequences.** Neither guard is sufficient alone and that is the point: the
git hook cannot see a publish that is not git, and the hook cannot see an
obfuscated command. Both fail open — a session the second cannot identify is
treated as not a worker, because gating an ordinary session over a failed lookup
would be worse than the bug being prevented.

**Verified live**, which the earlier claim never was: a worker told "Pushing is
part of the task" attempted `git push -u origin worktree-append-mango`, was
refused twice, left the remote empty, and still committed its work to the
branch. In isolation the git hook also refused all five invocation forms the
permissions reference lists as defeating a rule.

---

## D10 — The worker's system prompt is corrected, not replaced

**Date** 2026-09-12 · **Status** accepted

**Context.** A worker runs on a third-party model under Claude Code's default
system prompt, which describes a Claude model. Asked directly what it was, a
DeepSeek worker answered "Model ID: claude-sonnet-5" in good faith, and workers
signed commits with Claude co-authorship. The question was whether to give them
a generic, model-agnostic worker prompt instead.

**Decision.** Keep the default and append a correction naming the real provider
and model, telling the worker not to describe itself as a Claude model and not
to put Claude attribution in commits.

**Rejected.** *Replacing it with a derived prompt via `--system-prompt`.* The
default is obtainable — a transcript records it, 30,897 characters — so this was
possible rather than merely hard. Three things argue against it. Most of that
text is harness knowledge: how the tools behave, how permissions work, how files
are handled, which is the entire reason for running a worker inside Claude Code
instead of writing an agent loop. It is nearly free: a stable prefix sits in the
provider's automatic cache and bills at a fraction after the first call, which is
what the measured 97% hit rate is made of. And the observed problem was narrow —
identity, not capability — so discarding 31,000 characters of true statements to
fix a handful of false ones is the wrong trade. Revisit if a worker is ever
measured to perform worse *because* of the prompt rather than because of the
model.

**Consequences.** The correction is a few hundred characters on a cached prefix.
Verified by behaviour rather than by reading the prompt: a worker asked to write
down what it runs on wrote `deepseek-flash`, where it had previously reported
`claude-sonnet-5`, and its commit carried no Claude attribution.

---

## D11 — Prices are hand-maintained and dated, because nothing can fetch them

**Date** 2026-09-12 · **Status** accepted

**Context.** The spend figures rest on a price table. The obvious question is
whether the provider can supply it, and whether a period's cost can be read back
authoritatively rather than estimated.

**Decision.** The table stays in the repository, carries a `checked` date, and
`start` says how old it is when that exceeds 30 days — before the credential is
read or any request is made, so it can be fixed before the run it would
mis-price. The orchestrator may update the file.

**Rejected — because they do not exist, not because they were weighed.** Probed
directly: `/models` returns `{id, object, owned_by}` and no prices. Every cost or
usage shape returns 404 — `/user/cost`, `/user/billing`, `/billing/usage`,
`/dashboard/billing/subscription`, the OpenAI-style
`/v1/dashboard/billing/usage?start_date=…&end_date=…`, `/user/balance/history`,
`/user/usage_summary`. The provider exposes exactly `/models` and `/user/balance`,
the latter a point-in-time figure. So there is no pricing endpoint to read and no
period cost to pull; a local estimate against a dated table is not a shortcut,
it is the only thing available.

**Consequences.** A spend figure is an estimate and is labelled as one. The one
authoritative money signal left is the balance, which would give real
month-to-date spend by differencing samples — coarse at $0.01 and laggy, but the
cap is $80/month where neither matters. Not built yet; it is the remaining piece.

---

## D12 — One worker at a time, enforced rather than intended

**Date** 2026-09-12 · **Status** accepted

**Context.** One worker was decided early, so that the orchestrator reviews each
result before the next task starts. Nothing enforced it: `start` would launch a
second alongside the first.

**Decision.** `start` refuses while any worker record exists, and names the
worker and the command to clear it.

**Rejected.** *Leaving it as a convention.* Two workers means merging unverified
work from two sources into one tree, which is the thing the review step exists to
prevent — and a convention that the tool will happily break is not a constraint.

**Consequences.** Parallel delegation needs a deliberate change rather than
happening by accident. A worker that is stopped without being collected still
frees the slot, since `stop` removes the record.

---

## D13 — Real spend comes from differencing balance readings, and the readings are kept

**Date** 2026-09-12 · **Status** accepted

**Context.** D11 established that the provider exposes no pricing and no cost or
usage endpoint. The estimate — a hand-maintained table applied to transcript
token counts — was therefore the only figure, and nothing could check it.

**Decision.** Sample `/user/balance` at launch and at collect, append each
reading to `~/.claude/sidecar-balance`, and derive month-to-date spend from
them. `spend` reports both figures side by side, and the status line shows both
when both exist.

Spend is the **sum of the falls** between consecutive readings, not first minus
last. A top-up raises the balance, and first-minus-last would read that as the
month costing less or as negative spend. Counting only the falls is correct
whether or not anyone tops up and needs no separate baseline to keep in step.
Fewer than two readings in a month reports "not yet" rather than zero, because
one reading is a number and not a measurement.

**Rejected.**

- *Replacing the estimate.* They answer different questions — the estimate
  attributes cost to one run, the balance knows only the account — and a gap
  between them is information. Both are shown so a disagreement is visible.
- *Storing a running total instead of the readings.* The raw readings survive a
  wrong derivation; a total does not. This is also why the log is append-only
  and why `uninstall` leaves it, alongside the ledger.

**Consequences.** Granularity is the provider's, $0.01, and the reading lags —
it showed 5.00 through several confirmed runs earlier today. Neither matters for
a monthly cap of $80. A provider with no balance endpoint omits the two profile
keys and degrades to the estimate alone.

**A third instance of one bug class, and the one that finally names it.** The
sampler passed `__key` to `_credential`, which declares `local __key` itself, so
the eval assigned the helper's own local and the caller received an empty
credential — the request went out with `Bearer` and nothing after it, and the
reading silently never happened. The `__` prefix convention adopted after the
first two occurrences does not prevent this, because the helpers use `__` names
too. Only a name the helper does not use works. Every call site that returns
through `eval "$1=..."` is worth reading with that in mind.


## D14 — The endpoint pair travels in a settings file as well as the environment
**Date** 2026-09-13 · **Status** accepted

**Context.** The launch put `ANTHROPIC_BASE_URL` and the credential variable in
the worker's environment and nowhere else, so that the credential never appears
on a command line (`ps` is readable by every account on the machine). On
2026-09-13 a worker launched that way from a shell inside another `--bg`
session — the Anthropic Sidecar project's orchestrator, a background job — made
no request to its endpoint and finished the task on the claude.ai login, the
exact failure the preflight exists to prevent, and the preflight cannot see it
because the preflight is a `curl`, not a `claude`. Three controlled runs against
a listener on this machine: `claude -p` with the pair in the environment reached
it; `claude --bg` with the pair in the environment, inherited or `env -i`, did
not; `claude --bg --settings` with the pair in a settings `env` block did.

**Decision.** Write `{"env":{"<cred_var>":"…","ANTHROPIC_BASE_URL":"…"}}` to
`~/.claude/sidecar-run/<worker>.settings.json`, mode 0600, and pass it with
`--settings`. The environment is still set, so a Claude Code that honours it
loses nothing. `stop` removes the file with the worker's other records.

**Rejected.**

- *A JSON literal on the command line.* Works, and puts the credential in `ps`
  — the property the environment route was chosen for.
- *A repository-level `.claude/settings.local.json`.* Would redirect every
  session in that repository, including the orchestrator, which the design
  forbids (§3: the orchestrator never talks to a non-Anthropic endpoint).
- *Switching the worker to `claude -p`.* Honours the environment, but is not a
  peer session: no `ListAgents`, no `SendMessage`, no transcript to collect.

**Consequences.** The credential lives in one more 0600 file for the worker's
lifetime. A test now asserts the file's location, contents, mode and JSON
validity, that a quote or backslash in a credential survives the escaping, and
that `stop` removes it. Whether a future Claude Code honours the environment for
`--bg` again does not matter; the settings route is the one relied on.

## D15 — Rules of engagement live in `providers/NAME.rules.md`, read by the hook and by `start`

**Date** 2026-09-13 · **Status** accepted

**Context.** One worker at a time was enforced (D12) but no provider-specific
guidance reached either party: the orchestrator did not know how to pace a
given provider, and the worker's brief was the same for every model. The user
asked for per-model rules — Kaggle as a rapid iterative coder fed many queued
tasks at a stated rate — with the single-worker rule kept.

**Decision.** A markdown file per provider with `## Orchestrator` and
`## Worker` sections. `sidecar-mode.sh` (UserPromptSubmit, flag-gated like
drive mode) injects the Orchestrator section, capped at 15 lines by test;
`sidecar.sh rules` prints it in full; `start` appends the Worker section to the
system-prompt brief. `/sidecar-on NAME` records the provider in the flag file,
which `start`, `rules` and the hook read as the default.

**Rejected.** Prose in the `.conf` profile; one global rules block; a longer
per-prompt injection (the drive contract already costs ~120 lines a turn);
telling the worker the orchestrator's section.

**Consequences.** Every prompt in sidecar mode carries up to 16 more lines. A
provider with no rules file behaves exactly as before. Launchers that know a
session's real numbers (Anthropic Sidecar for Kaggle) own their provider's
rules file and rewrite it at READY.

## D16 — The Gemini CLI is a worker shape of its own, launched headless in a sidecar-made worktree

**Date** 2026-09-14 · **Status** accepted (built against a stub; live run pending the user's login)

**Context.** The user's Google AI Pro plan grants Gemini CLI 1,500 model requests a day
and no API key. Google's terms forbid using the CLI's OAuth from other software and
Google suspended accounts for it. The sidecar assumed Claude Code as the only harness.

**Decision.** A profile key `harness=gemini-cli`. `start` creates the worktree and
branch, runs `gemini -p … -o json --approval-mode yolo --skip-trust` in it with the
push guard in the environment, and records a pid. `status`/`stop` work from the pid;
`collect` reads the CLI's JSON stats and counts requests against `daily_requests`
(`billing=requests`); the brief and the provider's Worker rules ride in the prompt.

**Rejected.** OAuth proxies exposing `/v1/messages` (terms violation, suspensions);
`GEMINI.md` in the worktree (shows in the diff, clobbers a repo's own); the CLI's
`-w` worktree flag (location undocumented); a Gemini API key (paid, separate).

**Consequences.** Two worker shapes to keep in step; no peer messaging with a Gemini
worker; a second ledger (`sidecar-requests`, requests not money). The rules-of-engagement
feature (D15) carries over unchanged.

## D17 — `spend` reports the three kinds of cost, and a reached cap refuses `start`

**Date** 2026-09-14 · **Status** accepted · supersedes the advisory cap

**Context.** The user runs three kinds of allowance through the sidecar — API money
(DeepSeek), Kaggle's TPU session time, and subscription usage (Anthropic's windows;
Gemini's daily requests) — and asked for all three printed, Anthropic always, workers
only while in use, and for a provider at its cap to be unusable.

**Decision.** `spend` prints Anthropic from the budget sensor's state, then one line per
in-use provider by billing kind. `_cap_reached` decides per kind (money: higher of
estimate/billed vs `CAP_USD`; requests: today vs `daily_requests`; time: a fresh session
reading at 0) and `start` refuses on it before launching anything.

**Rejected.** Keeping the cap advisory (the user's ask); listing every profile (noise);
enforcing caps inside a running worker (nothing in the sidecar sits in the request path
of a Claude Code or Gemini CLI worker — the cap holds at the next `start`).

**Consequences.** A worker already out finishes past the cap. Time caps rely on the
provider's own reading (the Kaggle kernel stops itself at its cap anyway).
