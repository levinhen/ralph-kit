## Knowing the Codebase

When you need to understand how an area currently works (data model, renderer, workbench panel, etc.), check `docs/design-ledger/<area>.md` first. The ledger is the current truth. `ralph/tasks/` holds only PRDs that are still in play; a completed run's PRD is archived with its run dir under `ralph/archive/<date>-<run_id>/prd-<run_id>.md` and carries `status: merged` frontmatter. Both archived PRDs and archived runs are historical and may conflict with the ledger — trust the ledger, and do not mine the archive for design intent.
