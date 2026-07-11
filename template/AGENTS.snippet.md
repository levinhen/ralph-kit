<!-- ralph-kit:begin -->
## Ralph (autonomous agent loop)

This project ships the Ralph multi-agent loop under `ralph/` and two companion skills (`/prd`, `/ralph`) shipped to both `.claude/skills/` (Claude Code) and `.agents/skills/` (Codex). Both copies are byte-identical; Codex discovers repo-level skills under `.agents/skills/`.

Directory layout:

- `ralph/scripts/` — static loop code: `ralph.sh`, `orchestrate.sh`, `create-run.sh`, `append-progress-json.sh`, `lib/`, and the agent prompt files (`CLAUDE.md`, `CODEX.md`, `MERGE_BACK.md`, `CONSOLIDATE.md`).
- `ralph/tasks/` — PRD markdown authored by `/prd` (input to `/ralph` and the consolidation round).
- `ralph/runs/<run_id>/` — active runs (PRD JSON, per-story state, progress logs).
- `ralph/archive/<date>-<run_id>/` — completed runs after consolidation.
- `ralph/locks/` — runtime lock dirs (transient).

Common entry points:

- `ralph/scripts/ralph.sh --run <run_id>` — start an autonomous Ralph loop on a run-scoped PRD.
- `ralph/scripts/create-run.sh <run_id> path/to/prd.json` — initialize a run directory from an existing `prd.json`.
- `ralph/scripts/CLAUDE.md` — agent instructions consumed when `--tool claude` is used.
- `ralph/scripts/CODEX.md` — agent instructions consumed when `--tool codex` is used.
- `/prd` skill — generate a PRD from a feature description (`.claude/skills/prd/` for Claude Code, `.agents/skills/prd/` for Codex).
- `/ralph` skill — convert an existing PRD to Ralph's run-scoped `prd.json` (`.claude/skills/ralph/` for Claude Code, `.agents/skills/ralph/` for Codex).

Do not edit `ralph/runs/<run_id>/progress/*.jsonl` or `progress/shared-memory.json` by hand — use `ralph/scripts/append-progress-json.sh`.

See `ralph/scripts/CLAUDE.md` (or `CODEX.md`) for full per-iteration agent behavior.
<!-- ralph-kit:end -->
