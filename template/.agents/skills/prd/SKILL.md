---
name: prd
description: "Generate a Product Requirements Document (PRD) for a new feature. Use when planning a feature, starting a new project, or when asked to create a PRD. Triggers on: create a prd, write prd for, plan this feature, requirements for, spec out."
user-invocable: true
---

<!--
Distributed by ralph-kit (https://github.com/levinhen/ralph-kit).
Derived from snarktank/ralph (https://github.com/snarktank/ralph), MIT-licensed.
-->

# PRD Generator

Create detailed Product Requirements Documents that are clear, actionable, and suitable for implementation.

---

## The Job

1. Sweep the PRDs that are already in flight and report them to the user (Step 0)
2. Receive a feature description from the user
3. Ask clarifying questions (with lettered options), prioritized by importance — no fixed count
4. Review the answers and ask follow-up questions for anything still ambiguous; iterate until the key information is clear
5. Judge whether the work is Ralph-sized at all; if one session could finish it, say so before writing anything (Step 2b)
6. Restate the need in plain business language and get the user's confirmation before writing
7. Generate a structured PRD that neither duplicates nor silently contradicts an in-flight PRD; record any minor remaining uncertainties in Open Questions
8. Save to `ralph/tasks/prd-<feature-name>.md` (substitute `<feature-name>` with a kebab-case slug)

**Important:** Do NOT start implementing. Just create the PRD.

If the user also wants the PRD prepared for Ralph execution, use the `ralph` skill after saving the markdown PRD —
but only when the work is Ralph-sized; [Step 2b](#step-2b-is-this-ralph-sized-work) says how to tell, and a task one
session could finish should not be offered a run. The
markdown task remains in `ralph/tasks/` while the run is in play (Ralph archives it into
`ralph/archive/<date>-<run_id>/` once the run completes), while the Ralph execution file should be generated as
`ralph/runs/<run_id>/prd.json`. The Ralph skill/script owns run-scoped execution state such as
`progress/shared-memory.json`, per-story `progress/<story_id>.jsonl`, `state.json`, and per-story `stories/*.json`.

---

## Step 0: Sweep the PRDs Already in Flight

**Do this before you ask a single clarifying question, every time, without being asked to.** A PRD that has been
written but has not finished executing is invisible unless you go looking for it, and the cost of missing one is a
second PRD that re-specifies work someone already designed — or quietly contradicts it, so two runs end up fighting
over the same files.

You do not have to judge what counts as unfinished. Ralph moves a run and its source PRD into
`ralph/archive/<date>-<run_id>/` only once that run is finished and consolidated, so **whatever is still sitting in
`ralph/tasks/` or `ralph/runs/` is in flight by definition.** Sweep both, and read how far each one has got:

```bash
find ralph/tasks -maxdepth 1 -name 'prd-*.md' 2>/dev/null | sort
find ralph/runs -maxdepth 2 -name prd.json 2>/dev/null | sort | while read -r f; do
  printf '%s ' "$(dirname "$f")"
  jq -r '"\(.userStories | map(select(.passes == true)) | length)/\(.userStories | length) stories passing"' "$f"
done
```

Place every PRD the sweep turns up in one of four states. How far it has run is what decides the cost of changing its
design, so establish this *before* you design anything that touches it:

| State | How to tell | What its design is made of |
|---|---|---|
| **Drafted** | `ralph/tasks/prd-<x>.md` exists, no `ralph/runs/<x>/` | Paper. Nothing has been built. |
| **Split, not started** | run exists, `0/N stories passing` | Paper, plus a story split. Still no code. |
| **Part-run** | run exists, `k/N` with `0 < k < N` | The passing stories are already code on that run's branch. |
| **Stories done, not archived** | run exists, `N/N stories passing` | All code, pending merge-back and consolidation. |

Then **report what you found before you start asking questions** — one short list, each PRD with its state, and an
explicit note on anything that overlaps what the user just asked for. If the sweep comes back empty, say that in one
line and move on; the absence is part of the report.

---

## Step 0b: Do Not Re-Design What Is Already Designed

The sweep exists so this PRD does not duplicate or silently contradict one that is already in flight. Hold to these
rules while you write:

- **Overlap → do not re-specify it.** If an in-flight PRD already owns a piece of what the user is asking for, that
  piece is not yours to write again. Name the PRD that owns it and put it in this PRD's **Non-Goals**, pointing there.
- **Conflict → you may overturn the other design, but the new design lands here.** You are not bound to a design just
  because it is already written down. If what the user needs now is incompatible with an in-flight PRD's design,
  re-decide it — and write the resulting design into **this** PRD, saying plainly which decision in which PRD it
  supersedes. Do not leave the resolution implicit, and do not go edit the other PRD to match: from that point on,
  this PRD is the current truth for that decision and the other one is stale.
- **Overturning something already built is work this PRD has to carry.** Look at the state you recorded above.
  Overturning *paper* (drafted, or split-but-not-started) costs nothing — the other PRD simply goes stale. But a
  design that a **part-run** or **stories-done** run already turned into code exists on that run's branch: superseding
  it means this PRD needs its own user stories for changing that code, with acceptance criteria describing the new
  behaviour. A PRD that assumes built code will un-build itself produces stories that cannot pass.
- **Say which in-flight PRD you just made stale.** Ralph keeps executing the other run from its own `prd.json`, which
  knows nothing about this conversation — editing markdown would not reach it anyway. What to do about that run (let
  it finish, stop it, re-convert it) is the user's call, so hand them the fact rather than deciding for them.

**Where it lands in the PRD:** overlap goes in **Non-Goals**, naming the PRD that owns it; a superseded decision goes
in **Technical Considerations**, naming the PRD and the decision it replaces; the work of changing already-built code
becomes **User Stories** like any other work.

---

## Step 1: Clarifying Questions

Ask whatever questions the ambiguity actually requires — there is **no fixed count**. A simple, well-specified
prompt may need only one or two; a vague one may need several. Only skip a topic when the prompt already answers it.

**Prioritize by importance.** Lead with the blocking questions that fundamentally shape the PRD, then move to
secondary details. Group them so the user can see what matters most:

- **Must-answer (blocking):** the PRD can't be written without these
  - **Problem/Goal:** What problem does this solve?
  - **Core Functionality:** What are the key actions?
  - **Scope/Boundaries:** What should it NOT do?
  - **Success Criteria:** How do we know it's done?
- **Nice-to-have (refining):** sharpen the PRD but won't block it (target user, edge cases, design/tech preferences)

Don't overwhelm the user — surface the must-answer questions first. Keep the lettered-option format so the user can
answer quickly (e.g. "1A, 2C"), and let them defer the nice-to-have ones.

### Format Questions Like This:

```
1. What is the primary goal of this feature?
   A. Improve user onboarding experience
   B. Increase user retention
   C. Reduce support burden
   D. Other: [please specify]

2. Who is the target user?
   A. New users only
   B. Existing users only
   C. All users
   D. Admin users only

3. What is the scope?
   A. Minimal viable version
   B. Full-featured implementation
   C. Just the backend/API
   D. Just the UI
```

This lets users respond with "1A, 2C, 3B" for quick iteration. Remember to indent the options.

---

## Step 2: Follow-up & Refinement

Do **not** jump straight to writing the PRD after the first round of answers. Answers often reveal new gaps,
contradict each other, or are themselves too vague to act on. Close those gaps first.

After each round of answers:

1. **Re-read the answers** against the PRD sections you're about to write. For each section (Goals, User Stories,
   Functional Requirements, Non-Goals, Success Metrics), ask: do I have enough to write this unambiguously?
2. **Ask targeted follow-up questions** for anything still unclear — a vague answer ("make it fast"), a contradiction,
   or a new ambiguity surfaced by an earlier answer. Reuse the same prioritized, lettered-option format.
3. **Iterate** until the must-answer items are all clear. Each round should get more specific, not broader.

**Knowing when to stop:** stop once every blocking question is resolved — don't loop forever chasing minor details.
Any small remaining uncertainties that aren't worth blocking on go into the PRD's **Open Questions** section
(Step 4 → section 9), not another round of questions.

---

## Step 2b: Is This Ralph-Sized Work?

By now the answers tell you the shape of the work. Before you write anything, decide whether it is big enough to be a
Ralph run at all — and if it is not, say so before the PRD ceremony, not after.

Ralph's overhead is **per run, not per story**: every story is a fresh session that re-reads the repo, and the run
ends with a scaffold-cleanup round that runs the whole test suite, a merge-back, and a consolidation round, whether
the run had one story or fifteen. Measured on one project (2026-09-01, three paired repetitions per task, same model
and effort in both arms): a one-story run cost about 12× a direct session and a three-story run about 3×, with no
quality gain — the direct session finished the three-story task in under 100K tokens of context with no compaction,
and the wrap-up rounds alone were 70% of the one-story run's cost.

**The work fits one session — do not offer a Ralph handoff — when:**

- one agent can hold the whole change in view: a handful of files, one subsystem, one verification command;
- you could hand it over as a single prompt and expect it back within the hour without the agent losing the thread;
- nothing has to survive a session boundary: no resuming after an interruption, no isolating one part's failure from
  the rest, no parallel worktrees, no per-story checkpoints anyone will read;
- it would split into one to three stories on a serial chain.

**Ralph earns its overhead when:**

- the backlog is long enough that one session would compact or drift — roughly ten or more stories, hours of work;
- parts are independent enough to run as parallel runs;
- the work spans days and must resume from the last passing story;
- the process artifacts are wanted: per-story checkpoints, unblock rounds, scaffold cleanup, a design-ledger entry.

When the work fits one session, tell the user in one line, with the reason, and offer the two honest options:
implement it directly in the conversation (this skill itself still does not implement), or write a lightweight PRD
with no Ralph handoff. Only convert it to a run if the user, told this, still wants one — that is their call, not a
rule to enforce.

---

## Step 3: Restate the Need in Business Language

Before writing the formal PRD, **play the requirement back to the user in plain business language and wait for their
confirmation.** This is the final guard against building the wrong thing.

What to write:

- Describe the **problem, who is affected, the desired outcome, and the value** — in product/business terms.
- Keep it short: a few sentences or a tight bullet list the user can scan and react to.

What to avoid:

- **No implementation talk.** Do not mention which files/tables/functions will change, what to add or refactor, schemas,
  components, or any "how we'll build it" detail. That belongs in the PRD's technical sections, not here.
- Example — write *"Users want to see at a glance which tasks are most urgent so they can tackle those first,"* **not**
  *"add a `priority` column to the tasks table and a badge component to the card."*

Then:

1. **Stop and ask the user to confirm or correct** the restatement. Do not start writing the PRD yet.
2. If they correct it, revise and reconfirm. If a correction reveals a real gap, go back to Step 2 and ask.
3. Once confirmed, carry this agreed restatement forward — it becomes the basis of the PRD's
   **Introduction/Overview** (Step 4 → section 1).

---

## Step 4: PRD Structure

Generate the PRD with these sections:

### 1. Introduction/Overview

Brief description of the feature and the problem it solves. Build this from the business-language restatement the user
confirmed in Step 3 — keep it in product terms, not implementation terms.

### 2. Goals

Specific, measurable objectives (bullet list).

### 3. User Stories

Each story needs:

- **Title:** Short descriptive name
- **Description:** "As a [user], I want [feature] so that [benefit]"
- **Acceptance Criteria:** Verifiable checklist of what "done" means

Each story should be small enough to implement in one focused session.

**Format:**

```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Acceptance Criteria:**
- [ ] Specific verifiable criterion
- [ ] Another criterion
- [ ] Typecheck/lint passes
- [ ] **[UI stories only]** Verified in a browser: [what should be visible or happen on screen]
```

**Important:**

- Acceptance criteria must be verifiable, not vague. "Works correctly" is bad. "Button shows confirmation dialog before
  deleting" is good.
- **Every criterion must be observable within the story's own implementation session.** A criterion that can only be
  checked after a *later* story lands (e.g. a schema story whose criterion describes UI behavior) belongs to that later
  story instead — give each story an outcome it can demonstrate by itself. If verifying a story needs infrastructure (a
  test runner, seed data, a dev server), a story that provides it must come earlier in the list.
- **For any story with UI changes:** Always include a "Verified in a browser: ..." criterion naming the observable
  result. This ensures visual verification of frontend work. Never name a tool or skill in a criterion — the round that
  implements the story uses whatever browser tooling it has, and a criterion pointing at a missing helper can never be
  satisfied.

### 4. Functional Requirements

Numbered list of specific functionalities:

- "FR-1: The system must allow users to..."
- "FR-2: When a user clicks X, the system must..."

Be explicit and unambiguous.

### 5. Non-Goals (Out of Scope)

What this feature will NOT include. Critical for managing scope. List here anything an in-flight PRD already owns
(Step 0), naming that PRD — scope you are deliberately not re-specifying is a non-goal like any other.

### 6. Design Considerations (Optional)

- UI/UX requirements
- Link to mockups if available
- Relevant existing components to reuse

### 7. Technical Considerations (Optional)

- Known constraints or dependencies
- Integration points with existing systems
- Performance requirements
- Any decision here that supersedes an in-flight PRD's design (Step 0b) — name the PRD and the decision it replaces

### 8. Success Metrics

How will success be measured?

- "Reduce time to complete X by 50%"
- "Increase conversion rate by 10%"

### 9. Open Questions

Remaining questions or areas needing clarification — including any minor uncertainties left over from the
clarification rounds (Step 2) that weren't worth blocking the PRD on. Be specific so they can be resolved later.

---

## Writing for Junior Developers

The PRD reader may be a junior developer or AI agent. Therefore:

- Be explicit and unambiguous
- Avoid jargon or explain it
- Provide enough detail to understand purpose and core logic
- Number requirements for easy reference
- Use concrete examples where helpful

---

## Output

- **Format:** Markdown (`.md`)
- **Location:** `ralph/tasks/` (moved into `ralph/archive/<date>-<run_id>/` when the matching Ralph run finishes)
- **Filename:** `prd-<feature-name>.md` (kebab-case)
- **Ralph handoff:** Only when requested, and only for Ralph-sized work (Step 2b), also create
  `ralph/runs/<run_id>/prd.json` through the `ralph` skill.

---

## Example PRD

```markdown
# PRD: Task Priority System

## Introduction

Add priority levels to tasks so users can focus on what matters most. Tasks can be marked as high, medium, or low priority, with visual indicators and filtering to help users manage their workload effectively.

## Goals

- Allow assigning priority (high/medium/low) to any task
- Provide clear visual differentiation between priority levels
- Enable filtering and sorting by priority
- Default new tasks to medium priority

## User Stories

### US-001: Add priority field to database
**Description:** As a developer, I need to store task priority so it persists across sessions.

**Acceptance Criteria:**
- [ ] Add priority column to tasks table: 'high' | 'medium' | 'low' (default 'medium')
- [ ] Generate and run migration successfully
- [ ] Typecheck passes

### US-002: Display priority indicator on task cards
**Description:** As a user, I want to see task priority at a glance so I know what needs attention first.

**Acceptance Criteria:**
- [ ] Each task card shows colored priority badge (red=high, yellow=medium, gray=low)
- [ ] Priority visible without hovering or clicking
- [ ] Typecheck passes
- [ ] Verified in a browser: each card's badge color matches that task's priority

### US-003: Add priority selector to task edit
**Description:** As a user, I want to change a task's priority when editing it.

**Acceptance Criteria:**
- [ ] Priority dropdown in task edit modal
- [ ] Shows current priority as selected
- [ ] Saves immediately on selection change
- [ ] Typecheck passes
- [ ] Verified in a browser: changing the dropdown updates the card's badge without a reload

### US-004: Filter tasks by priority
**Description:** As a user, I want to filter the task list to see only high-priority items when I'm focused.

**Acceptance Criteria:**
- [ ] Filter dropdown with options: All | High | Medium | Low
- [ ] Filter persists in URL params
- [ ] Empty state message when no tasks match filter
- [ ] Typecheck passes
- [ ] Verified in a browser: picking a filter narrows the list and updates the URL

## Functional Requirements

- FR-1: Add `priority` field to tasks table ('high' | 'medium' | 'low', default 'medium')
- FR-2: Display colored priority badge on each task card
- FR-3: Include priority selector in task edit modal
- FR-4: Add priority filter dropdown to task list header
- FR-5: Sort by priority within each status column (high to medium to low)

## Non-Goals

- No priority-based notifications or reminders
- No automatic priority assignment based on due date
- No priority inheritance for subtasks

## Technical Considerations

- Reuse existing badge component with color variants
- Filter state managed via URL search params
- Priority stored in database, not computed

## Success Metrics

- Users can change priority in under 2 clicks
- High-priority tasks immediately visible at top of lists
- No regression in task list performance

## Open Questions

- Should priority affect task ordering within a column?
- Should we add keyboard shortcuts for priority changes?
```

---

## Checklist

Before saving the PRD:

- [ ] Swept `ralph/tasks/` and `ralph/runs/` for in-flight PRDs and reported them before asking questions
- [ ] Nothing in this PRD re-specifies work an in-flight PRD owns; every superseded design names the PRD it replaces
- [ ] Overturning a design a part-run or finished run already built is carried as real user stories here
- [ ] Judged whether the work is Ralph-sized (Step 2b); if one session could finish it, said so and offered no run unprompted
- [ ] Asked clarifying questions with lettered options, prioritized (must-answer first)
- [ ] Asked follow-up questions until the blocking items were clear
- [ ] Restated the need in business language (no implementation talk) and got the user's confirmation
- [ ] Incorporated user's answers
- [ ] Captured any leftover uncertainties in Open Questions
- [ ] User stories are small and specific
- [ ] Each story's acceptance criteria are observable within that story itself, not deferred to a later story
- [ ] Functional requirements are numbered and unambiguous
- [ ] Non-goals section defines clear boundaries
- [ ] Saved to `ralph/tasks/prd-<feature-name>.md`
- [ ] If Ralph handoff was requested, generated `ralph/runs/<run_id>/prd.json`
