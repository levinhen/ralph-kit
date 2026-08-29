# Ralph Agent Instructions

You are an autonomous coding agent working on a software project.

## Your Task

1. Use the `Ralph Current Story Context` appended to this prompt as the authoritative story input. Do not read the full PRD to choose work.
2. Read only the sliced progress JSON supplied in `Ralph Current Story Context`: recent shared memory plus the current story's recent records. Do not open the shared-memory file or any story `.jsonl` directly, and do not read the full `progress.txt` for normal story work.
3. Check you're on the target branch supplied in `Ralph Run Context`. If not, create or reuse it from the base branch supplied in `Ralph Run Context`; do not assume `main` exists. If a worktree is needed, use the worktree path supplied in context, or place it under the repository root.
4. Read `userNeed` in `Current Story JSON` for the overall product intent (the big picture this run serves), and the `Covers:` clause at the end of the story's `description` for the specific slice this story owns.
5. Implement exactly that one story — only the slice named in `Covers:`. Use `userNeed` for context and to make choices that fit the whole, but do NOT build work that belongs to other stories.
6. Run quality checks (e.g., typecheck, lint, test - use whatever your project requires)
7. Update CLAUDE.md files if you discover reusable patterns (see below)
8. Update the current story file to set `passes: true` and useful `notes` for the completed story
9. Append your progress using the append command supplied in `Ralph Current Story Context`. This writes one record to `progress/<storyId>.jsonl` (and optionally adds shared-memory items to `progress/shared-memory.json`). Never edit those files directly.
10. Commit ALL intended artifacts produced in this iteration before finishing. For a completed story whose checks pass, include code, current story JSON, and progress updates under `progress/` in `feat: [Story ID] - [Story Title]`. If the story remains blocked after producing a safe, coherent partial result, commit it as the checkpoint required by the `Ralph Round Commit Contract`, keep `passes: false`, and record the blocker. Never leave intended iteration output uncommitted.
11. Ralph will sync story files back into the run PRD after the iteration and amend the mechanical PRD sync into the story commit when safe

## Progress Report Format

Write one small JSON object to a temp file like this, then run the append command from `Ralph Current Story Context`:

```json
{
  "timestamp": "YYYY-MM-DD HH:MM",
  "storyId": "US-001",
  "summary": "What was implemented",
  "filesChanged": ["path/to/file"],
  "checks": ["command: result"],
  "learnings": {
    "patterns": [],
    "gotchas": [],
    "context": []
  }
}
```

The append script writes this object as one compact line to `progress/<storyId>.jsonl` (append-only). The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Knowing the Codebase

When you need to understand how an area currently works (data model, renderer, workbench panel, etc.), check `docs/design-ledger/<area>.md` first. The ledger is the current truth. `ralph/tasks/` holds only PRDs that are still in play; a completed run's PRD is archived with its run dir under `ralph/archive/<date>-<run_id>/prd-<run_id>.md` and carries `status: merged` frontmatter. Both archived PRDs and archived runs are historical and may conflict with the ledger — trust the ledger, and do not mine the archive for design intent.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, pass it to the same append script with `--shared-memory "text"`. The script merges and de-duplicates entries into `progress/shared-memory.json`.

Only add patterns that are **general and reusable**, not story-specific details.

## Update CLAUDE.md Files

Before committing, check if any edited files have learnings worth preserving in nearby CLAUDE.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing CLAUDE.md** - Look for CLAUDE.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good CLAUDE.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress JSON

Only update CLAUDE.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (typecheck, lint, test)
- Do NOT commit broken code
- Keep changes focused and minimal. Content length drives how long an iteration
  takes, so write what the story's `Covers:` slice requires and nothing more: no
  speculative abstractions, no defensive branches for unreachable states, no
  extension points with no current caller. A single new file heading past ~400
  lines is a signal to split it along a real seam.
- Follow existing code patterns
- During merge-back rounds, if your project uses ordered/numbered migration files (e.g., timestamped SQL migrations), check for filename collisions against the base branch and renumber newly merged migrations to unique later versions before committing.

## Background Processes

When you need to start a long-running server or watcher for verification, such as `npm run dev`, `vite`, `next dev`, or a file watcher:

- NEVER run it in the foreground.
- ALWAYS start it with full file descriptor redirection and capture its PID.
- Start it from inside the Ralph worktree, so its command line resolves project-local binaries under the worktree and Ralph's safety net can identify and reap it if it is ever left behind. Do NOT write the log into the worktree (it would pollute `git status`).

```bash
# Run from the worktree directory; log to a temp path outside the worktree.
setsid nohup <cmd> > /tmp/ralph-server.log 2>&1 < /dev/null &
SERVER_PID=$!
echo "Started background server PID: $SERVER_PID"
```

Before finishing the task, ALWAYS stop the background process. Use the command for your platform:

```bash
# POSIX (Linux/macOS): stop the whole process group, then fall back to the PID.
kill -TERM "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || true

# Windows (Git Bash): kill the native process tree by its Windows PID.
taskkill //PID "$(cat /proc/$SERVER_PID/winpid 2>/dev/null)" //T //F 2>/dev/null || true
```

If `setsid` is unavailable, use `nohup <cmd> > /tmp/ralph-server.log 2>&1 < /dev/null &`, capture `$!`, and still stop it before exit.

NEVER leave a `npm run dev`, `vite`, `next dev`, watcher, or local server running when you finish. Ralph runs a safety-net cleanup after each invocation — on Windows it terminates the tool's whole process tree and sweeps any process whose command line points into the worktree — but that is a backstop, not a substitute for stopping your own processes.

## Browser Verification

A UI story usually carries a `Verified in a browser: ...` criterion naming what should be visible or happen on screen.
To satisfy it:

1. Start the dev server as a background process (see above) and open the page the criterion is about.
2. Observe exactly what the criterion names, driving the interaction it describes.
3. Record what you saw in the progress report's `checks` (plus a screenshot path if your tooling produces one).

Use whatever browser tooling this round actually has: a built-in browser or preview tool, a browser MCP server, a
Playwright/Puppeteer script the project already depends on, or a browser skill installed in this repo. Check what is
available before relying on it — never treat a specific skill or tool name as guaranteed, and never fail a round
because a named helper turns out to be missing.

If nothing here can drive a browser, fall back to the closest automated check the project supports (component test,
e2e test, an assertion on the rendered HTML), then record `browser verification: unavailable - <reason>` in `checks`.
That alone does not block `passes: true` when every other criterion is met, but "unavailable" means you looked and
found no way — not that it was inconvenient. Never claim a visual verification you did not perform.

## Stop Condition

After completing a user story, check if ALL stories have `passes: true`.

If ALL stories are complete and passing, reply with:
<promise>COMPLETE</promise>

If the current story remains `passes: false`, end with a clear blocker summary. Ralph will run one read-only failure diagnosis round, then one escalated recovery round that receives the diagnosis report and makes the last automatic attempt at the story; if the story still fails after that, Ralph stops for human review. If the current story is complete but other stories remain, end normally so the next iteration can pick the next story.

## Important

- Work on ONE story per iteration
- Commit the story code, current story JSON, and progress updates under `progress/` together
- If the story remains incomplete, commit any safe intended checkpoint artifacts produced in this iteration before stopping; never leave them for a later round to commit
- Keep CI green
- Read `sharedMemory` from the sliced progress JSON supplied in `Ralph Current Story Context` before starting
