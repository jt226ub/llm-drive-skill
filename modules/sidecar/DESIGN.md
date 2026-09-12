# sidecar — design

**Status: design only. Nothing here is built.**

The third-party-model module of the drive skill. It delegates coding work from a
Claude Code session to a model on another provider — DeepSeek, Kimi, GLM,
anything exposing an Anthropic-shaped endpoint — without leaving the Claude Code
harness and without spending the Claude subscription's rate-limit windows on it.

The orchestrator stays Opus on the claude.ai subscription. The worker is a
second Claude Code session on a different API endpoint. They are peers on one
machine, and the orchestrator verifies what the worker produces.

Like `budget`, it is a module: off by default, switched on with `/sidecar-on`
and off with `/sidecar-off`, installed by the same installer, gated by a flag
file at `~/.claude/sidecar-mode`, and installed to `~/.claude/drive-sidecar/`.

Sections marked **[unverified]** name what still has to be proved; the evidence
for everything else is in `## What is verified`.

**On the name.** "third-party agents" is what this does and belongs in the
README headline, where people look for it. `sidecar` is what it is called in
commands and paths, because `drive` and `budget` are single lowercase words and
`/3rdpartyagents-on` is not a command anyone wants to type. One `git mv` and a
rename in the installer reverses this if it turns out wrong.

---

## 1. What this is for

The working pattern today is Opus orchestrating Opus: one session plans and
verifies, subagents do the coding, and the orchestrator keeps its context clean
by taking summaries rather than full output. It works, and it spends the 5-hour
window twice over — once on the planning and once on the coding.

This replaces the *coder* half with a model on a metered API, and leaves the
orchestration and verification where they are.

That split is the whole design, and it decides what may be delegated:

- **Delegate** work whose output is cheap to check — mechanical refactors,
  test writing, porting, doc sweeps, exploration that ends in a written finding.
- **Do not delegate** work whose output is expensive to check — architecture,
  anything that writes `DECISIONS.md`, anything where being subtly wrong costs
  more than doing it yourself.

If the orchestrator has to re-derive the work to check it, the delegation lost.

## 2. Decisions already settled

| | |
| --- | --- |
| Topology | Sidecar behind a tool call. No proxy in the orchestrator's path. |
| Shape | A **bolt-on module to the drive skill**, switched on like budget mode and off by default. |
| Worker count | **One.** |
| Worker shape | **`claude --bg`** — a background session, not `claude -p`. |
| Worker permissions | The same a normal Claude Code session has in that project. |
| Worker workspace | A **git worktree**. The orchestrator merges it when the result checks out. |
| Verification | The orchestrator checks every result; the worker's full output never enters its context. |
| Contract | The drive contract goes to the worker **verbatim**. No shortened variant. |
| Cost display | A status line segment, month-to-date against a cap. |
| Cap | **$80/month**, across every provider and model. Advisory: it colours the segment, it stops nothing. |
| Context floor | 256K minimum on any model used; 1M preferred. |

One worker is not a limitation to route around later. It is what makes
verification possible: with one worker the orchestrator checks each result
before the next task starts. Two workers and it is merging unverified work from
two sources into one tree.

The worktree is what makes that check safe rather than merely diligent: the
worker's output is never in the orchestrator's tree until a human-verifiable
diff has been looked at.

**`--bg`, not `-p`**, and the two cannot be combined — Claude Code rejects
`--bg` with `-p`. `-p` would hand back a structured result and a
`total_cost_usd` in one call, which is tidier; `--bg` gives a session that
`ListAgents` can see, `SendMessage` can reach and `claude attach` can open. The
peer channel and being able to watch are worth more than the tidier return, and
`-p`'s cost figure is unusable here anyway (§7) — so the ledger is computed from
the transcript either way, and `-p`'s one real advantage evaporates.

**Verbatim, measured.** The contract is 7,168 characters — **2,496 tokens**,
measured by differencing two identical `claude -p --output-format json` runs
(14,988 vs 17,484 total input tokens). That is about 1% of a 256K window and a
quarter of a percent of 1M, and on a provider with automatic prefix caching it
sits in the cached prefix and bills at a fraction of that after the first call.
Maintaining a second, shortened contract would cost more in drift than the
tokens are worth.

One worker is not a limitation to route around later. It is what makes
verification possible: with one worker the orchestrator checks each result
before the next task starts. Two workers and it is merging unverified work from
two sources into one tree.

## 3. Topology

```
  ┌─ Opus session (claude.ai subscription, no proxy, no shim) ─────────┐
  │                                                                    │
  │   mcp__sidecar__delegate(task)  ──┐                                │
  │   SendMessage / ListAgents  ◀─────┼──── peer channel (local socket)│
  └───────────────────────────────────┼────────────────────────────────┘
                                      ▼
                         ┌─ sidecar launcher ─────────────┐
                         │  provider profile → env        │
                         │  CLAUDE_CONFIG_DIR (isolated)  │
                         │  drive contract → system prompt│
                         └──────────────┬─────────────────┘
                                        ▼
                    claude --bg   (a real Claude Code session)
                    ANTHROPIC_BASE_URL=https://api.<provider>/anthropic
                                        │
                                        ▼
                              DeepSeek / Kimi / GLM / …
```

The orchestrator never talks to a non-Anthropic endpoint. If the provider is
down, the wrong shape, or Claude Code regresses against third-party endpoints,
the blast radius is "delegation is unavailable" and the fallback is that the
orchestrator does the task itself.

That is the entire reason for this shape. A router in front of the orchestrator
would put every request behind a component that, when it fails, also disables
the agent that would fix it.

## 4. Why the worker is a Claude Code session

Because then it needs nothing explained to it. A worker launched as
`claude --bg` gets the real system prompt, the real `Read`/`Write`/`Edit`/
`Bash`/`Grep`/`Glob`, the real permission system, the real hooks and skills. No
hand-written description of the harness to drift out of date, and no tool layer
to maintain.

`CLAUDE_CONFIG_DIR` gives it its own settings, its own hooks and its own agents,
so its permissions are defined deliberately rather than inherited by accident.

## 5. The three channels

| Channel | Direction | Carries |
| --- | --- | --- |
| MCP tool call → result | orchestrator → worker → orchestrator | the delegation and its report |
| `claude --resume <id>` | orchestrator → worker | follow-up with the worker's context intact |
| `SendMessage` / `ListAgents` | **both ways** | mid-task questions, findings, "stop" |

The third is the one that makes this feel like more than a batch job. Claude
Code sessions on one machine are addressable peers: `ListAgents` from an
unrelated session already lists background sessions by name, and `SendMessage`
reaches them. A subagent cannot do this — it reports once, at the end, and
cannot initiate. A peer can interrupt to ask a question.

**[unverified]** that a session on a non-Anthropic endpoint participates in peer
messaging. The transport is a local socket and model-independent, so it should;
but the worker's model has to *choose* to call `SendMessage`, and a cheaper
model may need that spelled out in its prompt. First thing to test.

## 6. Watching the worker, and what it will not look like

**It will not appear as a nested subagent panel inside the orchestrator's
transcript.** This is the one place the design cannot give the current
experience, and it is worth knowing before building on it. What it gives
instead:

- **Inline**: a tool call and its result, like any other tool call.
- **Separately**: a session listed by `claude agents` and `ListAgents`, opened
  full-screen with `claude attach <id>`, tailed with `claude logs <id>`.

That is close to the background-subagent experience — a thing you open and
watch — but it is a sibling session rather than a child of the conversation, and
there is no expandable panel in the transcript.

**[unverified]** whether MCP progress notifications render in the tool call's
panel while it runs. The delegate has to emit them regardless — a tool call that
sends nothing for the idle window is aborted — so if Claude Code renders them,
live progress inside the panel comes free. If it does not, `claude attach` is
the way to watch.

**The reasoning is recoverable.** Claude Code transcripts record thinking blocks
as `"type":"thinking"` entries — verified against a real transcript on this
machine, which carried 95 of them. So the worker's thinking is on disk whether
or not anyone watches it live, and the endpoint returns it (DeepSeek supports
thinking mode, ignoring `budget_tokens`).

**But the delegate tool must not pipe reasoning back into the orchestrator's
context.** That would spend exactly the window the delegation exists to save.
Reasoning stays in the worker's transcript; the tool returns a digest and the
path.

## 7. Cost tracking

### Where the numbers come from

Not from Claude Code. `--output-format json` does report `total_cost_usd` and a
per-model breakdown, but they are client-side estimates computed at **list
price**, and Claude Code has no list price for a `deepseek-*` model id. The
setting that would fix that, `modelPricing`, is **managed scope** — it cannot be
set in a user settings file at all.

So the ledger is computed here, from token counts the worker's transcript
already records (`message.usage`: `input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`) against a price table
this project owns.

That is the right answer regardless: the cap is "$80/month across every provider
and model", and only a table we control can price every provider.

### Caching is worth designing around

DeepSeek ignores Anthropic-style `cache_control` breakpoints, but runs automatic
server-side prefix caching underneath — no directives, no cache-write charge, no
storage fee, and cache hits bill at roughly 2% of the miss rate on V4 Flash and
about 8% on V4 Pro. It keys on an exact prefix from token 0.

Two consequences for the launcher:

1. **Keep the prefix byte-identical.** `--system-prompt-snapshot` already
   defaults to `on` — the prompt is rendered once per conversation and reused
   verbatim on every request *and every resume*. Combined with a fixed tool set
   and a fixed drive contract, the whole prefix is stable.
2. **Static first, variable last.** The drive contract and project conventions
   belong in the system prompt; the task belongs in the user message. Putting
   the task in `--append-system-prompt` would break the prefix on every call and
   throw the discount away.

**[unverified]** the real hit rate, and whether the Anthropic shim surfaces
DeepSeek's cache hit/miss counts as `cache_read_input_tokens`. Measurable on day
one; the design should report it rather than assume it.

### The ledger

One append-only file, one line per delegation: timestamp, provider, model,
token counts by class, computed cost, session id. Month-to-date is a sum over
it. Append-only because a spend record that gets rewritten is not a record.

### The status line

The cap reads the way the rate-limit windows read now: a segment at the bottom,
turning red past $80.

`settings.json` holds exactly one `statusLine` and the budget sensor owns it, so
the sensor gains an **extension point**: it appends the first line of
`~/.claude/statusline-extra` when that file exists, and this module writes it.
Four lines of change, one owner of the slot, and no knowledge of this module in
the sensor.

Since both budget and sidecar are now modules of the same skill, that extension
point is the general module seam rather than a one-off, and any later module
uses it the same way.

### Where state lives

Two kinds of thing, and they do not go in the same place:

| | Where | Why |
| --- | --- | --- |
| Provider profiles | the repo | Versioned and reviewable; adding a provider is a diff. |
| Price tables | the repo | Same — a price change should show up in history. |
| The spend ledger | `~/.claude/sidecar-ledger` | Runtime state about this machine, like `budget-state`. It does not belong in a repo, least of all a public one. |
| API keys | **neither** | Environment variables, or a `0600` file under `~/.claude`. Never the repo. |

**The drive skill repository is already public** (`github.com/jt226ub/llm-drive-skill`,
visibility `PUBLIC`). A profile therefore names the *credential variable* to
read — `cred_var=ANTHROPIC_AUTH_TOKEN` — and never the credential.

## 8. Universal by construction

Nothing above is DeepSeek-specific. A provider is a profile — base URL,
credential variable, model ids, prices — and adding one is a file, not code:

```
providers/
  deepseek.conf     base=https://api.deepseek.com/anthropic  cred=ANTHROPIC_AUTH_TOKEN
  <other>.conf
```

Verified from first-party documentation: DeepSeek. **[unverified]** for Z.ai/GLM,
Moonshot/Kimi, MiniMax and Qwen — widely reported to expose Anthropic-shaped
endpoints, not checked here. Gateways with a first-class `/anthropic` handler
(Bifrost, LiteLLM) cover anything that does not, and are the later slot for a
router *behind* the delegate tool if per-task model choice ever justifies one.

Bedrock, Vertex and Foundry are natively supported by Claude Code and need no
shim at all; they are the low-risk option if compatibility ever becomes the
binding problem.

## 9. Failure modes

| Failure | Effect | Handling |
| --- | --- | --- |
| Provider down or 5xx | delegation fails | tool returns unavailable; orchestrator does the task itself |
| Claude Code regresses against third-party endpoints | delegation fails | same; the orchestrator is untouched because it uses no shim |
| Worker stalls | no result | bounded wait, then stop the session and report |
| Worker produces wrong work | caught | the orchestrator verifies every result — this is the design, not a safety net |
| Ledger unwritable | cost unknown | say so in the status line; never show a stale figure as current |

The precedent for the last row is the budget module's sensor: silence about a
number is worse than not having it.

There is no automatic recovery machinery here on purpose. At the delegation
boundary the fallback is one branch — do it yourself — and needs no supervisor,
no health check and no self-healing loop.

## 10. What is verified

Established from first-party documentation or run on this machine:

- Native subagents **cannot** change provider: *"Subagents inherit the main
  conversation's provider scope… You cannot switch providers at the subagent
  level."*
- Claude Code has **no `ANTHROPIC_BASE_URL` failover**. `--fallback-model` is
  model-level within one endpoint.
- A credential variable **replaces the subscription for that process**, so a
  worker spends the provider's money and none of the 5-hour or weekly windows.
- Env vars are honoured per process: a child `claude` with
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` set reported the credential taking
  over from the claude.ai login. No `ANTHROPIC_*` variable leaks from a parent
  session into subprocesses.
- `claude --bg` produces a peer session that `ListAgents` lists and
  `claude attach`/`logs` reach.
- `claude -p` **rejects `--bg`** — they are alternative shapes.
- `--output-format json` reports `total_cost_usd` and a per-model breakdown, as
  client-side list-price estimates.
- `modelPricing` is managed scope.
- `--system-prompt-snapshot` defaults to `on`.
- MCP: a tool call that sends no response and no progress notification for the
  idle window **aborts**. A long delegation must emit progress.
- DeepSeek's endpoint is `https://api.deepseek.com/anthropic`; tool use,
  streaming, system prompts, thinking and vision supported; `cache_control`,
  document content, and MCP tool use/results not supported.

## 10a. First run against a live provider — 2026-09-12

A temporary DeepSeek key was used to answer the questions that were blocking.
**The core of the design holds.** Six findings, four of which change what gets
built.

**It works.** A `claude --bg` session with `ANTHROPIC_BASE_URL` pointed at
`https://api.deepseek.com/anthropic` started, took a task, created a file with
the right contents, and did it on DeepSeek's money. The endpoint itself is
solid: HTTP 200 on all four combinations of `Authorization: Bearer` /
`x-api-key` against `deepseek-flash` / `claude-sonnet-4-5`, with `claude-*`
names mapping as documented and thinking blocks in every response.

**Peer messaging reaches it — question 1 answered.** `ListAgents` from an
Anthropic session listed `ds-worker [482c2d] · bg · busy` alongside ordinary
sessions, and a `SendMessage` to it arrived: the worker's own log shows
`› Message from @llm-drive-skill-88: Probe from the orchestrator…` in its input.
**Delivery is proved; the reply leg is not**, because the worker never got to
process the message (see below). The two-way story rests on a round trip that
has still only been seen in one direction.

**Do not set `ANTHROPIC_MODEL` to a provider model id.** Claude Code validates
model names against its own catalog before the request goes anywhere. A bare
`ANTHROPIC_MODEL=deepseek-flash` killed the first session outright — *"There's
an issue with the selected model (deepseek-flash). It may not exist or you may
not have access to it."* — even though that exact id returns 200 from the
endpoint by curl. `ANTHROPIC_MODEL='deepseek-flash[1m]'` survives the main turn
but still fails the catalog check on auxiliary calls
(`[claude-code:unrecognized_model]` … `"query_source":"generate_session_title"`).
**The launcher passes `--model sonnet` and lets the provider's own mapping do
the translation.** That runs clean. The cost is cosmetic: the UI, and any commit
the worker writes, will say Sonnet.

**The cost figure is wrong by about 35×, measured.** A probe reporting
`total_cost_usd: 0.1133` for 22,655 input tokens was priced at Claude list
rates; at DeepSeek Flash's $0.14/M the same call is about $0.003. This was
predicted from `modelPricing` being managed-scope and is now measured. The
ledger must compute cost itself.

**The transcript's model field cannot be trusted to name the real model.** One
run recorded `"model":"deepseek-flash"`, another `"model":"claude-sonnet-5"`,
for the same provider. So the ledger takes provider and model from the launcher,
which knows, rather than reading them back from the transcript. Token counts
still come from the transcript.

**`/user/balance` is not a ledger.** It still read `5.00` after the probes —
too coarse and too lagging to meter against a monthly cap. Another reason the
count is ours.

**The unattended-stall failure is real, and it is the first thing to design
against.** The worker finished the file and then blocked on a permission prompt
for `git add && git commit` with nobody to answer, which also stopped it
draining the queued cross-session message. `--permission-mode acceptEdits`
covers the write and not the commit. Whatever the launcher passes has to cover
the *whole* task including the commit, or the worker has to be told not to
commit at all and hand the diff back instead — which suits the worktree hand-off
in §2 better anyway.

**Unplanned but welcome:** the worker put its work in a git worktree of its own
accord (`.claude/worktrees/inherited-noodling-kazoo`), which is the shape §2
asks for. Worth checking whether that is Claude Code's own behaviour for
background sessions before building machinery to force it.

**Also confirmed live:** the budget sensor ran inside the DeepSeek session and
printed `deepseek-flash · worker · no plan limits in this session` — the fix
from earlier today working in exactly the case it was written for, on a real
non-subscription session rather than a synthetic payload.

## 10b. Second run — the round trip, and permissions

**The worker answered. Two-way peer messaging with a non-Anthropic worker is
proved.** Unprompted by anything but its task, `ds-worker2` called `SendMessage`
back to the orchestrator:

> Task complete. Model ID: claude-sonnet-5. hello.txt was created with contents
> "sidecar" and committed successfully (commit a5abbfa, "Add hello.txt", on
> branch worktree-humming-sauteeing-castle in an isolated worktree).

Verified independently rather than taken on its word: `a5abbfa` exists on that
branch, `hello.txt` contains `sidecar`, one file changed. §5's third channel is
real in both directions.

**Permissions are inherited already — and that settles the isolation question
against `CLAUDE_CONFIG_DIR`.** Permission resolution keys off the config
directory and the working directory, not session identity, so a worker launched
without `CLAUDE_CONFIG_DIR` reads the same `~/.claude/settings.json` as the
orchestrator and the same `.claude/settings.json` as whatever folder it runs in.
The first run's stall was not a missing permission; it was `--permission-mode
acceptEdits` being *stricter* than the orchestrator's `auto`. On this machine
there are no `permissions` rules, no project `.claude/`, and no managed
settings, so all latitude comes from `auto` mode's classifier — and passing
`--permission-mode auto` let the worker commit without a prompt.

So the launcher **does not give the worker its own config directory.** The
earlier plan to isolate it and re-supply the drive contract via
`--append-system-prompt` is dropped: an isolated config directory inherits
nothing — no permissions, no hooks, so no drive contract, and no skills. The
decision in §2 was "the same permissions a normal Claude Code session has in
that project", and inheriting the default config directory *is* that, exactly,
with no machinery. The launcher passes the orchestrator's own permission mode
and nothing else.

The cost of that choice, stated plainly: the worker has the orchestrator's
latitude wherever it is pointed. Point it at a directory deliberately. And the
reverse of the cross-session warning applies — never route work through the
worker that the orchestrator's own permissions would refuse.

**The worker cannot tell what it is.** It reported `claude-sonnet-5` in good
faith, because that is the name it was given; nothing in its context says
DeepSeek. So the launcher must tell it in its prompt when that matters, and the
ledger must never ask it — provider and model come from the launcher, as §10a
already concluded for a different reason.

**The worktree is Claude Code's own behaviour, not ours to build.** Both
background workers created one unprompted — `inherited-noodling-kazoo`, then
`worktree-humming-sauteeing-castle`. Two for two is a default, not chance. §2's
worktree hand-off needs no machinery, only a step that merges the branch after
the orchestrator has reviewed the diff.

## 11. Open questions

Everything that was open in the first two drafts is now settled: one repository
with modules, `--bg` as the worker's shape, the name, the status line seam, the
worktree, the verbatim contract and its measured cost, and where state and
secrets live.

What is left is not design but evidence, and none of it can be gathered without
a provider key:

1. **Does Claude Code render MCP progress notifications in the tool panel?** If
   it does, live progress comes free. If not, `claude attach` is the way to
   watch. Either way the delegate must emit them or the call is aborted.
2. **Does the Anthropic shim surface DeepSeek's cache hit/miss counts?** Both
   probes reported `cache_creation_input_tokens: 0` and
   `cache_read_input_tokens: 0` — but both were cold, so a miss is exactly what
   should have happened and nothing is settled. Re-run against a warm prefix. If
   the shim reports zeros regardless, the caching may still be happening and
   billing cheaper while being invisible to us, and the ledger will overstate.
3. **Do the other providers' endpoints behave?** Only DeepSeek has been run.

Answered by the runs in §10a and §10b: the worker starts and works, peer
messaging works in both directions, the model must be named with a Claude alias,
the cost figure must be computed here, permissions are inherited from the
default config directory, and the worktree comes for free.

None of what is left changes the topology. The build can start, and its first
piece is the launcher.
