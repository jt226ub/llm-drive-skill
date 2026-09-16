# LLM Drive Skill

**drive** is an operating contract for substantive work. It targets six failure
modes: turns that end with unannounced undone work, "done" that was never run,
patches over symptoms, silent scope drift, multi-step jobs with no visible
state, and answers that bury the outcome.

The contract is harness-agnostic — it names no vendor, no tool, and no slash
command — so the same text drives Claude Code and any other model you can put a
system prompt in front of. It ships two ways:

| | Claude Code (`install.sh`) | Any LLM, via a gateway (`omniroute/install-omniroute.sh`) |
| --- | --- | --- |
| Reaches | Claude Code on this machine | every client and model through the gateway |
| Mechanism | a `UserPromptSubmit` hook, plus a `/drive` skill | `prefixPrompt`, prepended to the system prompt |
| Toggle | `/drive-on` and `/drive-off` | always on; no client can opt out |
| Needs | bash | bash, and the gateway's own CLI |

`skills/drive/SKILL.md` is the single source of truth for both. Neither
installer edits it; both strip its YAML frontmatter with the same rule and ship
the body verbatim, and the test suite asserts the two paths produce
byte-identical text.

## Modules

The contract is the core. Around it sit **modules** — Claude Code-specific
additions, each off by default, each switched on by its own standing flag, each
adding context to a turn only when its own conditions are met. They stay out of
the harness-agnostic contract entirely, because they read Claude Code's own
status line and drive Claude Code's own hooks.

| Module | Switch | What it does | Status |
| --- | --- | --- | --- |
| [budget](#budget-mode--pausing-before-a-rate-limit) | `/budget-on` | Watches the subscription's 5-hour and weekly rate-limit windows; makes the session write its handoff and park itself before one is hit. | **built** |
| sidecar | `/sidecar-on [provider]` | Delegates coding work to a model on a third-party API — DeepSeek, Kimi, GLM, anything exposing an Anthropic-shaped endpoint — running inside its own Claude Code session, so it spends that provider's money and none of the subscription's windows. A provider can also be the official Antigravity CLI run headless (`harness=antigravity-cli`), spending a Google AI Pro plan's quota instead of money, with `start --model` choosing Gemini 3.8 Flash or 3.1 Pro per task, `say` continuing a worker's conversation turn by turn, and `quota` reading the plan's 5-hour and weekly bars (D19, D20); every prompt also carries a one-line roster of the other providers and a one-line command cheat-sheet; `wait --worker NAME` blocks until a turn ends and `guide` prints the whole how-to (D21). Each provider carries rules of engagement (`providers/NAME.rules.md`): the orchestrator's section is injected per prompt while the mode is on, the worker's rides in its system prompt. `spend` shows Anthropic's windows plus each in-use provider's money, plan quota or session time, and a provider at its cap cannot be started (D17, D18). | **built**, see [`modules/sidecar/DESIGN.md`](modules/sidecar/DESIGN.md) |

Where drive governs *how* work is finished, budget governs *when it has to
stop*, and sidecar governs *who does it*.

## Install for Claude Code

```bash
git clone https://github.com/jt226ub/llm-drive-skill.git
cd llm-drive-skill
./install.sh
```

Restart Claude Code, then run `/drive-on` to switch on the standing mode.
Install alone does not enable it — it only puts the parts in place.

To let a Claude Code session do it for you, point it at the repo:

> Clone https://github.com/jt226ub/llm-drive-skill and run ./install.sh

It works three ways once installed:

- **`/drive`** — apply the contract to one task, on demand.
- **`/drive-on`** — standing mode. A `UserPromptSubmit` hook injects the
  contract into *every* prompt, in every session, until `/drive-off`.
- **`/budget-on`** — [budget mode](#budget-mode--pausing-before-a-rate-limit).
  Watches the plan's rate-limit windows and makes the session write its handoff
  and park itself before one is hit, rather than being cut off mid-sentence.
  Also standing, until `/budget-off`.

### What gets installed

Everything goes under `~/.claude`. The contract and the budget directives are
the only parts that hold content; the rest is plumbing.

| File | Role |
| --- | --- |
| `skills/drive/SKILL.md` | The contract itself — **single source of truth**. |
| `commands/drive-on.md` | `/drive-on` — creates the `~/.claude/drive-mode` flag. |
| `commands/drive-off.md` | `/drive-off` — removes the flag. |
| `hooks/drive-mode.sh` | On each prompt, if the flag exists, injects the contract. |
| `drive-budget/BUDGET.md` | The budget directives — **single source of truth** for them. |
| `drive-budget/sensor.sh` | The status line. Publishes the plan's rate-limit windows. |
| `drive-budget/gate.sh` | Reads them on each prompt and each tool call, and acts. |
| `drive-budget/park.sh` | Schedules a session's own resume; `--status`, `--cancel`. |
| `drive-budget/resume.sh` | What the scheduler runs when the window has reset. |
| `commands/budget-on.md` | `/budget-on` — creates the `~/.claude/budget-mode` flag. |
| `commands/budget-off.md` | `/budget-off` — removes the flag. |
| `budget-config` | Thresholds. Written once, never overwritten by a reinstall. |

`install.sh` also edits `~/.claude/settings.json`: the drive hook and the budget
prompt hook under `hooks.UserPromptSubmit`, the budget tool gate under
`hooks.PreToolUse`, and the sensor as `statusLine`. It backs the file up once
per run, merges rather than overwrites, and skips anything already registered,
so re-running is safe and other hooks survive. **An existing `statusLine` is
never replaced** — install reports it and exits non-zero, because the status
line is the one slot the sensor needs and taking over someone's own line
silently is worse than not installing.

## Budget mode — pausing before a rate limit

`/budget-on` makes a session watch the plan's own rate-limit windows and stop on
its own terms rather than being cut off mid-sentence by a 429. It is a standing
mode like drive mode: on for every session and every subagent, or off for all of
them, until `/budget-off`.

| The 5-hour window reaches | What happens |
| --- | --- |
| 97% (`WRAP_PCT`) | Stop starting work. Write `HANDOFF.md`, commit it, park the session. |
| 99% (`STOP_PCT`) | Every tool but the record-writing set is **denied**, and that allowance is capped at 25 calls. |
| parked | The session schedules its own resume for five minutes after the window resets, and closes completely. |

| The 7-day window reaches | What happens |
| --- | --- |
| 90% (`WEEK_DOC_PCT`) | Write the full record now — this limit costs days, not hours. Then carry on. |
| 97% (`WEEK_STOP_PCT`) | Same hard gate. **No automatic resume**: the reset is days out, too far to schedule against. |

Subagents get a shorter path. At either hard threshold their tool access closes
outright and they are told to return their findings — a subagent has no record
to write, and the session that dispatched it does.

### Where the numbers come from

Claude Code publishes plan rate-limit utilisation in exactly one place a local
script can read: the JSON it pipes to the `statusLine` command.

```json
"rate_limits": {
  "five_hour":   { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day":   { "used_percentage": 41.2, "resets_at": 1738857600 },
  "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }
}
```

So the sensor is a status line: it prints the usage bar you see and writes
`~/.claude/budget-state` for the gate to read. It costs no tokens, makes no
network call, and touches no credentials.

The alternatives were checked and rejected. **No hook event carries rate-limit
data** — not one, per the hooks reference. The transcript's `quotaLimits` record
is real but only written when a request has *already* been rejected with a 429,
which is after the work has stopped. `/api/oauth/usage` exists but needs the
Keychain OAuth token, and a tool that scrapes your credentials to call an
undocumented endpoint is the wrong foundation for something that runs on every
prompt.

### Resuming

Parking writes a `launchd` agent that fires `claude --bg --resume <id>` five
minutes after the window resets, and a per-session marker that shuts the gate.
The marker is written only after launchd accepts the job, so a session is never
left gated shut with nothing coming to wake it.

```bash
~/.claude/drive-budget/park.sh --status               # what is scheduled
~/.claude/drive-budget/park.sh --cancel --session ID  # drop one
~/.claude/drive-budget/park.sh --cancel --all         # drop all
```

`~/.claude/budget-resume.log` is the only record of what the unattended resumes
did; both `uninstall.sh` and `--cancel` leave it alone.

### Honest limits

- **It reduces the chance of a 429; it does not eliminate it.** The numbers
  refresh when the status line re-runs, which is on every new assistant message.
  One very large turn can cross 97% and the wall together, with no message in
  between for the gate to act on.
- **`rate_limits` only exists for Claude.ai Pro and Max subscribers** (or behind
  a gateway with spend limits), and only after the first API response in a
  session. Until then there is nothing to act on, and the prompt hook says so
  rather than staying quiet. A session without them — one on an API key or a
  non-Anthropic endpoint, or any session before its first response — leaves
  `budget-state` alone rather than overwriting it: the file describes the
  account, not the session, and a session that cannot see the account's limits
  has nothing to say about them.
- **The gate fails open, loudly.** If `budget-state` is missing or over an hour
  old, tool calls are allowed and the prompt hook reports it every turn. A gate
  that denied tools over its own bug would be worse than one that does nothing.
- **Automatic resume is macOS only.** `launchd` is what survives a closed lid
  and a reboot. Everywhere else `park.sh` refuses and says what is missing; the
  gate and the record still work.
- **A resumed session runs unattended in the background.** It can stall on a
  permission prompt with nobody there to answer. `claude agents` lists it and
  `claude logs <id>` shows what it did.
- **The record allowance is shared**, because the window is: two concurrent
  sessions past the hard threshold draw on the same 25 calls.
- Percentages are truncated, not rounded, so 96.9% does not trip a 97%
  threshold. The error is always on the side of acting later.

## Install for any other LLM

```bash
./omniroute/install-omniroute.sh
```

Ships the same contract into [OmniRoute](https://github.com/diegosouzapw/OmniRoute)'s
Global System Prompt, so every client and model routed through the gateway
receives it. See [omniroute/README.md](omniroute/README.md) for the base-URL and
CLI options, and for a measured note on which providers hold up under the added
context.

Any other gateway or client that accepts a system prompt works the same way:
take the body of `skills/drive/SKILL.md` below its frontmatter and prepend it.
Nothing in the contract depends on Claude Code, on tools being available, or on
slash commands existing.

## No dependencies

Nothing here needs jq, node, perl, python, awk or sed. The floor is `bash` and
the coreutils that come with it.

That is a deliberate correction, not a boast. The hook originally built a JSON
`additionalContext` envelope with `jq`. `jq` is absent on most Windows machines,
and its absence was **silent**: the broken pipeline still let the script
`exit 0`, so drive mode never engaged and never said why. Several installs hit
that and had to work around it.

The first fix tiered `node`, then `perl`, then a paste-this-yourself fallback.
That narrowed the problem instead of solving it — `node` is not on `PATH` when
Claude Code is installed as a native binary, `perl` is missing from minimal
containers, and Windows ships `python`/`python3` App Execution Alias shims that
satisfy `command -v` and then exit without running anything.

So the JSON handling moved into bash. `lib.sh` holds a scanner that locates and
rewrites members of `settings.json` in place; every other byte — key order,
indentation, whatever you hand-wrote — is left exactly as it was. The hook runs
no subprocess at all.

| Situation | What happens |
| --- | --- |
| No `settings.json`, or an empty one | Created, then registered into. |
| Hook already registered | Left alone; no backup written. |
| Existing content | Merged into, backup written first. |
| Not valid JSON, or `hooks` is not an object | Refused and left untouched; the snippet is printed to paste. |

Honest limits, all covered by the test suite:

- A **minified** `settings.json` comes back valid but mixed-format — the
  inserted block is indented, the rest stays on one line.
- Editing scales linearly with file size: about **0.15 s** for a typical 3.5 KB
  `settings.json`, **2.4 s** for a 30 KB one. Chunked indexing is what keeps
  that linear; reading the document character by character made it quadratic,
  and a 100 KB file took nine seconds.
- Keys written with `\u` escapes are compared raw and so will not match. Real
  `settings.json` keys are plain ASCII.
- Setting `CLAUDE_DIR` to something other than `~/.claude` installs the files
  there, but the hook and the two slash commands still read the flag and the
  skill from `$HOME/.claude`. `install.sh` says so when you do it.

## Checking a machine

Rolling this out to a second machine raises an obvious question — is drive mode
actually running there, and on which contract? Both answers are one line, and
both should be asked of *behaviour*, not of the source text:

```bash
# Is the standing mode actually injecting anything?
bash ~/.claude/hooks/drive-mode.sh | head -1

# Which contract is installed?
grep -q 'Harness-agnostic' ~/.claude/skills/drive/SKILL.md && echo current || echo pre-1.5
```

A working install prints `DRIVE MODE IS ON …`. Silence means one of two things:
the flag is simply off (check that `~/.claude/drive-mode` exists — `/drive-on`
creates it), or the hook is broken. **The broken case is silent by design**, and
it is the one that motivated all of this: the old hook piped through `jq`,
and where `jq` was missing the pipeline failed while the script still exited 0
— so drive mode injected nothing and said nothing about it. Measured on an old
install with `jq` off `PATH`: 0 bytes emitted, exit code 0. The current hook
emits the full contract with `PATH` empty entirely.

Do **not** try to tell the versions apart by grepping the hook for `jq`. The
current hook names `jq` in a comment explaining why it no longer uses it, so
`grep -c jq` returns 1 for both the old and the new script. Run the hook
instead.

Budget mode is checked the same way — by behaviour, and at the sensor first,
because everything else depends on it:

```bash
# Is the sensor reporting? These are the numbers the gate acts on.
cat ~/.claude/budget-state

# What would the gate do right now?
printf '{"session_id":"x","tool_name":"Bash"}' | bash ~/.claude/drive-budget/gate.sh prompt

# Is anything scheduled to resume itself?
~/.claude/drive-budget/park.sh --status
```

The gate prints `Budget: 5h N% …` when it is working. Silence means the flag is
off (`~/.claude/budget-mode` — `/budget-on` creates it). `NO USAGE DATA` means
the sensor is not running: check that `statusLine` in `settings.json` still
points at `drive-budget/sensor.sh`, and that Claude Code has been restarted
since it was installed. A `budget-state` file whose `UPDATED` stamp is hours old
says the same thing.

## Tests

```bash
./tests/run-tests.sh
```

192 assertions. A JSON editor written by hand is only defensible against
evidence, so the suite covers the shapes a real `settings.json` takes — no
`hooks` key, `hooks` without `UserPromptSubmit`, an existing foreign entry,
minified, tab-indented, unicode and quoted prose — and asserts valid JSON out,
unrelated settings preserved, a full install/uninstall round trip that restores
the file byte for byte, and a refusal that leaves a malformed file untouched
rather than guessing.

It also asserts the two copies of the frontmatter rule stay byte-identical, that
no shipped script invokes any of the tools listed above, and that the hook still
emits the whole contract with `PATH` set to nothing at all — a direct regression
guard on the silent failure described above. Verified on bash 3.2.57, the
version macOS ships as `/bin/bash`; newer bash is untested here.

The budget module is held to the same standard, because it can deny tool calls
and schedule unattended work. The suite feeds the sensor the payload shapes the
status line reference says occur — windows in either order, any window
independently absent, no `rate_limits` at all — and asserts that an absent
`five_hour` never reads `seven_day`'s number, which would leave the gate silent
at the wall. It drives the gate through every threshold and asserts what each
one does: which tools are denied and which are let through, that the record
allowance is bounded and resets with the window, that a subagent is closed
outright, that parking one session does not gate another out of writing its own
record, and that a stale state file leaves the gate **open** with the prompt
hook saying so. Parking runs against a stubbed `launchctl`, so the suite asserts
the launch agent's contents and that a refused bootstrap leaves nothing behind,
without registering a job on the machine running the tests.

`python3` is used for independent JSON validation when present. It is a
developer convenience only — nothing in the installed product needs it — and
those checks report `skip` rather than passing quietly when it is missing.

## Editing the contract

Edit `skills/drive/SKILL.md` and nothing else.

**Size budget:** both installers refuse a contract body over 9,000 characters.
In standing mode the whole body rides on *every* prompt, so its length is a cost
paid per turn. The number is self-imposed: it was originally a guard against a
10,000-character `additionalContext` cap the stdout path no longer goes
through, and OmniRoute would accept 50,000 — but one `SKILL.md` has to fit both
targets, and the per-turn cost was always the better reason to keep the contract
tight. It currently runs 7,168 characters.

## Removing it

```bash
./uninstall.sh
```

Cancels every scheduled resume first, while `park.sh` is still on disk to cancel
them with — a `launchd` job left behind would fire into a machine with nothing
to serve it. Then deletes the installed files and both flags, and deregisters
from `settings.json` (backup written). It removes only the entries naming
`drive-mode.sh` or `gate.sh`, and a `statusLine` only if its command names our
`sensor.sh`, leaving anyone else's hooks and status line in place, and drops the
`hooks` key only if that emptied it. Earlier backups, `budget-config` and
`budget-resume.log` are left behind deliberately — one holds thresholds you may
have tuned, the other is the only record of what the unattended resumes did.

## Where it helps, where it costs

Worth it for multi-step engineering work, where the discipline pays for itself
in verified finishes. Pure overhead for quick questions and chat — the standing
mode spends context on every prompt regardless of the task, which is why
`/drive-off` and the one-shot `/drive` both exist. The gateway deployment has no
such escape hatch by design, which is the trade it makes for reaching
everything.
