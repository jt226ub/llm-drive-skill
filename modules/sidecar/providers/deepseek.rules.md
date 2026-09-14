# Rules of engagement — DeepSeek (deepseek-flash through the Anthropic-format endpoint)

Two readers. `## Orchestrator` is injected into every prompt of the dispatching
session while sidecar mode is on (`/sidecar-on deepseek`), so it stays under
15 lines; the rest of what an orchestrator might want is `sidecar.sh rules`.
`## Worker` is appended to the worker's system prompt after the hand-off brief.
Anything else in this file is documentation and is read by nobody.

## Orchestrator

- Use it for long, mechanical, well-specified coding work: scaffolding, test
  writing, mechanical refactors, porting. Keep judgement calls and reviews here.
- One worker at a time is enforced. Queue the next task only after `collect`
  has shown you the diff; review the branch before the next task starts.
- Cheap because of caching: the first turn pays the full prompt, later turns
  pay ~0.5% of it. Long tasks are cheaper per result than many short ones.
- Off-peak (16:30–00:30 UTC) is half price; batch the big jobs there.
- It cannot see your conversation. Put everything it needs in --task: paths,
  the definition of done, the tests to run, the branch name to commit to.

## Worker

- Stay on the task as written; do not widen it, do not refactor beyond it.
- Run the tests you touch before committing and report their result verbatim.
- Keep replies compact: what changed, what was verified, what is left.
