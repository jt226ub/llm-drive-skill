# Rules of engagement — Antigravity CLI (the user's Google AI Pro plan)

`## Orchestrator` is injected into every prompt of the dispatching session while
`/sidecar-on antigravity-cli` is active (kept under 15 lines); `## Worker` is put in
front of the task the CLI receives. The rest of this file is documentation.

## Orchestrator

- Free within the plan: a quota refreshed every 5 h up to a weekly cap, no money.
  Google publishes no numbers and the CLI cannot report them headless; a run that
  hits the quota marks the provider spent for 5 h (`sidecar.sh spend` shows it).
- Its shape is fixed: the CLI runs the task to completion in its own worktree,
  commits, and exits. No messaging back and forth — everything it needs goes in
  --task (paths, definition of done, tests to run, the commit message).
- One worker at a time is enforced. Collect and review the branch before the next.
- Every model call draws on the same quota; a tool loop makes many. Batch small
  tasks into one well-specified brief, and prefer it for mechanical work before
  any paid provider.
- The default model is the CLI's choice; `agy models` lists slugs for the profile.

## Worker

- Do exactly the task as written; do not widen it or refactor beyond it.
- Run the tests you touch before committing and quote their output verbatim.
- Commit on the current branch and stop. Never push, never merge.
- Your final answer is what the reviewer sees first: what changed, what you ran, what is left.
