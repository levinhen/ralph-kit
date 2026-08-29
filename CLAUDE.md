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

## Testing reality

`tests/*.sh` are integration tests driving `ralph.sh` against a fixture repo
with a stubbed agent CLI. They all exercise **legacy mode** (state at
`ralph/prd.json`, no run directories). No test covers the run-scoped worktree
path, so bugs in worktree syncing do not get caught — verify those by hand.
