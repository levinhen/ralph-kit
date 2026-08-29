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
- **The dependency fields have seven consumers.** `dependsOn` (story-level) and
  `dependsOnRuns` (run-level) are documented in the ralph skill, enforced by
  `lint-prd.sh`, gated at `ralph.sh` startup, scheduled from by
  `orchestrate.sh` graph mode, described in both READMEs, rewritten by an
  unblock round that restructures a blocked story, and — for `dependsOn` —
  mirrored edge for edge in each run's `deps-audit.json`. A semantic change to
  either field must visit all seven, or the lint will accept what the scheduler
  misreads (or vice versa).
- **`dependsOn` is audited by a second agent, and the lint enforces that.**
  `/ralph` must hand the finished split to a separate agent running
  `DEPENDENCY_AUDIT.md`, which re-derives the edges and the `Covers:` coverage
  from the source PRD alone; the resolved result lands in
  `ralph/runs/<run_id>/deps-audit.json`. `lint-prd.sh` requires that file for a
  run-scoped PRD and compares `storyOrder` and `edges` against `prd.json`, so an
  edge edited afterwards invalidates the audit rather than outliving it. The
  audit is deliberately not self-servable: the splitting agent is anchored on
  its own shape and re-reading it produces agreement, not an audit. The same
  rule binds the unblock round — restructuring a blocked story invalidates the
  audit, so that round must re-run `DEPENDENCY_AUDIT.md` through a fresh
  isolated agent and rewrite `deps-audit.json` before it finishes. Keep the
  skill's `deps-audit.json` schema and the lint's checks in sync — the skill is
  the only place an agent learns the shape the lint demands.
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
