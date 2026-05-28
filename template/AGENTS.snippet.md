<!-- ralph-kit:begin -->
## Ralph (autonomous agent loop)

This project ships the Ralph multi-agent loop under `scripts/ralph/` and two companion Claude Code skills under `.claude/skills/`.

- `scripts/ralph/ralph.sh --run <run_id>` — start an autonomous Ralph loop on a run-scoped PRD.
- `scripts/ralph/create-run.sh <run_id> path/to/prd.json` — initialize a run directory from an existing `prd.json`.
- `scripts/ralph/CLAUDE.md` — agent instructions consumed when `--tool claude` is used.
- `scripts/ralph/CODEX.md` — agent instructions consumed when `--tool codex` is used.
- `.claude/skills/prd/` — `/prd` skill: generate a PRD from a feature description.
- `.claude/skills/ralph/` — `/ralph` skill: convert an existing PRD to Ralph's run-scoped `prd.json`.

Run state lives under `scripts/ralph/runs/<run_id>/`. Completed runs are archived to `scripts/ralph/runs/_archive/<date>-<run_id>/`. Do not edit `progress/*.jsonl` or `progress/shared-memory.json` by hand — use `scripts/ralph/append-progress-json.sh`.

See `scripts/ralph/CLAUDE.md` (or `CODEX.md`) for full per-iteration agent behavior.
<!-- ralph-kit:end -->
