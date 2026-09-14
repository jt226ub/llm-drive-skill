# Rules of engagement — Antigravity CLI (the user's Google AI Pro plan: Gemini 3.8 Flash and Gemini 3.1 Pro)

`## Orchestrator` is injected into every prompt of the dispatching session while
`/sidecar-on antigravity-cli` is active (kept under 15 lines); `## Worker` is put in
front of the task the CLI receives. The rest of this file is documentation.

## Orchestrator

- An iterative loop, not a live session: `start` runs one turn to completion in its own
  worktree and exits; `say --worker NAME --task "..."` runs the next turn of the same
  conversation there (context intact). No attach, no interrupting a turn. Put the full
  context in the first --task (paths, definition of done, tests); then ask.
- Send the next `say` within ~2 minutes of `collect`: the earlier turns are then read from
  cache (cheap quota); after ~10 minutes idle the whole conversation is re-sent at full price.
- Gemini 3.8 Flash (default, at its highest reasoning effort): a fast non-interactive
  coder for small and larger tasks. `-medium` / `-low` only to save quota.
- Gemini 3.1 Pro (`--model gemini-3.1-pro-high`; `-low` only to save quota): a slower
  non-interactive coding expert — small and larger tasks, help with task and project
  planning, review, and brainstorming; the answer comes back in `collect` under "what it said".
- Free within the plan: a 5-hour and a weekly quota shared by Flash and Pro, no money;
  `sidecar.sh quota` reads them and `spend` shows the last reading; 0% refuses `start`.
- One worker at a time is enforced. Collect and review the branch before the next.

## Worker

- Do exactly the task as written; do not widen it or refactor beyond it.
- Run the tests you touch before committing and quote their output verbatim.
- Commit on the current branch and stop. Never push, never merge.
- For a plan, review or brainstorm, put the whole answer in your final response (it is
  what the reviewer reads) and commit nothing unless the task says to.
- Your final answer is what the reviewer sees first: what changed, what you ran, what is left.
