# Merge-Back Conflict Resolution Round

This run is the dedicated final merge-back round for Ralph.

All user stories in the Ralph branch are already complete. Do not pick another user story. Do not implement a new feature. Your only goal is to finish the Git merge-back from the completed Ralph branch into the base branch workspace, starting the merge if the automatic attempt was blocked by local base changes.

## Required Behavior

1. Stay on the base branch workspace provided in the run context.
2. Check `git status` and whether `MERGE_HEAD` exists.
3. If Git is already in a merge state, resolve merge conflicts deliberately using the conflicted files and the completed Ralph branch as context.
4. If Git is not yet in a merge state because local base worktree changes blocked the automatic merge start, preserve those local changes and start `git merge --no-ff --no-commit <target branch>` yourself. Do not discard, reset, or permanently stash local content. If a temporary stash is absolutely necessary, re-apply it before completion so it is not left as the only copy of any work.
5. Do not abort the merge, rebase, cherry-pick, squash, or manually port the full branch as a separate single-parent commit.
6. Include the completed Ralph state files that should live on the base branch, especially the PRD and progress paths supplied in `Ralph Run Context`.
7. Do not stage unrelated pre-existing base worktree files unless they are intentionally part of the Ralph merge-back. Keep unrelated local files visible in the worktree and mention them if they remain after the merge commit.
8. Run the appropriate quality checks for the files you changed.
9. Stage resolved files and complete the merge with `git commit`, preserving the active merge parents.
10. Write the merge completion marker only after the merge commit succeeds, and do not include that marker file in the commit.

## Completion Requirements

Before finishing successfully:

1. Append a `MERGE-BACK` entry to the base branch progress path supplied in the merge-back context.
2. Write the merge completion marker file specified in the run context.
3. The marker file must contain exactly these lines:

```text
status=done
base_branch=<base branch name>
target_branch=<ralph branch name>
```

4. Only after the marker file is written may you treat this round as complete.

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

- Do not write the merge completion marker.
- Do not emit `<promise>COMPLETE</promise>`.
- Explain the blocker briefly and stop normally so the outer loop can continue.
