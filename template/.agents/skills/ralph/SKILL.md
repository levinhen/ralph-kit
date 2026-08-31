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

**Start by sweeping the work that is still in flight** — see
[Sweep the Runs Still in Flight](#step-0-sweep-the-runs-still-in-flight) below. That sweep is where `dependsOnRuns`
comes from, and it is the only thing standing between you and re-splitting work another run is already executing.

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
- `ralph/runs/<run_id>/deps-audit.json` — optional, written **after** a separate agent audits the split — see
  [Dependency Audit: A Separate Agent Re-derives the Edges](#dependency-audit-a-separate-agent-re-derives-the-edges).
  The lint reports a missing or stale audit as a `WARN:` line; the run starts either way.

Per-story progress records are appended to `ralph/runs/<run_id>/progress/<story_id>.jsonl` (one JSON object per
line, append-only) by `append-progress-json.sh` at iteration time. Do not pre-create those `.jsonl` files. Do not
pre-split `userStories` into `stories/*.json`; `ralph.sh` initializes per-story files from the run-scoped `prd.json` at
startup.

Do not overwrite an existing run directory unless the user explicitly asks to reset that run.

If you already have a valid `prd.json`, you can initialize the run directory with:

```bash
ralph/scripts/create-run.sh <run_id> path/to/prd.json
```

After writing the run files, always lint the PRD and fix everything it reports before handing the run to `ralph.sh`:

```bash
bash ralph/scripts/lint-prd.sh --run <run_id>
```

The lint rejects dangling, forward, self, and cyclic `dependsOn` references and `dependsOnRuns` entries that point at runs which do not exist. A `deps-audit.json` that is missing or no longer matches the split it audited is reported as a `WARN:` line and does not fail the lint (`RALPH_REQUIRE_DEPS_AUDIT=1` turns that back into an error, `RALPH_SKIP_DEPS_AUDIT=1` silences it). `ralph.sh` runs the same lint at startup and refuses to start on a failing PRD.

---

## Step 0: Sweep the Runs Still in Flight

**Do this first, every time, without being asked to.** Two things depend on it that nothing downstream can recover:
this run's `dependsOnRuns`, and whether you are about to re-split work another run is already executing.

You do not have to judge what counts as unfinished. A run and its source PRD move into
`ralph/archive/<date>-<run_id>/` only once that run is finished and consolidated, so **whatever is still sitting in
`ralph/tasks/` or `ralph/runs/` is in flight by definition**:

```bash
find ralph/tasks -maxdepth 1 -name 'prd-*.md' 2>/dev/null | sort   # PRDs written, not yet finished
ls ralph/prd.json 2>/dev/null                                      # a legacy-mode run, if this project has one
find ralph/runs -maxdepth 2 -name prd.json 2>/dev/null | sort | while read -r f; do
  printf '%s ' "$(dirname "$f")"
  jq -r '"\(.userStories | map(select(.passes == true)) | length)/\(.userStories | length) stories passing"' "$f"
done
```

(`find` rather than a `ralph/runs/*/` glob: an unmatched glob aborts the command outright under zsh, which is exactly
the case you hit on a project that has no runs yet.)

For any run that looks like it overlaps the PRD in front of you, read its stories rather than just its counts:

```bash
jq -r '.userNeed, (.userStories[] | "\(.id) passes=\(.passes) \(.title) — \(.description)")' ralph/runs/<x>/prd.json
```

**Report what you found before you split anything** — each in-flight PRD or run, how far it has got, and an explicit
note on any overlap with the PRD you are converting. An empty sweep is a one-line report, not silence.

Then let the sweep drive three decisions:

1. **`dependsOnRuns` comes from here.** An in-flight run whose code this run builds on — or whose output this run
   needs in order to verify its own stories — belongs in this run's root-level `dependsOnRuns`. The sweep is the only
   place you learn which runs exist to name, and the lint cannot cover for you: it rejects a `dependsOnRuns` entry
   pointing at a run that does not exist, but it has no way to notice an edge you never knew to write.
2. **Do not re-split work another run already owns.** If an in-flight run holds a slice of what this PRD describes,
   that slice does not get stories here. Two runs implementing one slice means two branches editing the same files and
   a merge-back collision. Either drop the slice from this run — naming the run that owns it, and adding the
   `dependsOnRuns` edge if you need its result — or, when this PRD deliberately supersedes that design, say so to the
   user and carry *changing* the other run's code as this run's own stories.
3. **A passing story is code, and not code this run can see yet.** A story marked `passes: true` in another run is
   code on **that run's branch**. This run's worktree is cut from the base branch, so until that run merges back its
   code does not exist here at all. A story whose criteria assume code from an unmerged run cannot be built *or*
   observed — that is precisely a `dependsOnRuns` edge, and it is a verification dependency as much as a build one.

Whether the PRD in front of you already has a run of its own is a separate check with its own rules — see
[Run Directory Handling](#run-directory-handling).

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
  "dependsOnRuns": [],
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
      "dependsOn": [],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

Two dependency fields make the decomposition auditable:

- **`dependsOn`** (per story): ids of stories in this same run that must be complete before this one — because it
  builds on their code **or because verifying it needs something they create** (a test runner, seed data, an endpoint).
  Every dependency must sit **earlier in the `userStories` array** than the story that names it; the array order is the
  execution order.
- **`dependsOnRuns`** (root): run ids of other Ralph runs whose changes must already be merged back into the base
  branch before this run starts — this run's worktree is created from the base branch, so an unmerged upstream run is
  invisible to it. Leave `[]` when the run is independent. See
  [Prefer Multiple Runs Over One Big Run](#prefer-multiple-runs-over-one-big-run).

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

Stories execute strictly in **array order** — `ralph.sh` always picks the first story with `passes != true`. Keep the
`priority` numbers consistent with the array order, but understand that the array order is what actually runs. Earlier
stories must not depend on later ones.

**Correct order:**

1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**

1. UI component (depends on schema that does not exist yet)
2. Schema change

**Make every dependency explicit in `dependsOn`.** Ordering the array correctly is not enough — write the actual
dependency edges into each story's `dependsOn` so the decomposition can be checked mechanically. Count both kinds of
dependency:

- **Build dependencies:** the story's code builds on another story's output (the UI story needs the schema story).
- **Verification dependencies:** checking the story's acceptance criteria needs something another story creates — a
  test harness, seed data, a running endpoint, a page to open. A story you cannot verify yet is just as blocked as a
  story you cannot build yet.

`lint-prd.sh` (run automatically by `ralph.sh` at startup) rejects a `dependsOn` that names a missing story, names the
story itself, points forward in the array, or forms a cycle. If the lint forces you to move a story earlier, that is
the decomposition telling you the original order was wrong.

---

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something Ralph can CHECK, not something vague.

### Good criteria (verifiable):

- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass for src/tasks/filter"

### Bad criteria (vague):

- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"
- "Verify with the <name> skill" — names a tool instead of an outcome, and is unsatisfiable wherever that tool is absent

### Always include as final criterion:

```
"Typecheck passes"
```

For stories with testable logic, also include a **scoped** test criterion that names what runs:

```
"Tests pass for src/tasks/filter"
```

Never put a whole-suite criterion (`"The test suite passes"`, `"npm test passes"`) on every story. A round only
touched one slice, so the other 95% of the suite re-runs to prove nothing — and in a project whose suite takes three
or four minutes, ten stories running it once or twice each burn an hour of wall clock per run. Scope every test
criterion to the paths the story owns.

The full suite belongs on **at most one story per run**: a final integration story, or the one story whose change is
genuinely cross-cutting (shared utility, config, build). If the project has no way to run a subset of its tests, say
so in that story's criterion and keep the full-suite line off the others.

### For stories that change UI, also include:

```
"Verified in a browser: <what should be visible or happen on screen>"
```

Name the observable result, never the tool that checks it. The implementing round uses whatever browser tooling it
actually has — a built-in browser/preview tool, a browser MCP server, a Playwright script the project already depends
on, or a browser skill installed in the repo. A criterion that names one specific helper is unsatisfiable in every
round that lacks it, which either stalls the story or gets it marked passing dishonestly.

Frontend stories are NOT complete until that observation is made. If a round has no way to drive a browser at all, it
records `browser verification: unavailable - <reason>` in its progress checks so a human can pick it up; it must never
claim a verification it did not perform.

---

## Verification Closure: Every Story Must Verify Itself in Its Own Round

Verifiable wording is not enough. Each criterion must also be **observable in the same round that implements the
story**, using only what exists once that story's own work (plus its `dependsOn` stories) is done. A story whose
criteria can only be checked after some *later* story lands is almost guaranteed to fail: the round either stalls
looking for a verification it cannot perform, or marks the story passing dishonestly. Either way the run stops and the
split has to be redone — so catch it now, at conversion time.

**The dry-run check.** After splitting, walk every story and ask, criterion by criterion:

> *"When the agent finishes implementing this story, what command does it run — or what does it open and look at — to
> observe this criterion, in that same round?"*

Every criterion needs a concrete answer: a test command, a typecheck, a migration that applies cleanly, an endpoint to
curl, a page to open and a thing to see on it. If the honest answer involves a later story or infrastructure nobody has
built yet, the split is wrong — fix the split, not the wording.

**The three classic failures and their fixes:**

1. **The observation point lives in a later story.** A schema story's criterion says "the badge shows the priority",
   but the badge arrives in US-003. → Move that criterion to the story that owns the observation point, and give the
   schema story its own observable outcome (the migration applies; a query returns the new column).
2. **The story has no observable outlet at all.** A pure-backend story with no test, no caller, and no endpoint —
   "Typecheck passes" is the only checkable line, so the real behavior goes unverified. → Add a genuine outlet to the
   story itself (a unit/integration test named in the criteria), or merge it with its first consumer into one vertical
   slice that can be observed end to end.
3. **The verification infrastructure arrives later.** The criteria assume a test runner, seed data, or a running dev
   server that a later story sets up. → Reorder so the infrastructure story comes first, and record the edge in
   `dependsOn` — verification dependencies are dependencies.

When a story fails the dry-run check, prefer **re-slicing vertically** (one thin end-to-end capability per story) over
padding criteria: a vertical slice always carries its own observation point, while horizontal layers have to borrow
one from the future.

---

## Dependency Audit: A Separate Agent Re-derives the Edges

**Recommended for a multi-story split, and you may never perform it yourself.** Once the split is written, a
*different* agent — a fresh context that has not seen your reasoning — re-derives every `dependsOn` edge and checks the
`Covers:` coverage from the source PRD and `prd.json` alone. Only after its findings are resolved does the run get its
`deps-audit.json`.

It is a second opinion, not a gate: `lint-prd.sh` warns about a missing or stale audit but still passes, and `ralph.sh`
still starts. Spend the extra agent call when the graph is worth checking — several stories, real edges between them,
a split you are not sure of. Skip it for a short or linear backlog, and say plainly that you skipped it.

**Why it cannot be you.** By the time you reach `dependsOn` you have already committed to a shape. A missed
verification edge is invisible from inside that shape: you know why US-003 comes after US-002, so "US-003 depends on
US-002" and "US-003 happens to follow US-002" feel like the same statement. A reader who never saw your reasoning has
to derive the edge from the story bodies, and derives a different answer when the edge is not really there. Re-reading
your own split produces agreement, not an audit.

### Running the audit

Spawn one fresh agent and give it **exactly three things**:

1. `ralph/scripts/DEPENDENCY_AUDIT.md` as its instructions,
2. the path to the source PRD document (`ralph/tasks/prd-<feature>.md`),
3. the path to `ralph/runs/<run_id>/prd.json`.

Use whatever isolation this session actually has — a subagent/task tool the host provides, or a one-shot CLI
subprocess, which works from any of the three tools:

```bash
# Pick the line for the CLI you are running under.
claude -p "$(cat ralph/scripts/DEPENDENCY_AUDIT.md)  Source PRD: ralph/tasks/prd-<feature>.md  prd.json: ralph/runs/<run_id>/prd.json"
codex exec "$(cat ralph/scripts/DEPENDENCY_AUDIT.md)  Source PRD: ralph/tasks/prd-<feature>.md  prd.json: ralph/runs/<run_id>/prd.json"
pi -p "$(cat ralph/scripts/DEPENDENCY_AUDIT.md)  Source PRD: ralph/tasks/prd-<feature>.md  prd.json: ralph/runs/<run_id>/prd.json"
```

**Do not send it your rationale.** No explanation of why you drew an edge, no summary of your approach discussion, no
"I split it this way because…". Every sentence of yours that reaches the auditor moves its answer toward yours, which
is the one thing the audit is supposed to be independent of. The three inputs above are the whole brief.

If no isolation mechanism works, skip the audit, tell the user the split went unaudited, and hand the run over anyway.
Never re-read your own split and write a `deps-audit.json` from it: an audit you performed yourself is worse than no
audit, because the file then claims a second opinion that never happened.

### Resolving the findings

The auditor reports `missing-edge` / `spurious-edge` / `coverage-gap` / `coverage-overlap` findings. Work through
every one:

- **`missing-edge`** — the auditor derived an edge you did not write. Default to **applying** it. This is the finding
  that actually breaks runs: a story starts before what it needs exists and fails, and the unblock round then has to
  re-derive the edge you skipped and restructure the split mid-run — the same auditing work, done under worse
  conditions than you have here.
- **`spurious-edge`** — the auditor could not justify an edge you wrote. Either remove it or state the justification
  the auditor lacked. A fake edge is not harmless: it serializes work that could have run in parallel and it buries
  the real edges among invented ones.
- **`coverage-gap`** — a slice of `userNeed` no story's `Covers:` clause claims. Fix the split, not just the wording:
  either add the missing story or extend the story that should own that slice.
- **`coverage-overlap`** — two stories claim the same slice. Decide which one owns it and narrow the other.

Rejecting a finding is allowed, but it costs you a written reason in the audit record. If applying the findings
changes story order or adds stories, **re-run the audit against the revised split** — the record has to describe the
split that will actually execute.

### Recording the result

Write `ralph/runs/<run_id>/deps-audit.json`:

```json
{
  "runId": "task-status",
  "storyOrder": ["US-001", "US-002", "US-003", "US-004"],
  "edges": {
    "US-001": [],
    "US-002": ["US-001"],
    "US-003": ["US-001", "US-002"],
    "US-004": ["US-001"]
  },
  "coverage": "complete",
  "findings": [
    {
      "kind": "missing-edge",
      "storyId": "US-003",
      "detail": "US-003's criterion is observed by looking at a task row, and the row only renders its status once US-002 adds the badge.",
      "resolution": "applied"
    }
  ]
}
```

- **`runId`** must match the run directory name.
- **`storyOrder`** lists every story id in `prd.json` order.
- **`edges`** repeats every story's final `dependsOn`. The lint compares it against `prd.json` **edge for edge** and
  warns on a disagreement, so copying it is a last read-through of the graph — and any later change to a `dependsOn`
  invalidates the audit instead of silently outliving it.
- **`coverage`** must be `"complete"`. A gap or an overlap means the split still needs fixing: fix it, re-run the
  audit, then record the resolved findings.
- **`findings`** records every finding the auditor raised, with `kind` (one of the four above), optional `storyId`,
  a non-empty `detail`, and a `resolution` of `"applied"` or `"rejected: <reason>"`. Use `[]` when the audit came back
  clean — that is a real and common outcome, not a reason to invent findings.

Then re-run `bash ralph/scripts/lint-prd.sh --run <run_id>` and fix anything it reports.

A story unblock round can rewrite this file. When a story turns out to be genuinely blocked — its acceptance criteria
cannot be satisfied from inside it — that round restructures the split and re-runs the audit against the new shape,
exactly the way you ran it here. The file always describes the split that is currently executing, never the one the run
started with.

> `RALPH_SKIP_DEPS_AUDIT=1` bypasses the check. It exists for runs created before the audit was introduced. Do not
> reach for it to get past a lint error on a run you just wrote — that is the case the gate is for.

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
9. **Always add**: "Typecheck passes" to every story's acceptance criteria. That is the only blanket criterion —
   test criteria name the story's own paths, and the full suite appears on at most one story in the run.
10. **dependsOn**: Every story lists its real build **and verification** dependencies by story id. Dependencies may
    only point at earlier array entries. Omit or leave `[]` for genuinely independent stories — do not fabricate a
    linear chain.
11. **dependsOnRuns**: At the root, list the run ids this run needs merged back first — including any run the
    Step 0 sweep turned up whose code this run builds on or needs to verify itself; `[]` when independent.
12. **Dependency audit** (recommended for a multi-story graph, not required): a separate agent re-derives the edges
    and the `Covers:` coverage per
    [Dependency Audit](#dependency-audit-a-separate-agent-re-derives-the-edges); its resolved findings and the final
    graph go into `ralph/runs/<run_id>/deps-audit.json`. Never audit your own split — skip it and say so instead.
13. **Lint before handoff**: `bash ralph/scripts/lint-prd.sh --run <run_id>` must pass; fix reported errors by fixing
    the split, not by deleting the dependency fields.

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

## Prefer Multiple Runs Over One Big Run

A run is Ralph's unit of isolation and delivery: its own branch, worktree, state, merge-back, and archive. When the
work is really several separable deliverables, **split it into several runs** instead of one long story list, and let
the orchestrator execute the run graph. Lean toward splitting when:

- the story list heads past roughly 8–10 stories;
- the work contains milestones that are independently mergeable and useful (a data layer, then features on top);
- distinct subsystems barely share code — separate runs let them proceed in parallel worktrees;
- part of the work is riskier or more exploratory — isolating it keeps a failure from freezing the rest.

Rules for a multi-run split:

1. **Each run must close its own loop.** A run ends with the base branch containing a coherent, verified increment —
   all of that run's stories pass and the branch merges back cleanly. Never split so that a run ends in a half-wired
   state only a later run can make sense of; the run boundary is a merge boundary.
2. **Declare the edges in `dependsOnRuns`.** A run that builds on another run's code lists that run's id. The
   dependency means "must already be merged back into the base branch", because each run's worktree is created from
   the base branch — an unmerged upstream run simply is not visible downstream.
3. **Keep independent runs independent.** No `dependsOnRuns` entry means the orchestrator may run them in parallel;
   do not add fake edges for sequencing comfort.
4. **Apply the same closure check at run level.** Ask of each run: "when this run's stories all pass, what does the
   base branch observably do that it could not do before?" A run with no answer is a layer, not a deliverable — merge
   it into the run that consumes it.

`orchestrate.sh` reads `dependsOnRuns` across `ralph/runs/*/prd.json`, starts every run whose dependencies are already
merged back (or archived), runs independent runs in parallel, and blocks a run's downstream when it fails. Completed
runs are archived by the consolidation round or `archive-runs.sh`, so the runs directory stays a worklist of what is
still in play.

Scheduling happens inside the subset the operator selected for that invocation (`--only`, or the interactive picker),
not across the whole directory. A selected run whose `dependsOnRuns` names a run left out of the selection is reported
as unrunnable and left alone rather than started — one more reason an edge has to be real work this run cannot see,
never sequencing comfort.

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
  "dependsOnRuns": [],
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
      "dependsOn": [],
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
        "Verified in a browser: each card's badge color matches that task's status"
      ],
      "dependsOn": ["US-001"],
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
        "Verified in a browser: changing a row's status updates the row without a reload"
      ],
      "dependsOn": ["US-001", "US-002"],
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
        "Verified in a browser: picking a filter narrows the list and updates the URL"
      ],
      "dependsOn": ["US-001"],
      "priority": 4,
      "passes": false,
      "notes": ""
    }
  ]
}
```

Note the edges: US-003 depends on US-002 as a **verification** dependency — observing "the row updates without a
reload" needs the badge from US-002 on screen — while US-004 needs only the schema, so it does not inherit a fake edge
through US-002/US-003.

---

## Run Directory Handling

**Before writing a new run-scoped prd.json, check whether `ralph/runs/<run_id>/` already exists:**

1. If the run directory does not exist, create it and write fresh `prd.json`, `progress.txt`, `progress/shared-memory.json`, and `state.json`.
2. If the run directory exists for the same feature, update it only if the user asked to revise that run.
3. If the run directory exists for a different feature, choose a different `run_id` instead of overwriting it.
4. Do not use root-level `ralph/prd.json` for new runs unless the user explicitly asks for legacy mode.
5. Also check `ralph/archive/` — a completed run with the same `run_id` may already be archived (folder name `<date>-<run_id>`, holding the run dir contents plus the source `prd-<run_id>.md`). If so, pick a fresh `run_id` (e.g., append a suffix) rather than reviving an archived run.

## Working with Merged PRDs

If the source PRD has `status: merged` frontmatter (such PRDs live under `ralph/archive/<date>-<run_id>/`, not `ralph/tasks/`), it has already been distilled into `docs/design-ledger/<area>.md` and Ralph already ran it. Before converting:

1. Tell the user the PRD is marked merged and ask whether they want to:
   - Pick a different PRD,
   - Write a *new* PRD that evolves the design (preferred), or
   - Override and re-run anyway (rare).
2. When writing stories that touch areas listed in the PRD's `superseded-by`, read those ledger files first and base your acceptance criteria on the current design, not on what the historical PRD says.

The `ralph.sh` script discovers run-scoped PRDs and starts them with `--run <run_id>`. On startup it lints the PRD
(`lint-prd.sh`), refuses to start while a `dependsOnRuns` entry is not yet merged back, creates per-story files under
`stories/`, injects only the current story plus sliced shared memory and recent per-story records into the agent
prompt, and syncs story files back into the run PRD after each iteration. Per-story records are appended one JSON
object per line into `progress/<story_id>.jsonl`.

A story that does not reach `passes: true` gets one story unblock round (`UNBLOCK_STORY.md`). That round first decides
whether the story was merely unfinished — in which case it finishes it — or genuinely blocked, meaning its acceptance
criteria cannot be satisfied from inside it because the observation point, the verification setup, or a dependency
belongs elsewhere. A blocked story is repaired by restructuring the run PRD, re-running the dependency audit against
the new split, and letting the loop continue on it. Ralph stops for human review only when neither is possible.

---

## Checklist Before Saving

Before writing run-scoped `prd.json`, verify:

- [ ] Swept `ralph/tasks/` and `ralph/runs/` for work still in flight and reported it before splitting
- [ ] No story re-implements a slice an in-flight run already owns, and no criterion assumes code from an unmerged run
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
- [ ] Test criteria name the story's own paths; at most one story carries a full-suite run
- [ ] UI stories have a "Verified in a browser: ..." criterion naming what to look at, with no tool or skill name in it
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
- [ ] Verification closure dry-run done: every criterion is observable in its own story's round
- [ ] `dependsOn` records the real build and verification edges (no fabricated linear chain)
- [ ] Dependency audit: either a separate agent ran it — every finding applied or rejected with a written reason, and
      `deps-audit.json` agreeing with `prd.json` edge for edge — or it was skipped and the user was told
- [ ] Considered splitting into multiple runs; run-level edges — to new runs and to in-flight ones — are declared in `dependsOnRuns`
- [ ] `bash ralph/scripts/lint-prd.sh --run <run_id>` reports OK
