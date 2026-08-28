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
- **`sync_root_ralph_inputs` in `template/ralph/scripts/lib/sync.sh`** copies
  playbooks into the active worktree. A new prompt file must be added there or
  it silently keeps serving a stale copy inside running worktrees.

## Testing reality

`tests/*.sh` are integration tests driving `ralph.sh` against a fixture repo
with a stubbed agent CLI. They all exercise **legacy mode** (state at
`ralph/prd.json`, no run directories). No test covers the run-scoped worktree
path, so bugs in worktree syncing do not get caught — verify those by hand.
