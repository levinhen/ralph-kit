<!-- ralph-kit:begin -->
## Ralph (autonomous agent loop)

This project ships the Ralph multi-agent loop under `ralph/` and two companion Claude Code skills under `.claude/skills/`.

Directory layout:

- `ralph/scripts/` — static loop code: `ralph.sh`, `orchestrate.sh`, `create-run.sh`, `append-progress-json.sh`, `lib/`, and the agent prompt files (`CLAUDE.md`, `CODEX.md`, `MERGE_BACK.md`, `CONSOLIDATE.md`).
- `ralph/runs/<run_id>/` — active runs (PRD, per-story state, progress logs).
- `ralph/archive/<date>-<run_id>/` — completed runs after consolidation.
- `ralph/locks/` — runtime lock dirs (transient).

Common entry points:

- `ralph/scripts/ralph.sh --run <run_id>` — start an autonomous Ralph loop on a run-scoped PRD.
- `ralph/scripts/create-run.sh <run_id> path/to/prd.json` — initialize a run directory from an existing `prd.json`.
- `ralph/scripts/CLAUDE.md` — agent instructions consumed when `--tool claude` is used.
- `ralph/scripts/CODEX.md` — agent instructions consumed when `--tool codex` is used.
- `.claude/skills/prd/` — `/prd` skill: generate a PRD from a feature description.
- `.claude/skills/ralph/` — `/ralph` skill: convert an existing PRD to Ralph's run-scoped `prd.json`.

Do not edit `ralph/runs/<run_id>/progress/*.jsonl` or `progress/shared-memory.json` by hand — use `ralph/scripts/append-progress-json.sh`.

See `ralph/scripts/CLAUDE.md` (or `CODEX.md`) for full per-iteration agent behavior.
<!-- ralph-kit:end -->
