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

1. Receive a feature description from the user
2. Ask clarifying questions (with lettered options), prioritized by importance — no fixed count
3. Review the answers and ask follow-up questions for anything still ambiguous; iterate until the key information is clear
4. Restate the need in plain business language and get the user's confirmation before writing
5. Generate a structured PRD based on answers; record any minor remaining uncertainties in Open Questions
6. Save to `ralph/tasks/prd-<feature-name>.md` (substitute `<feature-name>` with a kebab-case slug)

**Important:** Do NOT start implementing. Just create the PRD.

If the user also wants the PRD prepared for Ralph execution, use the `ralph` skill after saving the markdown PRD. The
markdown task remains in `ralph/tasks/` while the run is in play (Ralph archives it into
`ralph/archive/<date>-<run_id>/` once the run completes), while the Ralph execution file should be generated as
`ralph/runs/<run_id>/prd.json`. The Ralph skill/script owns run-scoped execution state such as
`progress/shared-memory.json`, per-story `progress/<story_id>.jsonl`, `state.json`, and per-story `stories/*.json`.

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

What this feature will NOT include. Critical for managing scope.

### 6. Design Considerations (Optional)

- UI/UX requirements
- Link to mockups if available
- Relevant existing components to reuse

### 7. Technical Considerations (Optional)

- Known constraints or dependencies
- Integration points with existing systems
- Performance requirements

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
- **Ralph handoff:** Only when requested, also create `ralph/runs/<run_id>/prd.json` through the `ralph` skill.

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
