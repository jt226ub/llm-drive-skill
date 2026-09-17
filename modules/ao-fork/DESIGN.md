# The AO fork — one app for every harness, with our budget and our roles

**Status** design note, 2026-09-17 · **Decision** D22 · **Scope now** Antigravity plan quota,
role profiles, workflow templates, the Drive contract inside every session. **Deferred** the
Kaggle TPU provider and its time budget (the user's call, 2026-09-17: "omit the TPU part as
something we will add later").

## 0. What was measured before deciding

Agent Orchestrator (AO, `github.com/Untrivial-ai/agent-orchestrator`, Apache 2.0, v0.13.0,
Go daemon + Electron desktop, 27 harnesses) was run against the Antigravity CLI on the
user's Google AI Pro account on 2026-09-17, from a source build of the daemon with a scratch
data directory:

| what | result |
|---|---|
| Agy worker, default permission mode | launches `agy --add-dir <worktree> --prompt-interactive "<task>"` in AO's own pty host; the agent stops at every `agy` permission prompt while the Kanban says "Working" (the adapter declares `EmitsBlockedActivity=false`) |
| Agy worker, `--permission bypass-permissions` on the project | spawn → correct code → tests green → commit in 75 s wall; the session goes `working` → `idle` |
| second turn, `ao send --session <id> --message …` | delivered into the TUI, commit 26 s later; context intact |
| billing | the TUI header shows the Pro account and "Gemini 3.8 Flash (High)"; the plan's 5-hour bar moved, no key involved |
| who talks to whom | `ao send` is harness-agnostic; a worker's system prompt ends with the exact `ao send --session <orchestrator-id>` line; the orchestrator's prompt forbids writing to the pty directly; `ao` is pinned on every session's PATH |
| upstream budget work | per-session token usage from Claude / Codex / Kimi native transcripts, a LiteLLM-derived USD catalog (`pricing/catalog/v1`), a usage summary API and page, Codex subscription capacity (5-hour and weekly windows, `near_limit` / `exhausted`, account switching), an open intake for quota-aware Claude → Codex fallback (#4918) |
| forks | 1,670, none carrying any of this; the top ones by stars have ≤ 4 and are untouched mirrors |
| prior art (2026-09-17) | no upstream issue or PR for Antigravity quota; the accepted pattern is the Codex capacity coordinator merged in #4722; the provider-neutral usage page (#4218) was rejected; the one public Antigravity quota reader (`asdfsnlr/omantigravity`, an Omarchy bar widget) uses `agy -p /usage --output-format json` |

So the shape the sidecar built by hand — a Claude orchestrator, an Antigravity coder that runs
turn by turn, per-task model choice, a quota gate — exists in AO with a live view of every
session. What AO lacks is exactly the sidecar's policy layer: the Antigravity plan quota,
named roles with rules of their own, and a way to bind roles to models for a project. That is
the fork.

## 1. Principles

- **Upstream stays the engine.** The fork adds providers and config; it does not rewrite
  the daemon, the Kanban, or the harness adapters. Every addition is a new file or a small,
  named seam, so rebases on upstream `main` stay cheap while its usage work moves.
- **Same words as the sidecar.** The roles are the user's roles (LLM Drive Skill D19): Gemini
  3.8 Flash the fast non-interactive coder, Gemini 3.1 Pro the slower expert for planning,
  review and brainstorming, DeepSeek V4.1 Flash the paid interactive expert, Qwen on the TPU
  later. A profile's rules file is the provider's existing `*.rules.md`, not new prose.
- **Quota is a reading, not a guess.** The only source for Antigravity's plan quota is the
  CLI's own `/usage` command; headless it answers as JSON in under a second (§2). Nothing
  estimates it.
- **Advisory by default, refusing by profile.** Upstream keeps Codex capacity out of launch
  admission. The fork does the same unless a profile says `refuseBelowPercent`, in which case
  a spawn is refused with a readable reason (the opaque-quota-error complaint is upstream
  issue #4995).

## 2. The Antigravity quota provider

**Seam.** Upstream's Codex capacity lives in `backend/internal/domain/codex_capacity.go`
(snapshot: state `available|near_limit|exhausted|unknown|unsupported`, one bucket per
provider meter with `primary`/`secondary` windows of `usedPercent`, `windowDurationMinutes`,
`resetsAt`), a coordinator in `service/agent/codex_capacity.go` (display TTL 2 min, read
timeout 10 s, one read in flight per account, backoff on failure) and a port
`ReadCapacity(ctx) (CodexCapacityObservation, error)` in `ports/codex_accounts.go`, merged in
#4722. A provider-neutral quota pipeline with its own page (#4218) was rejected in review —
"make the existing agent inventory/auth state the source of truth instead of independently
discovering quota accounts" — so the fork does not build one: it adds a capacity snapshot in the
Codex bucket shape (already provider-neutral in its fields) under `domain/`, a small port the
Agy adapter implements, and a coordinator with the Codex one's TTL, single-flight and backoff.

**Reader.** `adapters/agent/agy/capacity.go`: run `agy -p "/usage" --output-format json` with
`GEMINI_API_KEY`/`GOOGLE_API_KEY` unset (found 2026-09-17 via the Omarchy plugin
`asdfsnlr/omantigravity`, verified live: the slash command runs headless in under a second,
no model call, no pty). The envelope's `command.data` is structured: `groups[]` (`name`
"Gemini Models" / "Claude and GPT models", `description` naming the models) each with
`buckets[]` of `id` (`gemini-weekly`, `gemini-5h`, `3p-weekly`, `3p-5h`), `window`
(`weekly` / `5h`), `remaining_fraction` (0–1) and `reset_time` (RFC 3339). Map straight
onto the Codex bucket shape: `usedPercent = 100 × (1 − remaining_fraction)`,
`resetsAt = reset_time`, `windowDurationMinutes` 300 / 10080. `status` other than
`SUCCESS`, or an `error` naming authentication → `unknown` with reason `not signed in`; the
CLI's data-use wizard cannot appear in `-p` mode, so the reader never touches it. Display TTL
2 min and single-flight reads exactly as the Codex coordinator (`service/agent/codex_capacity.go`),
because upstream rejected a separate quota pipeline (#4218, closed: "make the existing agent
inventory/auth state the source of truth") and its later Cursor and Kimi subscription-usage
PRs (#4338, #4339, closed unmerged) were themselves written "matching the current Codex capacity
pattern". `agy -p "/model" --output-format json` returns the CLI's current default model
(`id`, `label`, `effort`) the same way, for the picker's default.

The sidecar's own reader (`antigravity-quota.py`, a pty driving the interactive `/usage`
screen, ~12 s) is superseded by the same command; switching it is a separate, later change in
the sidecar.

**Surfaces.**

- `GET /api/v1/agents/agy/capacity` (or the neutral route #4218 created) returning the
  snapshot; `ao agent ls` gains a capacity column for harnesses that report one.
- Settings: an "Antigravity" section beside "Codex accounts"
  (`renderer/components/settings/CodexAccountsSection.tsx` is the pattern) showing the four
  bars and the reset times.
- The model picker on New Task (`AgentModelPicker.tsx`) shows the Gemini bucket's percent
  left next to every `gemini-*` slug, and the Claude/GPT bucket next to `claude-*` /
  `gpt-oss-*`, since `agy models` lists both families and they draw on different meters.
- Kanban cards: nothing new; upstream's token-count-on-cards work (#5026) is where
  per-session numbers go once §2b exists.

**Admission.** A profile's `quota` block (§3) carries `warnBelowPercent` and
`refuseBelowPercent`. Spawn checks the fresh snapshot (forcing a read if stale): below warn →
a notification on the session ("Gemini 5-hour bar at 12 %, resets 14:05"); below refuse →
`ErrSpawnQuota` with the same text, surfaced in the CLI and the New Task sheet. This is the
sidecar's `_cap_reached` quota branch (0 % on either bar refuses `start`) made per profile.

**2b. Per-session attribution (second step, not first).** Upstream attributes tokens by
ingesting native transcripts (`domain/usage.go`: `claude_main`, `claude_subagent`,
`codex_rollout`, `kimi_wire`). Antigravity's TUI writes its conversation to
`~/.gemini/antigravity-cli/conversations/<id>.db` (SQLite; `steps` rows hold protobuf blobs
with the tool name, command and cwd — readable with `strings`, not yet decoded) and prints
no per-turn token line; the headless envelope does, but AO runs the TUI. Cheapest honest
attribution: a capacity reading at spawn and at each `idle` transition, charged to the
session as *percent of the 5-hour bar*, which is what the plan meters anyway ("consumed
proportionally to the cost of the tokens", the CLI's own text). Decoding the `.db` protobufs
for real token counts is a later task, filed, not designed here.

## 3. Role profiles

**Today.** `ProjectConfig` (`domain/projectconfig.go`) has one `AgentConfig` (`model`,
`effort`, `mode`, `permissions`), a `RoleOverride` (`agent` + `AgentConfig`) each for
`worker` and `orchestrator`, a `reviewers` list of (`harness`, `AgentConfig`), inline
`agentRules` plus a repo-relative `agentRulesFile` for workers, and `orchestratorRules`.
Spawn takes `--agent`, `--model`, `--mode`, `--kind`. There is no named bundle of these, so
"Flash coder" is retyped per project and the rules text has one slot per role, not per model.

**Roles, re-cut for AO (D23).** The sidecar's roster split on interactivity ("non-interactive"
Flash and Pro, "interactive" DeepSeek and TPU). In AO every session takes a next turn by
`ao send` (verified 2026-09-17: 26 s), so that axis is gone; what remains is what each model
is for and what it costs:

| profile | harness, model | role | cost rule |
|---|---|---|---|
| orchestrator | Claude Code, chat | the human-facing coordinator: AO's role text plus the contract | subscription windows |
| flash-coder | Antigravity, Gemini 3.8 Flash high | default implementer for small and larger tasks | plan quota shared with Pro; falls back to 3.7 Flash on no capacity |
| pro-expert | Antigravity, Gemini 3.1 Pro high | planning, review, brainstorming, hard bugs; also an AO reviewer harness | the same shared quota, spent on judgement not typing |
| deepseek-expert | Claude Code on the DeepSeek endpoint | paid expert and second-opinion reviewer when the free arms are down or exhausted | per token, sparingly |
| tpu-coder | deferred | | time, not tokens |

Each profile's `rulesFile` is the `## Role` section of the provider's rules file in the LLM
Drive Skill repository, so the sidecar and the fork read one text.

**Fork.** A `profiles` map, project-level and with a user-level default file
(`<data dir>/profiles.json`, project entries win by name):

```json
{
  "profiles": {
    "flash-coder":  {"harness": "agy", "model": "gemini-3.8-flash-high", "permissions": "bypass-permissions",
                     "mode": "tui", "rulesFile": "rules/flash-coder.md",
                     "fallback": {"model": "gemini-3.7-flash-high", "when": "no-capacity"},
                     "quota": {"bucket": "gemini", "warnBelowPercent": 20, "refuseBelowPercent": 0}},
    "pro-expert":   {"harness": "agy", "model": "gemini-3.1-pro-high", "permissions": "bypass-permissions",
                     "mode": "tui", "rulesFile": "rules/pro-expert.md",
                     "quota": {"bucket": "gemini", "warnBelowPercent": 20, "refuseBelowPercent": 0}},
    "deepseek-expert": {"harness": "claude-code", "mode": "chat", "permissions": "bypass-permissions",
                     "env": {"ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_API_KEY": "${DEEPSEEK_API_KEY}"},
                     "rulesFile": "rules/deepseek-expert.md"},
    "orchestrator": {"harness": "claude-code", "mode": "chat", "rulesFile": "rules/orchestrator.md"}
  }
}
```

A profile is a named `RoleOverride` plus three things upstream has no slot for: a
`rulesFile` of its own, a `fallback` (the sidecar's `fallback_model`: rerun once on the named
model when the turn ends in "No capacity", and say so on the card), and a `quota` policy.
`env` per profile is upstream's per-project `env` narrowed to one role; `${VAR}` is resolved
from the daemon's environment at spawn, never stored. Spawn gains `--profile NAME`, which
resolves harness, config, env and rules before the existing `--agent`/`--model` overrides
apply on top. Role slots (`worker`, `orchestrator`, each `reviewers` entry) accept a
`profile` name instead of an inline harness. The model slugs are whatever `agy models`
prints (AO already parses it for the picker): eleven Gemini entries in three efforts, two
Claude, one GPT-OSS.

**Where it lands in code.** `domain/projectconfig.go` (the struct and its validation),
`session_manager/manager.go` `buildSpawnTexts` (rules assembly, §5), `cli/spawn.go`
(`--profile`), the project settings sheet in the renderer. No adapter changes.

## 4. Workflow templates

A template is a named assignment of profiles to the three role slots plus the orchestrator's
standing plan — the delegation policy in words — stored beside the profiles and applied to a
project in one step:

```json
{
  "templates": {
    "flash-first": {"orchestrator": "orchestrator", "worker": "flash-coder", "reviewers": ["pro-expert"],
                    "orchestratorRulesFile": "rules/plan-flash-first.md"},
    "expert-pair": {"orchestrator": "orchestrator", "worker": "pro-expert", "reviewers": ["deepseek-expert"],
                    "orchestratorRulesFile": "rules/plan-expert-pair.md"}
  }
}
```

`ao project apply-template <project> <name>` writes the slots (it is the existing
`set-config` under the hood, so nothing else in the config moves); the desktop's project
settings sheet gets a template picker that does the same, and New Task shows which template
is active. A template never changes a profile; it only binds names. The orchestrator's
plan file is what tells the Claude orchestrator *which* profile to spawn for which kind of
task — "small and larger coding tasks to flash-coder; planning, review and brainstorming to
pro-expert; paid experts sparingly" — in the user's roster words, so the choice per task
stays the orchestrator's, as it is in the sidecar today.

## 5. The Drive contract inside every session

**Seam.** Upstream assembles each session's system prompt in `session_manager/prompt.go`:
a role section (`## AO Worker Role` or `## AO Orchestrator Role`, both AO's text), then the
project rules from `buildProjectRules` (inline `agentRules` and the repo-relative
`agentRulesFile`, joined by a blank line), then the issue context, the orchestrator
coordination line, the PR conventions. The prompt is written to
`<data dir>/prompts/<session>/system.md` and delivered per harness (for Agy, in the first
prompt; 9.6 KB in the test, a cached prefix from the second turn on).

**Fork.** AO's own role text is always first (its assembly is fixed: role, coordination line,
PR conventions, container labels, then the Project Rules slot, then Publishing Scope and the
confidentiality guard). Everything ours lives inside that slot, in this order:

1. **The contract** — the body of `skills/drive/SKILL.md`, byte-identical to what the
   Claude Code hook, the gateway path and (since D23) the sidecar's worker briefs ship.
   General "how to work" first; its own Precedence clause defers to what follows.
2. **The project's rules** — upstream's `agentRules` / `agentRulesFile`, untouched (in the
   fork's own repository that is the AGENTS.md pointer).
3. **The role's rules** — the `## Role` section of the provider's rules file (D23), the most
   specific and the last, so it also wins on recency.

AO's Publishing Scope then closes the prompt, which settles the one real tension: the
contract's §3 asks approval before pushing, AO's worker role pushes CI fixes on issue-backed
work; the contract's wording (D23) names standing role instructions as the grant.

Orchestrator sessions get the same three layers in AO's Project-Specific Orchestrator Rules
slot, the third being the template's plan file — the roster in the user's words, which
profile for which kind of task.

Size: contract ~1,500 tokens, AO base ~2,400 (9.6 KB measured), rules a few hundred; about
4,500 per session start, a cached prefix from the second turn on Antigravity.

No per-harness generation step: AO already puts one system prompt in front of every harness
it launches, which is the whole reason the contract is harness-agnostic.

## 6. Out of scope now, kept in view

- **Kaggle TPU provider and time budget** — deferred by the user. When it returns: a profile
  `tpu-coder` on `claude-code` with the sidecar's `kaggle-tpu.env` (base URL and key) via
  profile `env`, and a `session_remaining_min` reading from the kernel's `/session/quota`
  as a time bucket in the same capacity shape. AO runs Claude Code interactively, so the
  `--bg` base-URL bug (memory `claude-bg-ignores-base-url`) does not apply.
- **Codex** — the user intends to add ChatGPT Codex; upstream's capacity, account switching
  and rollout ingestion cover it, so the fork only needs a `codex-*` profile.
- **Blocked-state detection for Agy** — `EmitsBlockedActivity=false` upstream; with
  bypass-permissions there is nothing to detect, so it stays as is.

## 7. Order of work, smallest first

1. Fork `Untrivial-ai/agent-orchestrator` under the user's GitHub account; branch
   `fork/main`; CI as upstream (`go test ./...`, `golangci-lint`, frontend typecheck).
2. **Done 2026-09-17** (`feat/agy-capacity`, PR on the fork): domain + port + adapter reader
   (`agy -p /usage --output-format json`, keys scrubbed), coordinator mirroring the Codex one,
   `GET/POST /api/v1/agents/agy/capacity[/ensure]`, Settings section beside Codex accounts,
   eight locale catalogs; verified live (2.6 s, real plan numbers) and under the race
   detector. Not done, deliberately: `ao agent ls` column, admission gate (§3 quota policy).
3. Profiles: config struct, validation, `--profile`, rules layering (§5), the model picker
   percent. Verify by spawning `flash-coder` and `pro-expert` on the scratch project and
   reading the delivered `system.md`.
4. Templates: struct, `apply-template`, the settings picker.
5. Quota admission (warn/refuse) and the capacity fallback rerun.
6. Rebase on upstream `main`; repeat 2–5's checks.

Each step is a PR against the fork with its own tests; none needs the TPU.

## 8. What this does to the sidecar

The LLM Drive Skill sidecar stays the CLI-only path and the reference for the rules text,
the quota reader and the fallback rule; the fork carries the same policy into the app. When
the fork's steps 2–5 are verified live, the sidecar's `antigravity-cli` provider becomes a
thin wrapper or is retired — a later decision, not this one.
