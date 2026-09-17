# Rules of engagement — DeepSeek (deepseek-flash through the Anthropic-format endpoint)

Three sections, three readers. `## Role` is the harness-agnostic description of what this
model is for, in the user's words: the sidecar-mode hook prints it before `## Orchestrator`,
and the AO fork's role profiles read it as the profile's rules (LLM Drive Skill D23).
`## Orchestrator` is the sidecar's own mechanics for the dispatching session (under 15 lines,
injected on every prompt while `/sidecar-on deepseek` is active; the rest of what an
orchestrator might want is `sidecar.sh rules`). `## Worker` is appended to the worker's
system prompt after the hand-off brief and the Drive contract: only what this provider
needs beyond them. Anything else in this file is documentation and is read by nobody.

## Role

- DeepSeek V4.1 Flash: the paid expert coder and second-opinion reviewer, a Claude Code
  session of its own that you can message. Paid per token from the API balance, so use it
  sparingly: when the free arms are down or exhausted, or when the task needs an expert you
  can talk to. Keep judgement calls and reviews with the orchestrator.

## Orchestrator

- One worker at a time is enforced. Queue the next task only after `collect` has
  shown you the diff; review the branch before the next task starts.
- Cheap because of caching: the first turn pays the full prompt, later turns pay
  ~0.5% of it. Long tasks are cheaper per result than many short ones; off-peak
  (16:30–00:30 UTC) is half price.
- It cannot see your conversation. Put everything it needs in --task: paths, the
  definition of done, the tests to run, the branch name to commit to.

## Worker

- Keep replies compact: every token is billed. What changed, what was verified, what is left.
