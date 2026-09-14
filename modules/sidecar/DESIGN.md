# sidecar — design

**Status: built and installed.** `sidecar.sh`, one provider profile, a price
table, and the two slash commands. What is written below as intention has been
built except where a section says otherwise; §10a, §10b and §10c are the record
of what running it actually taught, and they overrule the earlier sections
wherever they disagree.

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
- **But not by every `--bg` launch.** Measured 2026-09-13 on Claude Code
  2.1.270: a `claude --bg` started from a shell inside another `--bg` session,
  with the pair in its environment — inherited or `env -i` — made no request to
  the endpoint (a listener on 127.0.0.1 and a live tunnel both saw nothing) and
  answered on the claude.ai login, with the real system prompt's 40k cached
  tokens in its usage. `claude -p` with the same environment reached the
  endpoint. `claude --bg --settings '{"env":{…}}'` reached it too. So the
  launcher passes the pair twice: in the environment and in a 0600 settings
  file beside the worker's records (D14). The 2026-09-12 run in §10a, from an
  interactive orchestrator, did reach DeepSeek; the condition that breaks the
  environment route is not pinned down beyond "launched from inside a `--bg`
  session", and the settings route holds in every case measured.
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

## 10c. Building it — 2026-09-12

**It works, and the first version of it was quietly broken in the one way that
mattered.** A live delegation produced exactly the right artefact: DeepSeek
wrote `mul()  { echo $(( $1 * $2 )); }` in the existing one-line style,
committed it to a worktree it made itself, and `collect` priced the run at
$0.03. Every visible signal said success.

But a helper returning its value by `eval "$1=..."` had a local named the same
as the variable the caller asked for, so the credential came back empty and was
never noticed. And an empty or rejected credential does not stop a background
worker: **Claude Code retries and falls back to the saved claude.ai login.**
Measured directly — a worker launched with a deliberately wrong key logged three
401s from DeepSeek and completed the task anyway. So the module could spend the
subscription windows it exists to protect and report the cost as pennies.

`start` now proves the credential against the provider before launching, and
refuses on anything but HTTP 200. `collect` refuses to price a run whose
transcript shows an authentication error. D8 has the reasoning.

**Two things the attempt to diagnose this got wrong**, recorded because they
cost more than the bug did. Message-id shape does not identify the endpoint:
Claude Code stamps `msg_...` regardless of who served the request, and a
conclusion drawn from that had to be retracted. And DeepSeek's `/user/balance`
lags — it read `5.00` through several confirmed runs — so it cannot attribute a
single run either.

**Two corrections to the cost figures**, both prompted by the number failing a
human sniff test rather than a test suite — *"1 million tokens for such a simple
request doesn't make sense to me"*, which was right twice over.

*The same response was billed more than once.* A transcript records an assistant
message repeatedly: **21 usage records against 13 distinct message ids** in the
run that exposed it. Summing every `"usage":{` therefore roughly doubled the
figures. `_usage` now counts each message id once, and counts a record carrying
no id, since dropping it would understate and understating spend is the worse
direction.

*Summed tokens are not the provider's token count, and printing them invited a
false comparison.* Against DeepSeek's own dashboard — **11 requests, 55,939
tokens** — the deduplicated transcript gives 13 responses and 719,487 input
tokens. The gap is not an error in either: every request re-sends the whole
conversation, so `cache_read_input_tokens` is that request's *cumulative prefix*
rather than new tokens, and the per-request trace shows it climbing 38,515 →
52,767 → … → 57,510 as the conversation grows. Summing it is right for **cost**,
because those tokens really are billed at the cache-hit rate, and wrong as a
**total**, because the provider counts unique tokens processed. `collect` now
prints the cost and the response count and not the summed tokens, and says why.

The cost itself was never far out: 19,142 missed input, 700,345 cached, 2,542
output prices at **$0.013** for that run, which is what a dozen requests of ~55K
context on a cheap model should cost.

**The multi-line prompt bug, which cost two live tests.** Prepending the
hand-off brief to the task made the launch prompt multi-line, and the session
then started with an **empty prompt** and sat idle. Two workers in a row did
nothing at all while reporting `state: blocked`, and both runs were read as
"inconclusive" rather than as a bug, because a stalled worker and a worker with
nothing to do look the same from outside. The brief now rides in
`--append-system-prompt`, which is where a standing instruction belongs anyway.
The lesson is narrower than it looks: *inconclusive* twice in a row about the
same thing is a finding, not a run of bad luck.

**The push guard was unproven; it now holds, by a different mechanism.** D9 has
the reasoning. What follows is the record of it failing first. A worker launched with
`--disallowed-tools "Bash(git push:*)"` pushed to a real remote anyway — checked
against a bare repository, which received the commit. Anthropic's docs use two
rule spellings and the space form is untested here, so the flag is still passed
but nothing claims it blocks. What the module actually relies on is the brief
telling the worker to hand work back as a branch, and the orchestrator reviewing
the diff before merging. **[unverified]** whether any rule spelling blocks it.
Worth settling, because workers told "Commit it. Nothing else." attempted `git
push` four times each.

## 10d. Staying provider-agnostic, and the budget that is not money

Audited for provider assumptions once DeepSeek was working. Every mention of it
in the code is a comment explaining why something is the way it is; the only
behavioural default is `--provider deepseek`, which a flag overrides. Two real
leaks were found and closed.

**`collect` died when a provider had no price row.** `_price` refuses rather
than guesses, which is right, but that made a model you host yourself unusable:
it costs nothing per token, so it has no row, so the work could not be reported
at all. A profile now declares `billing=tokens` (the default) or `billing=none`,
and a `none` provider gets its tokens counted and its work reported with no cost
figure and no ledger row. Proven by copying the module somewhere its `SELF_DIR`
resolves to a provider set containing no DeepSeek at all.

**The cap was baked into the script.** `CAP_USD` now comes from
`~/.claude/sidecar-config`, written once by install, with a non-numeric value
falling back rather than breaking the arithmetic it feeds.

### What a time budget would need

**Not built — it needs an endpoint that exists first.** A self-hosted model on a
rented machine is bounded by hours rather than dollars, and the shape is already
close: the balance log is a sequence of readings with a timestamp and a number,
and spend is the sum of the falls. Minutes remaining falls the same way.

What is genuinely missing is only the naming and the units:

- A profile key saying what the reading *is* — `billing=time`, with a
  `balance_field` naming whatever the endpoint returns and a unit — so that
  `spend` and the status line can say "3h 40m of 30h" rather than dollars.
- A cap in the same unit, beside `CAP_USD` rather than replacing it, since a
  machine can run both kinds of provider in the same month.
- Nothing else. `_to_micro` becomes a units conversion rather than a currency
  one, `_billed_mtd` is unchanged because falling is falling, and the
  append-only log already keeps the raw readings so a first attempt at the
  conversion can be redone from data rather than from memory.

**Answered, 2026-09-12:** it is a fixed allowance that resets, and the value can
be queried — by the endpoint if it carries it, and by the Kaggle CLI regardless.

That settles the shape. It is a **window**, not a balance, so it belongs closer
to the budget module's model than to the ledger's: a window has a size, a
consumed fraction and a reset time, and the interesting question is "how much is
left before it resets", which is what the status line already says for the
five-hour and weekly windows.

The consequence for the reading log is small but worth writing down now. A
balance is differenced because nothing reports spend; an allowance that reports
its own remaining value needs no differencing at all — the reading *is* the
answer, and summing falls across a reset boundary would be wrong, because the
allowance going back up is a reset and not a top-up. So a `billing=time`
provider reads its remaining allowance directly and does not go through
`_billed_mtd`.

The CLI being able to pull the value matters as a fallback: if the served
endpoint does not carry the allowance, the profile can name a command to run
instead of a URL to fetch, which keeps the reading source a per-provider detail
rather than a fork in the module.

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
2. **Does the Anthropic shim surface DeepSeek's cache hit/miss counts?**
   **Answered 2026-09-13: yes, and the cache holds on a real agent loop.** A
   25,242-token system prefix sent three times through
   `/anthropic/v1/messages` reported 25,242 miss / 0 hit on the first call and
   **154 miss / 25,088 hit** on the second and third (`cache_read_input_tokens`);
   the native `/chat/completions` control reports the same split. A worker
   started by `start` (nine responses, three files created one tool call at a
   time) reported 51,088 miss on its first response and 147–388 miss / 51,840–
   52,992 hit on every later one — 99.5 % of input at the hit rate, ≈$0.02 for
   the run. The two cold probes in §10a were simply cold. Consequences: the
   ledger's per-token pricing is right to bill `cache_read_input_tokens` at the
   hit rate, and `cache_creation_input_tokens` stays 0 on this provider (no
   write charge), as `prices.conf` already assumes.
3. **Do the other providers' endpoints behave?** Only DeepSeek has been run.

Answered by the runs in §10a and §10b: the worker starts and works, peer
messaging works in both directions, the model must be named with a Claude alias,
the cost figure must be computed here, permissions are inherited from the
default config directory, and the worktree comes for free.

None of what is left changes the topology. The build can start, and its first
piece is the launcher.

## 12. Rules of engagement per provider — 2026-09-13

The user asked for model-specific instructions: the sidecar enforces one worker
at a time (D12), but nothing told the dispatching session *how* a given provider
should be used — a Kaggle TPU is a rapid iterative coder to be fed many small
tasks at a stated token rate; DeepSeek is cheap on long cached loops — and
nothing told the worker what its particular model gets wrong.

**Shape.** One file per provider beside its profile, `providers/NAME.rules.md`,
with two headed sections and nothing else that is read:

- `## Orchestrator` — how the session that dispatches should use this model.
  Injected into every prompt while sidecar mode is on by
  `hooks/sidecar-mode.sh`, a copy of the drive-mode hook's shape (flag file,
  plain stdout, pure bash, exit 0). Capped at 15 lines by test, because the
  drive contract already costs ~120 lines per turn; the full text is
  `sidecar.sh rules [--provider NAME]`.
- `## Worker` — appended to the worker's system prompt after the hand-off brief
  by `start`, as "Rules of engagement for MODEL on PROVIDER:". Optional; a
  provider without the file gets the brief alone.

**Which provider.** `/sidecar-on NAME` writes the name into the flag file
(`$HOME/.claude/sidecar-mode`); `start` and `rules` read it when `--provider`
is not given, and the hook reads it to choose the rules file. An empty or
malformed line means deepseek, as before. The hook's header also says whether a
worker is out, read from `$HOME/.claude/sidecar-run/*.env`, so the orchestrator
is reminded to collect before dispatching again.

**What was rejected.** Putting the rules in the profile `.conf` (a `key=value`
file cannot hold prose); a single skill-level rules block (it is per model by
the user's ask); injecting the Worker section into the orchestrator too (it is
conduct for the model, noise for the dispatcher). Providers whose numbers
change per session (a Kaggle kernel's decode rate and context) write their own
`NAME.rules.md` from their launcher at READY — the Anthropic Sidecar project
does that — and this module reads whatever is there.

## 13. A second worker shape: the Gemini CLI — 2026-09-14 (superseded by §15: the CLI stopped serving personal accounts)

The user's Google AI Pro plan gives Gemini CLI 1,500 model requests a day and funds no
API key; Google names using the CLI's OAuth from any other software as a terms
violation and suspended accounts for it in February–March 2026. So the plan's quota
can be spent by exactly one thing: the official CLI. `providers/gemini-cli.conf`
declares `harness=gemini-cli`, and `start` runs the CLI headless instead of a Claude
Code session:

- `gemini -p "<brief + Worker rules + task>" -o json --approval-mode yolo --skip-trust`
  inside a worktree the sidecar creates at `.claude/worktrees/<worker>` on a branch of
  the same name (Claude Code made that worktree itself; the CLI does not). The brief
  rides in the prompt, not in a `GEMINI.md`, because a file in the worktree would show
  in the diff and clobber a repository's own.
- The run record holds `harness`, `pid` and `worktree`; `status` reads the pid
  (`live` / `exited(rc)`), `stop` kills it. No session id, no `claude attach`, no peer
  messaging — the CLI runs to completion and prints one JSON object.
- `collect` sums `stats.models.*.api.totalRequests` and the model token counts from
  that JSON (roles nest inside each model with their own counts and are skipped),
  prints the `response`, and records requests in `~/.claude/sidecar-requests`;
  `billing=requests` with `daily_requests=1500` makes `spend` show today's count.
- The push guard is unchanged: it is `GIT_CONFIG_*`, so any git process obeys it.
- Preflight: the CLI must be installed and `~/.gemini/oauth_creds.json` must exist;
  the login itself is interactive and the user's.

Rejected: any proxy of the CLI's OAuth (terms; suspensions); `GEMINI_SYSTEM_MD` (it
replaces the whole system prompt); the CLI's own `-w` worktree flag (its location is
undocumented and `collect` needs to find the worktree).

Verified with a stub `gemini` in `tests/run-tests.sh` (argv, env, cwd, commit, JSON
stats, exit codes, a hanging worker killed by `stop`). Not yet run against the real
CLI: the login needs the user at the machine.

## 14. Three kinds of cost, and caps that stop a provider — 2026-09-14

`spend` now prints one line per kind and nothing else: the Anthropic subscription's
windows first and always (from the budget sensor's `budget-state`: "5h 28% used (resets
HH:MM) · 7d 89% used"), then one line per provider that is *in use* — a worker out, or
spend in the current period — by its billing kind: `tokens` ("API est $X · billed $Y /
$CAP this month"), `requests` ("N of 1,500 model requests today"), time ("N min of session
time left at the last reading", from `balance_url`). Providers with nothing to report are
not listed, so the lines that matter are not buried.

Caps are enforced at `start`, not advisory: a token-billed provider at `CAP_USD` (the
higher of estimate and billed), a requests-billed one at `daily_requests`, a time-billed
one whose fresh session reading is 0 minutes. `start` refuses with the reason and when it
resets; `spend` marks the line "CAP REACHED … start refuses". The status line still turns
red at the money cap. This supersedes the "advisory by decision" stance the cap had.

## 15. The Antigravity CLI replaces the Gemini CLI as the worker — 2026-09-14

§13 was built against a stub and never ran live: the first real call after a successful
Google login on Gemini CLI 0.59.0 answered `IneligibleTierError: This client is no longer
supported for Gemini Code Assist for individuals`. Google stopped serving free, AI Pro
and AI Ultra accounts on Gemini CLI and the Code Assist extensions on 2026-06-18; the
plan's replacement is the closed-source Antigravity CLI (`agy`, Go). It keeps the shape
§13 wanted — one headless run per task, one JSON envelope on exit — so the harness
changed, not the contract:

- `providers/antigravity-cli.conf`: `harness=antigravity-cli`, `billing=quota`,
  `print_timeout=2h`, `model=gemini-3.8-flash-high` (a slug from `agy models`, passed as
  `--model`; the user wants the newest Flash, and `auto` leaves a choice the CLI records nowhere).
- `start` runs `agy -p "<brief + Worker rules + task>" --output-format json
  --dangerously-skip-permissions --print-timeout 2h` in the sidecar-made worktree;
  status, stop and the push guard are unchanged. The login is the CLI's own
  (`~/.gemini/antigravity-cli/antigravity-oauth-token`); `start` refuses without it.
- Money guard: the CLI can fall back to purchased AI credits when the plan's quota is
  gone (`useG1Credits`, opt-in, in `~/.gemini/antigravity-cli/settings.json`; the CLI
  rewrites that file on every start and drops defaults, so an absent key is off — a
  first version wrote `false` into it and refused a silent file, and the CLI erased it
  within the same run). `start` refuses while the file says `true`. The CLI also
  inherits the setting from the Antigravity desktop app's user settings (its log says
  "inherited useG1Credits=true from …"); keep it off there too.
- `collect` reads the envelope (`status`, `response`, `error`, `num_turns`,
  `usage.{input,output,thinking,cache_read}_tokens`), counts one run per collect in
  `sidecar-requests`, and — because the plan's quota (refreshed every 5 h up to a weekly
  cap, no numbers published, readable only in the interactive `/usage`) cannot be
  polled — treats a run whose `error` names a quota, rate limit or credits as the cap:
  `sidecar-quota` gets `EPOCH PROVIDER MESSAGE`, `spend` shows CAP REACHED and `start`
  refuses for 5 h from that moment.
- Signing in on an unattended machine: `modules/sidecar/antigravity-login.py DIR`
  runs `agy` under a pty that looks like an SSH session, so it prints the sign-in URL
  instead of opening a browser; the URL goes to the user's phone through the chat and
  the CLI's own 60-second window (hardcoded) is enough when the URL is posted the moment
  it appears. Done live 2026-09-14 on the second attempt; the Gemini CLI's 5-minute
  variant of the same relay is what timed out first.

Rejected: the `gemini` provider mode of `agy` (a Gemini API key: paid, not the plan);
any proxy of the CLI's login (terms). Verified with a stub `agy` in `tests/run-tests.sh`
and live: two real `agy -p` calls (`status SUCCESS`, 13k input tokens of the CLI's own
system prompt per call) after the relay login.

**Reviewed by both Gemini models through the sidecar itself, 2026-09-14.** The same
review task (no edits, answer in the response) went to `gemini-3.8-flash-high` and
`gemini-3.1-pro-high`. Flash: 384 s, 387k input tokens (+636k cache reads), 49k output
(+39k thinking), a 26k-character review with twelve findings, and it ran the whole test
suite unasked. Pro: 382 s, 98k input (+337k cached), 33k output (+31k thinking), a
5k-character review with four findings plus one outside the asked scope. Both found the
same three real defects: `_agy_stats` and `_agy_field` read the first match of a key, so
a response quoting `"num_turns"` or `"status"` could be taken for the envelope's own;
`_agy_field` left `"}` on the last field of an envelope; and `_collect_agy` returned
before the error check when the envelope had no `usage`, so an early quota failure was
never marked. Flash alone added: a quota message printed only to stderr was never read,
`printf '%b'` on model text, an inherited `GEMINI_API_KEY` would make the CLI bill the
key instead of the plan, the run record was written non-atomically, and the pid `stop`
kills is the launching subshell's. Pro alone added the porcelain worktree listing (the
plain listing split `/Volumes/External Data/…` at the space, which is why both reviews'
`collect` output said "no worktree yet"). Fixed: all of these except the pid concern
(`stop` already kills the subshell's children; a recycled pid is a theoretical hazard
left as is) and the orphaned worktree on an early `start` failure (low, left as is).
Each fix has a test. On this evidence Pro's review was the one to read and Flash's the
one to grep; both were worth the quota.

## 16. The roster: four models, four roles, one line each in every prompt — 2026-09-14

The user set the roles: **Gemini 3.8 Flash** — a fast non-interactive coder (small and
larger tasks; the CLI runs, answers and exits, so every task is a fresh `start`);
**Gemini 3.1 Pro** — a slower non-interactive coding expert (small and larger tasks, help
with task and project planning, review, brainstorming); **Qwen3.8-27B on the Kaggle TPU**
— a fast interactive coder for small and large tasks, which must be booted and queued and
is then used for the session, its budget being time rather than tokens; **DeepSeek V4.1
Flash** — a fast interactive expert coder paid per API token, used sparingly.

What changed to carry that:

- `start --model SLUG` picks the model for one run on a profile that lists `models=`
  (antigravity-cli: the three 3.8 Flash efforts and the two 3.1 Pro efforts); any other
  slug, or a profile without the list, refuses. The run record and `status` show the
  model chosen.
- Each profile carries a one-line `roster=`; the sidecar-mode hook prints, after the
  active provider's Orchestrator section, `Other providers (start --provider NAME
  [--model SLUG]):` and one line per other profile. The mode's provider still decides
  whose full rules are injected; the roster is what makes the others an option without
  switching. The Kaggle TPU launcher writes its own roster line into `kaggle-tpu.conf`.
- The Orchestrator sections of `antigravity-cli.rules.md` and `deepseek.rules.md`, and
  the ones the Kaggle launcher writes, now say those roles in the user's words.

Rejected: one profile per model (the rules would repeat and `/sidecar-on` would have to
name an effort); putting the whole roster's rules in every prompt (the 15-line cap is
there for a reason — one line per other provider is the compromise).

## 17. The Antigravity worker becomes an iterative loop; the plan quota becomes readable — 2026-09-14

**Conversation.** The CLI keeps a whole exchange under a conversation id, and a later
`agy -p … --conversation <id>` in a new process continues it with the context intact.
Measured: a follow-up sent within 2 minutes reads the earlier turns from cache (12k of
21k input tokens on both Flash 3.8 high and Pro 3.1 high); after 10 minutes idle nothing
is cached and the whole conversation is re-sent (33k tokens). Quota "is consumed
proportionally to the cost of the tokens" (the CLI's own /usage text), so that matters.
`say --worker NAME --task TEXT` runs the next turn in the same worktree with the same
model: the run record keeps `turns=` and `conversation=`, the previous envelope is
appended to `NAME.turns`, `collect` shows "conversation turn N" and how to continue,
`stop` clears it all. `say` refuses while a turn is running, when the last turn left
no envelope (nothing to continue), on a Claude Code worker (those are reached with
`claude attach`), and at a cap. The brief and the Worker rules ride only in turn 1;
the conversation holds them. The rules of engagement now say: put the full context in
the first `--task`, then ask, and send the next `say` within ~2 minutes of `collect`.

**Quota.** `antigravity-quota.py` drives the interactive CLI under a pseudo-terminal in
an empty folder of ours (`~/.claude/sidecar-run/agy-quota`, trusted once), sends
`/usage`, and parses the GEMINI MODELS group's weekly and five-hour bars into one line
(`weekly=97.71 weekly_reset=167h21m five_hour=94.34 five_hour_reset=4h21m`). Nothing
headless reports these; the CLI fetches them through an internal endpoint and logs no
numbers. Readings go to `~/.claude/sidecar-quota-readings`; `quota` forces one,
`spend` reuses a reading younger than 10 minutes (a reading costs ~10 s), and a fresh
reading at 0% on either bar is the cap. The script stops, exit 3, if the CLI's
first-run wizard is up — the theme and the data-use consent are the user's to answer,
never a script's — and exit 4 when not signed in.

Rejected: the long-lived `--input-format stream-json` process (it delivered a turn's
result one turn late twice in scratch); summarise-and-restart follow-ups (both Gemini
models' fallback design; unnecessary once cache reads were measured); reading quota
from the CLI's log or cache files (there is nothing there).
