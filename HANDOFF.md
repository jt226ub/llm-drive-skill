# Handoff — session record, and a brief for the next session

## ⇒ NEXT: **build `modules/sidecar/launch.sh`, and nothing before it**

Everything else in the sidecar module hangs off the launcher, and every design
question that could have changed its shape is now answered against a live
provider. `modules/sidecar/DESIGN.md` §10a and §10b are the evidence; read those
two sections before the rest of the document, because they overrule three things
the earlier sections say.

The command shape is already verified working. This exact form created a file,
committed it, and messaged the orchestrator back:

    cd <worktree-or-repo>
    env ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic \
        ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY" \
      claude --bg --name ds-worker --model sonnet --permission-mode auto "<task>"

Four things about it are load-bearing and were each learned the hard way:

1. **`--model sonnet`, never `ANTHROPIC_MODEL=deepseek-flash`.** Claude Code
   validates model names against its own catalog before any request leaves the
   machine. A bare provider id kills the session outright — *"There's an issue
   with the selected model"* — even though that id returns HTTP 200 from the
   endpoint by curl. `deepseek-flash[1m]` survives the main turn but still trips
   the check on auxiliary calls. DeepSeek's own mapping turns `claude-sonnet*`
   into `deepseek-flash`, so the alias is the right lever.
2. **`--permission-mode auto`, matching the orchestrator.** Do not pass
   `acceptEdits`; it is *stricter*, and it stalls the worker on the commit with
   nobody to answer — which also stops it draining queued messages.
3. **No `CLAUDE_CONFIG_DIR`.** Permissions resolve from the config directory and
   the working directory, so the default gives the worker exactly the
   orchestrator's permissions in that folder, plus the drive hook, for free. An
   isolated directory inherits nothing.
4. **No worktree machinery.** Claude Code makes one for background sessions by
   itself — two for two across the runs. The launcher needs a merge step after
   review, not a worktree step.

Then, in order: the cost ledger (`~/.claude/sidecar-ledger`, append-only, priced
from a table in this repo against token counts from the worker's transcript —
**not** from Claude Code's own figure, which overstated by ~35×), the
`statusline-extra` extension point in `modules/budget/sensor.sh`, and the
`/sidecar-on` and `/sidecar-off` commands with an installer stanza.

The key is at `~/.claude/sidecar-credentials`, mode 0600, `DEEPSEEK_API_KEY=…`.
**It is temporary and the owner intends to rotate it** once the module is built;
read it from that file rather than hard-coding it anywhere. The repository is
public — no credential may enter it.

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

`resume.sh` now starts a **new** session in the parked directory and hands it
`HANDOFF.md`, watchdogged at 60 seconds. `DECISIONS.md` D4 carries the
correction. If you see a `com.llmdrive.budget-resume.*` job still listed by
`launchctl list` long after its time, that is this bug and it is now tested
against.

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
