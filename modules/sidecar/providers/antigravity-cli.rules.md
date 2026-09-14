# Rules of engagement — Antigravity CLI (the user's Google AI Pro plan: Gemini 3.8 Flash and Gemini 3.1 Pro)

`## Orchestrator` is injected into every prompt of the dispatching session while
`/sidecar-on antigravity-cli` is active (kept under 15 lines); `## Worker` is put in
front of the task the CLI receives. The rest of this file is documentation.

## Orchestrator

- Non-interactive: the CLI runs one task to completion in its own worktree, answers, and
  exits — no messaging, no attach; a new task is a new `start`. Everything it needs goes
  in --task (paths, definition of done, tests to run, the commit message).
- Gemini 3.8 Flash (default, at its highest reasoning effort): a fast non-interactive
  coder for small and larger tasks. `-medium` / `-low` only to save quota.
- Gemini 3.1 Pro (`--model gemini-3.1-pro-high`; `-low` only to save quota): a slower
  non-interactive coding expert — small and larger tasks, help with task and project
  planning, review, and brainstorming; the answer comes back in `collect` under "what it said".
- Free within the plan: a quota refreshed every 5 h up to a weekly cap, no money; Google
  publishes no numbers, and a run that hits the quota marks it spent for 5 h (`spend`).
- One worker at a time is enforced. Collect and review the branch before the next.

## Worker

- Do exactly the task as written; do not widen it or refactor beyond it.
- Run the tests you touch before committing and quote their output verbatim.
- Commit on the current branch and stop. Never push, never merge.
- For a plan, review or brainstorm, put the whole answer in your final response (it is
  what the reviewer reads) and commit nothing unless the task says to.
- Your final answer is what the reviewer sees first: what changed, what you ran, what is left.
