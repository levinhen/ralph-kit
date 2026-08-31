## Scaffolding You Leave Behind

You build one slice while the rest of the run does not exist yet, so some propping is legitimate: a stub for a dependency that lands two stories later, a fixture that lets you see your slice work, a temporary probe. Ralph runs a dedicated **scaffold cleanup round** once every story passes, and that round removes this run's propping before anything merges back. Work with it:

- **Declare what you propped up.** For each piece of scaffolding this round leaves in the tree, add one line to `learnings.context` in the progress record, in the form `scaffold: <what> - <why>`. That list is what the cleanup round works from; anything you leave undeclared it has to rediscover from the diff.
- **Do not clean up after other stories.** You only see your own slice, and a prop that looks dead from here may be the only thing holding up a story that has not run yet.
- **Do not hide real tests behind a per-story command.** A `test:us022core`-style script is a fine shortcut while you work, but the assertions worth keeping belong in the project's normal test layout, reachable by the project's ordinary test command. A test that only ever runs from a story-shaped script is a test that stops running the moment that script goes away.

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
