# ralph-kit

One-command installer for the [Ralph](https://github.com/snarktank/ralph) autonomous-agent loop, packaged with companion Claude Code skills (`/prd`, `/ralph`) and Codex (`AGENTS.md`) integration.

Drops the following into any project:

```
.claude/skills/prd/SKILL.md       # /prd slash command
.claude/skills/ralph/SKILL.md     # /ralph slash command
scripts/ralph/                    # the Ralph loop (ralph.sh, lib/, CLAUDE.md, CODEX.md, ...)
AGENTS.md                         # (created or annotated; existing content preserved)
```

## Install

No `npm publish` required — install straight from GitHub:

```sh
# First-time install in current project:
npx github:levinhen/ralph-kit init

# Pull the latest version into an installed project:
npx github:levinhen/ralph-kit sync

# Diagnose what's installed and whether it's up-to-date:
npx github:levinhen/ralph-kit doctor
```

## Safety guarantees

`init` and `sync` **never** touch:

- `tasks/` — your PRD markdown files
- `scripts/ralph/runs/` — in-progress and archived Ralph runs
- `scripts/ralph/locks/` — runtime lock directories
- `scripts/ralph/progress/` — legacy-mode progress logs
- An existing `AGENTS.md` — the snippet is printed for you to paste

For every other file:

- **Target missing** → write.
- **Target identical to template** → skip (idempotent).
- **Target differs from template** → `init` skips and warns. `sync` backs up the existing file as `<file>.ralph-kit.bak` then writes the new version.

Run `ralph-kit doctor` any time to see drift.

## Attribution

The core Ralph loop (`scripts/ralph/`) is derived from [snarktank/ralph](https://github.com/snarktank/ralph), MIT-licensed. This kit adds:

- Multi-agent support (`CLAUDE.md` + `CODEX.md` per-agent prompts).
- Run-scoped layout (`runs/<run_id>/`) with consolidation + merge-back rounds.
- Companion Claude Code skills (`/prd`, `/ralph`).
- A CLI installer that keeps copies in sync across multiple projects.

See [`LICENSE`](./LICENSE) for full copyright notices.
