# Ralph Consolidation Round

This run is the dedicated post-merge consolidation round for Ralph.

The Ralph branch has already been merged into the base branch. Your only job in this round is to **distill the design decisions from the completed run into the active design ledger**, so future LLM searches see the current truth instead of an accumulating pile of historical, sometimes-conflicting PRDs.

Do not pick another user story. Do not implement a new feature. Do not modify product source code.

## Required Behavior

1. Stay on the base branch workspace provided in the run context.
2. Read these inputs (paths supplied in `Ralph Run Context` and `Ralph Consolidation Context`):
   - The run's PRD (`prd.json`): original scope and acceptance criteria.
   - The run's story files (`stories/*.json`): each story's title, criteria, notes.
   - The run's progress entries (`progress/*.jsonl`): what was actually built, learnings, gotchas, files changed.
   - The corresponding source PRD markdown if present at `ralph/tasks/prd-<run-id>.md`.
3. Decide which **design areas** this run affected. An "area" is a coherent slice of the codebase. Use the `filesChanged` lists in progress entries to infer the areas. Prefer kebab-case names that align with top-level source directories. Examples: `frontend-workbench-review`, `domain-model-results`, `pdf-renderer`, `rendering-parser`, `bundle-import`. One run may touch multiple areas; one ledger file may receive updates from multiple runs over time.
4. For each affected area, update (or create) `docs/design-ledger/<area>.md`:
   - The ledger is the **current authoritative design**. Future LLMs will read this instead of historical PRDs.
   - Write what the design IS NOW, not the history of how it got there.
   - When this run supersedes a prior decision recorded in the ledger:
     - Replace the superseded section with the new decision.
     - At the bottom of the affected section, add one line: `_Updated YYYY-MM-DD by run <run-id> (was: <one-line summary of prior decision>)._`
   - Keep entries scannable: short headings, bullet lists for invariants, code paths in backticks, link to representative source files. A reader should find the answer to "how does X work today?" in under 30 seconds.
   - Do NOT copy the full PRD into the ledger. Compress aggressively. Keep only decisions and invariants that future work needs to respect — drop acceptance criteria, story-by-story rationale, and historical context.
5. If a source PRD exists at `ralph/tasks/prd-<run-id>.md`, add or update YAML frontmatter at the very top:

   ```yaml
   ---
   status: merged
   merged-on: <today's date in YYYY-MM-DD>
   merged-run: <run-id>
   superseded-by:
     - docs/design-ledger/<area-1>.md
     - docs/design-ledger/<area-2>.md
   ---
   ```

   Preserve the existing markdown body untouched. Do not rewrite the body. If frontmatter already exists, update fields in place.
6. Stage and commit the ledger updates and PRD frontmatter together:
   - Commit message: `docs: consolidate <run-id> into design-ledger`
   - Include the ledger files and the source PRD frontmatter change. Do not include the consolidation marker file.
   - Include every intended repository artifact produced by this consolidation round. Do not leave consolidation output for the archive step or a later retry to commit.
   - Before writing the marker, run `git status --short` and verify that no intended consolidation artifact remains uncommitted. Unrelated pre-existing files may remain visible; do not include them.
7. Write the consolidation completion marker at the path supplied in `Ralph Consolidation Context`. The marker file must contain exactly these lines:

   ```text
   status=done
   run_id=<run-id>
   ```

   Only after the marker is written may you treat this round as complete.

## Idempotency

If this run's content already appears reflected in the ledger (e.g., a prior consolidation attempt got partway through), do not duplicate. Read carefully, verify the ledger reflects the run's outcomes, then write the marker without further commits.

## If There Is Nothing To Consolidate

If the run produced no design decisions worth recording (e.g., a pure mechanical refactor with no behavioral, contract, or layout changes), still:

- Add `status: merged` frontmatter to the source PRD if one exists.
- Write the marker.
- Skip the ledger updates.

Use commit message: `docs: mark <run-id> merged (no design-ledger changes)`.

## Background Processes

Same rule as `MERGE_BACK.md`: never run a long-running server or watcher in the foreground. Use full file descriptor redirection, capture the PID, kill the process group before exit:

```bash
setsid nohup <cmd> > /tmp/ralph-server.log 2>&1 < /dev/null &
SERVER_PID=$!
```

```bash
kill -TERM "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || true
```

You should rarely need a server for consolidation work.

## If You Cannot Finish

- Do not write the consolidation marker.
- Do not emit `<promise>COMPLETE</promise>`.
- Briefly explain the blocker and stop normally so the outer loop can continue.
