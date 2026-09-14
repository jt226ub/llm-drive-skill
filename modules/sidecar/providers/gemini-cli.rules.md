# Rules of engagement — Gemini CLI (the user's Google AI Pro plan, 1,500 model requests a day)

`## Orchestrator` is injected into every prompt of the dispatching session while
`/sidecar-on gemini-cli` is active (kept under 15 lines); `## Worker` is put in
front of the task the CLI receives. The rest of this file is documentation.

## Orchestrator

- Free within the plan: 1,500 model requests a day, no money. `sidecar.sh spend`
  shows today's count. Prefer it for mechanical work before any paid provider.
- Its shape is fixed: the CLI runs the task to completion in its own worktree,
  commits, and exits. No messaging back and forth — everything it needs goes in
  --task (paths, definition of done, tests to run, the commit message).
- One worker at a time is enforced. Collect and review the branch before the next.
- A request is one model call, and a tool loop makes many: a task of moderate
  size costs 20–60 requests. Batch small tasks into one well-specified brief.
- Large context is its strength (1M tokens): hand it whole files and logs.

## Worker

- Do exactly the task as written; do not widen it or refactor beyond it.
- Run the tests you touch before committing and quote their output verbatim.
- Commit on the current branch and stop. Never push, never merge.
- Your final answer is what the reviewer sees first: what changed, what you ran, what is left.
