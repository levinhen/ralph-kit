# Scaffold Cleanup Round

Every user story on this branch already passes. This round is the last code round before merge-back, and it has exactly one job: remove the scaffolding the story rounds left behind, so what merges into the base branch is the feature and nothing else.

Do not pick another user story. Do not implement a new feature. Do not start the merge-back.

## Why This Round Exists

Each story round was scoped to one slice and had to prove that slice on its own, with the rest of the run not yet built. So it propped itself up: a per-story test command, a seeded fixture, a demo route, a stub standing in for something that only landed two stories later. That propping was correct for the round that wrote it and is wrong for the branch that ships — and no story round could ever have removed it, because each one only saw its own slice. You see the whole branch. You are the only round that can.

## Required Behavior

1. Stay in the Ralph worktree supplied in the run context, on the Ralph branch. Do not touch the base checkout.
2. Establish what this run actually introduced before deciding anything, using the base commit supplied in `Scaffold Cleanup Context`:

```bash
git diff --stat <base sha>..HEAD
git log --oneline <base sha>..HEAD
```

   Anything that already existed at the base commit is out of scope for this round, however untidy it looks. You are removing this run's propping, not tidying the project.
3. Read the run's progress records for lines the story rounds wrote as `scaffold: <what> - <why>`. Those are self-reported scaffolding and the shortest path to the list. They are a starting point, not the whole list — a round that forgot to declare its scaffolding still left it in the diff.
4. Remove what the checklist below identifies as scaffolding, one coherent change at a time.
5. Re-point, do not delete, anything that still carries real value under a scaffold-shaped name (see `Renaming Over Deleting`).
6. Run the project's whole test suite — one-shot, never a watch mode. This round's edits are cross-cutting by nature, so a scoped run proves nothing here. If the suite is very large, run it once at the end rather than after each removal.
7. Fix what your removals break. If a removal cannot be made to work, revert that one removal, keep the rest, and record why.
8. Commit everything you changed onto the Ralph branch, e.g. `chore: remove per-story scaffolding`.
9. Append one progress record with story id `SCAFFOLD-CLEANUP` using the append command in `Scaffold Cleanup Context`, listing what you removed, what you deliberately kept, and why.
10. Write the cleanup marker file only after the commit succeeds, and do not commit that marker.

## What Counts as Scaffolding

Judge every candidate against one test: **does this only make sense while one story is being built in isolation?** If the answer is yes, and the finished branch no longer needs it, it is scaffolding.

- **Per-story entry points.** Package scripts like `test:us022core`, one-off runner scripts, ad-hoc CLI entry points, Makefile targets, or CI jobs named after a story id. Nobody will ever type them again.
- **Self-verification props.** Demo routes, sandbox pages, seeded fixtures, sample data, or debug panels that exist so a round could look at its own slice, and that nothing in the shipped product reaches.
- **Probes.** Debug logging, timers, counters, `window.__DEBUG`-style globals, commented-out previous implementations, and dead branches left in for comparison.
- **Bridges.** Stubs, shims, mocks, hardcoded returns, or feature flags a story added to stand in for work that had not landed yet — where the real implementation is now on this branch and the bridge is unreachable or merely redundant.
- **Stale markers.** `TODO`/`FIXME`/`HACK` comments pointing at stories this run has now completed.

## What Is Not Scaffolding

These stay. Removing any of them is a defect, not a cleanup.

- **Product code**, including anything an acceptance criterion still rests on. If deleting it would make a criterion no longer observable, it is not scaffolding — full stop.
- **Tests that assert real behavior**, even when their name, path, or command carries a story id. A test is judged by what it asserts, never by what it is called.
- **Fixtures, factories, or helpers those tests need**, and anything the project's normal test entry point depends on.
- **Run bookkeeping**: `prd.json`, story files, `progress/`, the design ledger, and `CLAUDE.md` updates the rounds wrote.
- **Anything that predates this run**, per step 2.
- **Anything you are unsure about.** This round has no mandate to guess. Keep it, and say so in the progress record — an unremoved prop costs a line of clutter, a wrongly removed one costs a working feature.

## Renaming Over Deleting

The common case is not a pure prop but a real test wearing a scaffold's name: `test:us022core` runs assertions worth keeping. Deleting the script would silently drop those assertions from every future run, which is strictly worse than leaving the script alone.

So: fold the test file into the project's normal test layout and naming, make sure the project's ordinary test command picks it up, verify that by running that ordinary command, and only then remove the per-story script. If you cannot get it adopted by the normal entry point in this round, leave the script in place and record what stands in the way. **Never remove a runner without first confirming that what it ran still runs.**

## Completion Requirements

Before finishing successfully:

1. The project's whole test suite passes on the Ralph branch.
2. Every story in the run PRD is still `passes: true`, and you changed no `passes` value, no acceptance criterion, and no `Covers:` clause. This round edits code, never the backlog. If a removal would require weakening a criterion, that removal is wrong.
3. `git status --short` in the worktree shows no uncommitted round output.
4. The `SCAFFOLD-CLEANUP` progress record is committed.
5. Write the cleanup marker file specified in the run context, containing exactly these lines:

```text
status=done
run_id=<run id>
```

6. The marker is runtime control state: write it last, and leave it uncommitted.

## When There Is Nothing To Remove

A run whose stories left no propping is a normal outcome, not a failure. Say so in the progress record, note what you checked, write the marker, and finish. Do not invent cleanup to justify the round, and do not refactor working code because you are here anyway.

## Background Processes

When verification requires a long-running server or watcher, such as `npm run dev`, `vite`, `next dev`, or a file watcher, do not run it in the foreground. Start it with full file descriptor redirection, capture its PID, and stop it before finishing:

```bash
setsid nohup <cmd> > /tmp/ralph-server.log 2>&1 < /dev/null &
SERVER_PID=$!
echo "Started background server PID: $SERVER_PID"
```

Before exit, stop the process group first and fall back to the PID:

```bash
kill -TERM "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || true
```

If `setsid` is unavailable, use `nohup <cmd> > /tmp/ralph-server.log 2>&1 < /dev/null &`, capture `$!`, and still kill that PID before exit. Never leave a `npm run dev`, `vite`, `next dev`, watcher, or local server running when you finish.

## If You Cannot Finish

- Do not write the cleanup marker.
- Do not emit `<promise>COMPLETE</promise>`.
- Commit whatever safe, coherent removals you did complete, so the next attempt starts from them.
- Explain the blocker briefly and stop normally so the outer loop can continue.
