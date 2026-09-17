# Rules of engagement — Antigravity CLI (the user's Google AI Pro plan: Gemini 3.8 Flash and Gemini 3.1 Pro)

Three sections, three readers. `## Role` is the harness-agnostic description of what these
models are for, in the user's words: the sidecar-mode hook prints it before `## Orchestrator`,
and the AO fork's role profiles read it as the profile's rules (LLM Drive Skill D23).
`## Orchestrator` is the sidecar's own mechanics for the dispatching session (kept under
15 lines, injected on every prompt while `/sidecar-on antigravity-cli` is active). `## Worker`
is what the worker gets after the Drive contract, in front of the task: only what this
provider needs beyond the contract. The rest of this file is documentation.

## Role

- Gemini 3.8 Flash (default, at its highest reasoning effort): the default implementer for
  small and larger coding tasks; `-medium` / `-low` only to save quota. When 3.8 has no
  capacity the CLI retries; if the turn still fails it reruns on 3.7 Flash.
- Gemini 3.1 Pro (`gemini-3.1-pro-high`; `-low` only to save quota): the expert — planning,
  review, brainstorming, hard bugs. It also serves as a reviewer of another model's branch.
- Free within the plan: one 5-hour and one weekly quota shared by Flash and Pro, no money.
  Spend Pro on judgement, not typing; keep every turn purposeful because both draw on the
  same meter. Below 20 % on either bar, prefer shorter tasks; at 0 % nothing starts.

## Orchestrator

- An iterative loop, not a live session: `start` runs one turn to completion in its own
  worktree and exits; `say --worker NAME --task "..."` runs the next turn of the same
  conversation there (context intact). No attach, no interrupting a turn. Put the full
  context in the first --task (paths, definition of done, tests); then ask.
- Send the next `say` within ~2 minutes of `collect`: the earlier turns are then read from
  cache (cheap quota); after ~10 minutes idle the whole conversation is re-sent at full price.
- `start --model gemini-3.1-pro-high` for the expert; the answer to a plan, review or
  brainstorm comes back in `collect` under "what it said". A capacity rerun on 3.7 Flash
  is named in `collect`.
- `sidecar.sh quota` reads the plan's bars and `spend` shows the last reading; 0 % refuses
  `start`. One worker at a time is enforced. Collect and review the branch before the next.

## Worker

- For a plan, review or brainstorm, put the whole answer in your final response (it is
  what the reviewer reads) and commit nothing unless the task says to.
- Quote the output of the tests you ran verbatim; the reviewer cannot rerun them here.
