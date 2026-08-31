# CLAUDE.md

Guidance for agents working in this repository.

## What this repo is

`ralph-kit` is an installer that copies a static template into other projects.
Almost nothing here runs on its own: `template/` is the payload, and
`bin/ralph-kit.mjs` copies it. Edits to `template/` only reach a project after
`ralph-kit sync` runs there.

## Git workflow

Commit and push straight to `main` when a task is done. Do not open a branch or
a pull request for ordinary work.

## Before committing

Run the test suite:

```sh
npm test
```

## Editing rules that are easy to get wrong

- **Skills ship twice.** `template/.claude/skills/<name>/SKILL.md` and
  `template/.agents/skills/<name>/SKILL.md` must stay byte-identical — one copy
  serves Claude Code, the other serves Codex and pi. `ralph-kit doctor` flags a
  drift between them.
- **Agent playbooks come in three.** `CLAUDE.md`, `CODEX.md`, and `PI.md` under
  `template/ralph/scripts/` are per-tool round instructions. A change to how a
  round should behave usually belongs in all three; decide deliberately when it
  does not. CODEX.md and PI.md drive the same model family, so they diverge
  least.
- **Acceptance criteria never name a tool.** `/prd` and `/ralph` write criteria
  into `prd.json`, and an implementation round can only satisfy them with the
  tooling it happens to have. Write the observable outcome
  (`Verified in a browser: <what shows on screen>`), never the helper that
  observes it: a criterion naming a skill or MCP server the round lacks is
  unsatisfiable, so the story either stalls or gets marked passing dishonestly.
  The three playbooks' `Browser Verification` section is what tells a round how
  to pick its own tooling and how to record the gap when it has none.
- **Agent playbooks are read from the root checkout only.** `ralph.sh` resolves
  them from `SCRIPT_DIR` and folds them into a temporary prompt file, so a new
  prompt file needs no worktree copy and no entry in `sync_root_ralph_inputs`.
  Copying them into the worktree is what used to go stale — do not add it back.
- **"Still in flight" is a directory fact both skills bet on.** `/prd` and `/ralph`
  open by sweeping `ralph/tasks/` and `ralph/runs/` and reading whatever is left
  there as written-but-unfinished. That only holds because consolidation moves a
  finished run *and* its source PRD into `ralph/archive/<date>-<run_id>/` — the
  sweep has no other source of truth, so changing what archiving moves, or when,
  silently turns finished work back into "in flight" in both skills and both
  READMEs. What the sweep feeds is one rule: neither skill re-specifies a slice an
  in-flight PRD already owns. It may overturn that design, but the replacement
  lands in the PRD being written now, naming what it supersedes — and where the old
  design is already code on a part-run branch, changing that code is carried as
  real stories rather than assumed away. `/ralph` reads the same sweep for a second
  thing: an in-flight run is the only place a `dependsOnRuns` edge can be
  discovered, since the lint rejects an entry naming a run that does not exist but
  cannot notice one that was never written.
- **The dependency fields have seven consumers.** `dependsOn` (story-level) and
  `dependsOnRuns` (run-level) are documented in the ralph skill, enforced by
  `lint-prd.sh`, gated at `ralph.sh` startup, scheduled from by
  `orchestrate.sh` graph mode, described in both READMEs, rewritten by an
  unblock round that restructures a blocked story, and — for `dependsOn` —
  mirrored edge for edge in a run's `deps-audit.json` when it has one. A
  semantic change to either field must visit all seven, or the lint will accept
  what the scheduler misreads (or vice versa).
- **The dependency audit is advice, and nothing may turn it back into a gate.**
  `/ralph` may hand the finished split to a separate agent running
  `DEPENDENCY_AUDIT.md`, which re-derives the edges and the `Covers:` coverage
  from the source PRD alone; the resolved result lands in
  `ralph/runs/<run_id>/deps-audit.json`. That file is optional. `lint-prd.sh`
  reports a missing or stale one through `report_deps_audit`, which prints
  `WARN:` and leaves `ERROR_COUNT` alone, so neither `ralph.sh` nor
  `create-run.sh` refuses to start over it — only `RALPH_REQUIRE_DEPS_AUDIT=1`
  restores the old error. Adding a new blocking check here re-breaks the thing
  this repo is: a decision aid, not a compliance regime.
  What stays absolute is that the audit is not self-servable: the splitting
  agent is anchored on its own shape and re-reading it produces agreement, not
  an audit. So the choice is always audit-by-another-agent or no audit — never
  a `deps-audit.json` written by the agent that wrote the split. The same rule
  binds the unblock round: restructuring a blocked story invalidates an existing
  audit, so that round re-runs `DEPENDENCY_AUDIT.md` through a fresh isolated
  agent or deletes the stale file. Keep the skill's `deps-audit.json` schema and
  the lint's checks in sync — the skill is the only place an agent learns the
  shape the lint compares against.
- **Status-line colour lives in `lib/log.sh`, and never in a log file.** The
  loop's own status lines print through `ralph_log_line` / `ralph_log_banner`
  (stdout) and `ralph_log_line_err` (stderr), which emit SGR codes only when
  that stream is an interactive terminal and `NO_COLOR` is unset. Never write an
  escape sequence into an `echo` directly: `orchestrate.sh` redirects each
  parallel run to a log file and the tests capture stdout, and both must keep
  reading as plain text. The hues are semantic, not decorative — cyan story
  round, yellow unblock round, magenta merge-back, blue consolidation, green
  finished, red stopping — and the unblock yellow is deliberately the same
  warning colour `lib/progress-bar.sh` paints the pinned row with for that
  phase. Changing one without the other makes the row and the banner disagree
  about whether the run is on the happy path. Both READMEs document the table.

- **Run status is written unconditionally; the pinned row is not.** A run's
  state reaches two places: `lib/progress-bar.sh` pins it to an interactive
  terminal, and `lib/run-status.sh` writes it to
  `ralph/status/<run_id>.json`. Only the first is allowed to give up when the
  streams are not a tty — `orchestrate.sh` redirects every parallel run to a log
  file, so a status file gated on a tty would be empty in exactly the case it
  exists for. `ralph_status_update` is the single front door: it drives both,
  and nothing should call `ralph_progress_update` directly again. The file stays
  out of `ralph/runs/` deliberately — consolidation moves that directory into
  `ralph/archive/` and stages it with `git add -A`, and runtime state has no
  business in a commit.
  `orchestrate.sh` reads those files into a status board pinned to its own
  terminal (`lib/status-board.sh`). Like the log colours and the progress row,
  it writes SGR and cursor codes to `/dev/tty` only: the tests capture the
  orchestrator's stdout and every parallel run's output is a log file, and both
  must stay byte-identical plain text. `tests/run-status.sh` asserts that, and
  asserts the status file is current *mid-run* rather than only at exit.
- **The unblock round's verdict is a fourth thing the status file carries.**
  `unblockRounds` counts the phase transition into `unblocking`; the outcome is
  stamped by `ralph_status_unblock_outcome` at each of the three exits in
  `ralph.sh` — `finished`, `restructured`, `stopped`. The board keeps that
  marker on a finished run's row, because a run whose output went to a file has
  no other cheap way to say it left the happy path. Adding a fourth exit to the
  failure path means stamping it there too, or the row silently reports the
  previous verdict.
- **The failure path is described in four places.** Story failure runs exactly
  one round (`UNBLOCK_STORY.md`), which decides whether the story is genuinely
  blocked or was merely unfinished: unfinished means it gets completed there,
  blocked means the run PRD is restructured around it and the loop continues on
  the new split, and neither means Ralph stops. The three playbooks'
  `Stop Condition` sections and both READMEs state this sequence; changing the
  flow in `ralph.sh` without updating those texts leaves agents being promised a
  flow that no longer runs.
- **A blocked story is a decomposition defect, not a harder story.** The unblock
  round may only restructure when it can name something the criteria require
  that the story itself is not the one to create — a later observation point, a
  missing observable outlet, later verification setup, or a missing `dependsOn`
  edge. It may never weaken a criterion, drop a `Covers:` slice, or mark
  anything passing. That boundary is the whole thing keeping the round from
  editing failing stories into passing ones, so keep it explicit in
  `UNBLOCK_STORY.md` and do not soften it elsewhere.

## Testing reality

`tests/*.sh` are integration tests driving `ralph.sh` against a fixture repo
with a stubbed agent CLI. They all exercise **legacy mode** (state at
`ralph/prd.json`, no run directories). No test covers the run-scoped worktree
path, so bugs in worktree syncing do not get caught — verify those by hand.

Nothing that needs a real terminal is covered either: the pinned progress row
and the orchestrator's status board only render when stdout is a tty, which no
test has. `tests/run-status.sh` covers the half that survives redirection — the
status files, and the fact that no escape sequence leaks into them. Verify the
rendering itself by hand, or under a pty.
