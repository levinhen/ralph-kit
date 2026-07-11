---
name: ralph
description: "Convert PRDs to run-scoped prd.json format for the Ralph autonomous agent system. Use when you have an existing PRD and need to convert it to Ralph's JSON format. Triggers on: convert this prd, turn this into ralph format, create prd.json from this, ralph json."
user-invocable: true
---

<!--
Distributed by ralph-kit (https://github.com/levinhen/ralph-kit).
Derived from snarktank/ralph (https://github.com/snarktank/ralph), MIT-licensed.
-->

# Ralph PRD Converter

Converts existing PRDs to the prd.json format that Ralph uses for autonomous execution.

---

## The Job

Take a PRD (markdown file or text) and convert it to a run-scoped `prd.json` under
`ralph/runs/<run_id>/prd.json`.

**This is not a mechanical transcription.** Before splitting the PRD into stories, validate that the approach baked into
the PRD actually fits the user's need — see [Validate the Approach Before Splitting Stories](#validate-the-approach-before-splitting-stories)
below. Only after the approach is sound (or corrected) do you split it into user stories.

Choose a stable `run_id` from the feature name unless the user provides one. Use kebab-case with only letters, numbers,
dots, underscores, and dashes, matching the `ralph.sh --run <run_id>` validation rules. For example, `core-protocol`
maps to `ralph/runs/core-protocol/prd.json` and `.worktrees/core-protocol`.

Before choosing `branchName`, inspect the local git environment for the repository you are in. Treat the currently
checked-out local branch as the base branch for the Ralph run unless the user says otherwise. Do not assume the base
branch is `main` or `master`.

Also initialize these companion files for a new run:

- `ralph/runs/<run_id>/progress.txt` with a Ralph progress header
- `ralph/runs/<run_id>/progress/shared-memory.json` initialized to `[]` (cross-story patterns/gotchas)
- `ralph/runs/<run_id>/state.json` with `runId`, `baseBranch`, `baseSha`, `targetBranch`, and `status: "ready"`

Per-story progress records are appended to `ralph/runs/<run_id>/progress/<story_id>.jsonl` (one JSON object per
line, append-only) by `append-progress-json.sh` at iteration time. Do not pre-create those `.jsonl` files. Do not
pre-split `userStories` into `stories/*.json`; `ralph.sh` initializes per-story files from the run-scoped `prd.json` at
startup.

Do not overwrite an existing run directory unless the user explicitly asks to reset that run.

If you already have a valid `prd.json`, you can initialize the run directory with:

```bash
ralph/scripts/create-run.sh <run_id> path/to/prd.json
```

---

## Validate the Approach Before Splitting Stories

A PRD usually already bakes in a *solution* — both in its Technical/Design Considerations and implicitly in how its user
stories are written ("add a `priority` column", "add a badge component" are already implementation choices). **Do not
blindly convert that approach into stories.** A flawed approach faithfully transcribed just propagates the flaw into
execution. Do this first:

1. **Recover the user need.** Read the business-language statement of what the user actually wants from the PRD's
   **Introduction/Overview** (the `prd` skill writes this in product terms, not implementation terms). If it is missing
   or unclear, ask the user before proceeding — do not guess.

2. **Step back from the PRD's proposed solution** and re-think it against that need:
   - Does this approach actually solve the stated problem?
   - Is it the simplest/most appropriate way, or is there a clearly better alternative?
   - Any risks, gaps, or hidden assumptions? Does it over-build beyond the need, or under-build and miss the goal?

3. **Decide:**
   - **If the approach is sound** → proceed directly to splitting it into user stories. No need to check in with the user.
   - **If the approach looks wrong or there's a clearly better option** → **stop.** Surface your concern and the
     alternative to the user in plain terms, and wait for them to confirm or pick a direction. Do not start splitting
     until the approach is agreed.

4. **Split from the *agreed* approach**, not necessarily the PRD's original stories. The PRD's stories are a starting
   suggestion; re-derive them from the validated approach if it changed. As you split, carry the user need into every
   story — see [Give Every Story the Big Picture](#give-every-story-the-big-picture).

> This makes conversion a thinking step, not a transcription step. The PRD answers *"what does the user need"*; this step
> confirms *"is the planned solution the right one"* before locking it into executable stories.

---

## Output Format

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature description from PRD title/intro]",
  "userNeed": "[The confirmed business-language restatement of what the user actually needs — from the PRD Introduction/Overview]",
  "userStories": [
    {
      "id": "US-001",
      "title": "[Story title]",
      "description": "As a [user], I want [feature] so that [benefit]. Covers: [which slice of the overall user need this story is responsible for].",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

Write `userNeed` **once, at the root**. You do not copy it into each story by hand — when `ralph.sh` splits the PRD
into per-story files, it copies the root `userNeed` into every `stories/<id>.json` automatically, so each memoryless
iteration still sees it.

---

## Give Every Story the Big Picture

Each Ralph iteration is a **fresh, memoryless agent that only sees its own story file** — `ralph.sh` splits each story
object into `stories/<id>.json` and the agent is told not to read the full PRD. So if the overall intent only lives in
the PRD, the agent building US-003 has no idea what it's ultimately for. Fix this by carrying two things into every
story:

1. **`userNeed` — the big picture, written once at the root.** Take the confirmed business-language restatement (the
   same one recovered in *Validate the Approach*, from the PRD's Introduction/Overview) and write it as a single
   **root-level `userNeed`** field. Keep it in product terms, not implementation terms. You do **not** duplicate it into
   each story — `ralph.sh` copies the root `userNeed` into every `stories/<id>.json` when it splits the PRD
   ([`initialize_story_files`](../../../ralph/scripts/lib/story-state.sh)), so each story file ends up self-contained and
   its agent sees the big picture without reading the full PRD.

2. **`description` scope clause — which slice this story owns.** When you split the work, every story's `description`
   must end with a **`Covers:`** clause stating which part of the overall `userNeed` this story is responsible for. This
   tells the agent how its one piece fits the whole, and makes the decomposition auditable (you can read the `Covers:`
   clauses top to bottom and confirm they tile the whole need with no gaps or overlap).

> Rule of thumb: read just the `userNeed` plus the `Covers:` clauses end to end. Together they should fully account for
> the user's need — nothing missing, nothing doubled. If they don't tile cleanly, the split is wrong, not the wording.

---

## Story Size: The Number One Rule

**Each story must be completable in ONE Ralph iteration (one context window).**

Ralph spawns a fresh Amp instance per iteration with no memory of previous work. If a story is too big, the LLM runs out
of context before finishing and produces broken code.

### Right-sized stories:

- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):

- "Build the entire dashboard" - Split into: schema, queries, UI components, filters
- "Add authentication" - Split into: schema, middleware, login UI, session handling
- "Refactor the API" - Split into one story per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order:**

1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**

1. UI component (depends on schema that does not exist yet)
2. Schema change

---

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something Ralph can CHECK, not something vague.

### Good criteria (verifiable):

- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass"

### Bad criteria (vague):

- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as final criterion:

```
"Typecheck passes"
```

For stories with testable logic, also include:

```
"Tests pass"
```

### For stories that change UI, also include:

```
"Verify in browser using dev-browser skill"
```

Frontend stories are NOT complete until visually verified. Ralph will use the dev-browser skill to navigate to the page,
interact with the UI, and confirm changes work.

---

## Conversion Rules

1. **Each user story becomes one JSON entry**
2. **IDs**: Sequential (US-001, US-002, etc.)
3. **Priority**: Based on dependency order, then document order
4. **All stories**: `passes: false` and empty `notes`
5. **userNeed**: Write the confirmed business-language restatement once as the top-level `userNeed` only; `ralph.sh`
   copies it into each `stories/<id>.json` at split time, so do not hand-duplicate it into the story objects
6. **description**: Every story's `description` ends with a `Covers:` clause naming the slice of `userNeed` it owns;
   the clauses together must tile the whole need with no gaps or overlap
7. **run_id**: Derive a stable run id from the feature name and write files under `ralph/runs/<run_id>/`.
8. **branchName**: Derive a Ralph execution branch from the current local git branch context, using a feature-specific
   kebab-case suffix prefixed with `ralph/`. This branch is meant to be created from the repository's current
   checked-out local branch, not from an assumed default branch.
9. **Always add**: "Typecheck passes" to every story's acceptance criteria

### Branch and Worktree Rules

- Inspect the repository's current local git branch before writing the run-scoped `prd.json`.
- Treat that current local branch as the source branch for the future Ralph execution branch unless the user explicitly
  says otherwise.
- Keep `branchName` as a dedicated `ralph/...` branch name, but do not encode assumptions that it will be created from
  `main`.
- Use a unique Ralph `run_id` for each independent Ralph loop.
- If a worktree is used for the Ralph branch, place it under the repository root at `.worktrees/<run_id>`.
- Never place Ralph worktrees in a sibling directory next to the repository root.

---

## Splitting Large PRDs

If a PRD has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**

1. US-001: Add notifications table to database
2. US-002: Create notification service for sending notifications
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality
6. US-006: Add notification preferences page

Each is one focused change that can be completed and verified independently.

---

## Example

**Input PRD:**

```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Toggle between pending/in-progress/done on task list
- Filter list by status
- Show status badge on each task
- Persist status in database
```

**Output `ralph/runs/task-status/prd.json`:**

```json
{
  "project": "TaskApp",
  "branchName": "ralph/task-status",
  "description": "Task Status Feature - Track task progress with status indicators",
  "userNeed": "People managing a task list can't tell what's underway versus done, so things get dropped or duplicated. They want to see each task's progress at a glance, update it as work moves along, and narrow the list to whatever they're focused on.",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add status field to tasks table",
      "description": "As a developer, I need to store task status in the database. Covers: the foundation for tracking progress — persisting each task's state so the rest of the need can build on it.",
      "acceptanceCriteria": [
        "Add status column: 'pending' | 'in_progress' | 'done' (default 'pending')",
        "Generate and run migration successfully",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Display status badge on task cards",
      "description": "As a user, I want to see task status at a glance. Covers: the 'see progress at a glance' slice of the need.",
      "acceptanceCriteria": [
        "Each task card shows colored status badge",
        "Badge colors: gray=pending, blue=in_progress, green=done",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Add status toggle to task list rows",
      "description": "As a user, I want to change task status directly from the list. Covers: the 'update it as work moves along' slice of the need.",
      "acceptanceCriteria": [
        "Each row has status dropdown or toggle",
        "Changing status saves immediately",
        "UI updates without page refresh",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 3,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-004",
      "title": "Filter tasks by status",
      "description": "As a user, I want to filter the list to see only certain statuses. Covers: the 'narrow the list to whatever they're focused on' slice of the need.",
      "acceptanceCriteria": [
        "Filter dropdown: All | Pending | In Progress | Done",
        "Filter persists in URL params",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 4,
      "passes": false,
      "notes": ""
    }
  ]
}
```

---

## Run Directory Handling

**Before writing a new run-scoped prd.json, check whether `ralph/runs/<run_id>/` already exists:**

1. If the run directory does not exist, create it and write fresh `prd.json`, `progress.txt`, `progress/shared-memory.json`, and `state.json`.
2. If the run directory exists for the same feature, update it only if the user asked to revise that run.
3. If the run directory exists for a different feature, choose a different `run_id` instead of overwriting it.
4. Do not use root-level `ralph/prd.json` for new runs unless the user explicitly asks for legacy mode.
5. Also check `ralph/archive/` — a completed run with the same `run_id` may already be archived (folder name `<date>-<run_id>`). If so, pick a fresh `run_id` (e.g., append a suffix) rather than reviving an archived run.

## Working with Merged PRDs

If the source PRD has `status: merged` frontmatter, it has already been distilled into `docs/design-ledger/<area>.md` and Ralph already ran it. Before converting:

1. Tell the user the PRD is marked merged and ask whether they want to:
   - Pick a different PRD,
   - Write a *new* PRD that evolves the design (preferred), or
   - Override and re-run anyway (rare).
2. When writing stories that touch areas listed in the PRD's `superseded-by`, read those ledger files first and base your acceptance criteria on the current design, not on what the historical PRD says.

The `ralph.sh` script discovers run-scoped PRDs and starts them with `--run <run_id>`. On startup it creates per-story
files under `stories/`, injects only the current story plus sliced shared memory and recent per-story records into the
agent prompt, and syncs story files back into the run PRD after each iteration. Per-story records are appended one JSON
object per line into `progress/<story_id>.jsonl`.

---

## Checklist Before Saving

Before writing run-scoped `prd.json`, verify:

- [ ] Validated the PRD's approach against the user need; if it looked off, confirmed the approach with the user before splitting
- [ ] `userNeed` (the business-language restatement) is set once at the root (the script copies it into each story at split time)
- [ ] Every story's `description` ends with a `Covers:` clause, and the clauses tile the whole `userNeed` (no gaps/overlap)
- [ ] `run_id` is unique and valid for `ralph.sh --run <run_id>`
- [ ] Files are written under `ralph/runs/<run_id>/`
- [ ] `progress.txt`, `progress/shared-memory.json`, and `state.json` are initialized for new runs
- [ ] No `progress/<story_id>.jsonl` files were pre-created — those are written at iteration time
- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (schema to backend to UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] UI stories have "Verify in browser using dev-browser skill" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
