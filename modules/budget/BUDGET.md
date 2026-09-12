---
name: budget
description: "Directives injected when a plan rate-limit window is close to exhausted: wrap up, write the record, park the session for an automatic resume."
---

<!-- Sections are delimited by the @MARKER comments below. budget/gate.sh prints
     exactly one section, chosen by which threshold was crossed, so nothing here
     costs context on an ordinary turn. Edit the prose here and nowhere else. -->

<!-- @WRAP -->
## BUDGET: the 5-hour window is nearly spent

You have crossed the wrap-up threshold. The tool gate closes at the hard
threshold, and anything you have not written down by then is lost.

**Stop starting work.** Finish only what is already in flight and can be
verified in the remaining budget. Do not open a new file, spawn a subagent, or
begin a task you cannot finish now.

Then, in this order:

1. **Write the record** — `HANDOFF.md` and, if a decision was made this session,
   `DECISIONS.md`. The schema is below. This is the deliverable now; the code is
   not.
2. **Commit it** by explicit path.
3. **Park the session** so it resumes itself once the window resets:

       "$HOME/.claude/drive-budget/park.sh" --session SESSION_ID --cwd "$PWD"

   The gate tells you the session id. Parking schedules a resume five minutes
   after the window resets and then closes the gate completely.
4. **End the turn**, leading with where the work stands and what the next
   session picks up.
<!-- @STOP -->
## BUDGET: the 5-hour window is exhausted — the gate is closed

Tool calls other than the ones needed to write and commit the record are being
denied, and that allowance is bounded. Do not try to route around it.

Right now, in this order:

1. Write `HANDOFF.md` (and `DECISIONS.md` if a decision was made) to the schema
   below.
2. Commit by explicit path.
3. Park:

       "$HOME/.claude/drive-budget/park.sh" --session SESSION_ID --cwd "$PWD"

4. End the turn. Say plainly what is done, what is not, and what the resumed
   session will pick up.

If the record is already written and committed, park and stop — do not spend the
remaining allowance re-reading things.
<!-- @WEEK_DOC -->
## BUDGET: the weekly window is nearly spent

The 7-day window is the expensive one to hit: the 5-hour window returns in
hours, this one returns in days, and it takes every session on the account down
with it. Nothing you leave undocumented survives that gap.

**Write the full record now, while there is budget to write it with.** Not a
note — the whole thing: `HANDOFF.md` brought up to date, every decision made
this session in `DECISIONS.md`, every open defect or unverified claim named as
such. Assume the next session is days away and remembers nothing.

Then continue working if the 5-hour window allows, keeping the record current as
you go rather than deferring it again.
<!-- @WEEK_STOP -->
## BUDGET: the weekly window is exhausted — the gate is closed

Only writing and committing the record is still permitted, and that allowance is
bounded. There is no automatic resume from here: the window is days out, so
parking against it would leave a job scheduled far beyond anything you can
verify. Write the record, commit it, and stop.

Tell the user, in your closing report, when the weekly window resets — the gate
message gives the time — so they can decide what to do with the gap.
<!-- @SUBAGENT -->
## BUDGET: the window is exhausted — return now

You are a subagent and the account's rate-limit window is spent. Your tool
access is closed.

Return immediately with what you have: what you found, what you verified, and
what you did not get to. Do not write files, do not commit, do not start another
search. The session that dispatched you owns the record; your job is to hand it
your findings before the window closes on it too.
<!-- @PARKED -->
## BUDGET: this session is parked

A resume is already scheduled. The record has been written and the gate is shut.

Do nothing further. End the turn with a one-line statement of when the session
will resume and what it will pick up.
<!-- @SCHEMA -->
### The record schema

**`HANDOFF.md`** — the session record and the brief for the next session. Create
it if it does not exist. Structure:

    # Handoff — session record, and a brief for the next session

    ## ⇒ NEXT: **<the one thing to do first, and why it is first>**

    <What to do, in order. Commands to run and the result to expect. What is a
    prerequisite for what. What is already known to fail, and how to read it.>

    ## What this session did

    <Verified done, with the evidence — what was run and what it returned.
    Attempted but unverified, said as such. What was deliberately not done.>

    ## What is in the way

    <Blockers, unverified claims, anything the next session must not take on
    trust.>

Lead with `⇒ NEXT`. A handoff that opens with a narrative of the session makes
the reader hunt for the instruction.

**`DECISIONS.md`** — append-only. One entry per consequential decision. Never
edit an old entry; supersede it with a new one and mark the old one superseded.

    ## D<N> — <what was decided, as a sentence>

    **Date** YYYY-MM-DD · **Status** accepted

    **Context.** <The forcing question.>

    **Decision.** <What was chosen.>

    **Rejected.** <The alternatives, and why each lost.>

    **Consequences.** <What this costs, and what would reverse it.>

If the repository already has these files, match the shape they are already in
rather than the shape above. If it has neither and the session made no decision,
write `HANDOFF.md` alone — do not create an empty decision log.
