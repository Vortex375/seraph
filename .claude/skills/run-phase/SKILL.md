---
name: run-phase
description: "Work a phase of tickets to completion in one long-running session, dispatching each to a sub-agent and judging what comes back."
disable-model-invocation: true
---

# Run Phase

Work a **phase** — a run of tickets — to completion without leaving this session.

You are the **foreman**. You dispatch and you judge; sub-agents build. Every file read, every edit, every test run happens inside a sub-agent, so your own context holds tickets and **verdicts** and nothing else. That discipline is what lets one session outlast a phase no single context window could hold.

The issue tracker should have been provided to you — run `/setup-matt-pocock-skills` if `docs/agents/issue-tracker.md` is missing. Consult it for how *this* repo expresses tickets, claims, blocking edges and the **frontier**. Ticket state lives on disk rather than in your context, which is what makes a phase resumable after a compact or a crash.

## Process

### 1. Fix the phase boundary

The user names the feature and where the phase ends — a ticket range, a phase from the spec, or "everything". Resolve that to an explicit list of ticket ids, working from the tickets alone — their titles and blocking edges are the whole input.

Restate the list to the user and get their go-ahead before dispatching anything. This is the last point at which a mis-scoped phase is cheap.

**Done when:** you can name every ticket in the phase and its blockers.

### 2. Take the frontier ticket

Scan the phase's tickets for the **frontier** — open, unblocked, unclaimed — and take the lowest-numbered one. Claim it by setting its `Status:` to `claimed` and saving, before any work.

Record `git rev-parse HEAD` as this ticket's **base**. The verifier reviews against it, so capture it before the implementer touches anything.

**Done when:** one ticket is claimed and its base SHA is noted.

### 3. Dispatch the implementer

One `Agent` call, `subagent_type: "general-purpose"`, `model: "sonnet"`. The sub-agent starts cold, so the prompt carries everything:

- The ticket's file path, and: "Read it in full, including every acceptance criterion."
- "Run `/implement` on this ticket. Its blockers are all complete — build on what they landed."
- "Work only what this ticket asks for. Anything else you notice, name it in your report."
- "Commit to the current branch when the acceptance criteria are met."
- "Report back in under 200 words: what you built, which files, and any decision you had to make that the ticket did not settle. Do not paste code or diffs."
- "If the ticket asks a question only the user can answer, stop and return `BLOCKED: <the question>` rather than choosing for them."

**Done when:** the implementer has returned a report or `BLOCKED:`.

### 4. Dispatch the verifier

Fresh eyes, never having seen the implementer's reasoning. One `Agent` call, `subagent_type: "general-purpose"`, `model: "sonnet"`:

- The ticket's file path and the base SHA, with the diff command `git diff <base>...HEAD`.
- "Check the diff against every acceptance criterion in the ticket. Judge what the code does, not what the commit message claims."
- "Run the project's test suite and typechecker, and treat a failure as a defect."
- "Return a verdict on the first line — `APPROVED` or `REWORK` — and nothing else on it. If `REWORK`, follow it with a numbered list of defects, each naming the criterion it fails and the file it lives in. Under 300 words. Do not paste diffs."

The implementer's `/implement` already ran `/code-review` over its own work, which covers the Standards axis. This pass is the axis that cannot be self-graded: did it build what the ticket asked for.

**Done when:** a verdict line has come back.

### 5. Route the verdict

A ticket resolves only on a verifier's `APPROVED`. Your own impression of the work is not a verdict.

- **APPROVED** → set the ticket's `Status:` to `resolved` and append the implementer's report and the verdict under the ticket's `## Comments` heading. That comment is the phase's memory: it survives a compact, where your context may not. Return to step 2.
- **REWORK** → dispatch the fix. Send the defect list back to the *same* implementer with `SendMessage` when the defects are things it got wrong; spawn a *new* implementer when the verdict says the approach itself is wrong, since the original's context is now working against it. Either way, return to step 4 with the same base SHA.
- **BLOCKED** → put the question to the user, then resume at step 3 with their answer folded into the prompt.

**Two `REWORK` verdicts on one ticket means the ticket is wrong, not the agent.** Stop, append both verdicts to the ticket, and bring it to the user.

### 6. Close the phase

When every ticket on the step-1 list is `resolved`, report: tickets completed, tickets that needed rework and why, and every decision a sub-agent had to make that its ticket did not settle. That last list is the one worth reading — it is where the spec was thin.

**Done when:** every ticket on the list is `resolved` or has been escalated to the user.

## Working the frontier in parallel

Serial is the default: with a deep critical path, most tickets are gated anyway, and one implementer at a time keeps the branch coherent.

When the frontier is genuinely wide and you want the throughput, dispatch each implementer with `isolation: "worktree"` so they hold separate checkouts, and verify and merge them one at a time. Parallel implementers sharing one working tree will overwrite each other.
