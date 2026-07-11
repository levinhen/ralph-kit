# ralph-kit

English | [简体中文](./README.zh-CN.md)

One-command installer for the [Ralph](https://github.com/snarktank/ralph) autonomous-agent loop, packaged with companion `/prd` and `/ralph` skills for both Claude Code (`.claude/skills/`) and Codex (`.agents/skills/`), plus `AGENTS.md` integration.

The whole idea in one paragraph: **you describe a feature in chat; it becomes a PRD you review; the PRD is split into small, verifiable user stories; a shell loop then spawns one fresh AI agent per story inside an isolated git worktree — each implements, checks, and commits its slice — until every story passes; the branch is merged back into your base branch, the run's design decisions are distilled into a long-lived design ledger, and the run directory is archived.** Files are the memory, git is the checkpoint, and every agent invocation starts from a clean context window.

Drops the following into any project:

```
.claude/skills/prd/SKILL.md   # /prd skill (Claude Code)
.claude/skills/ralph/SKILL.md # /ralph skill (Claude Code)
.agents/skills/prd/SKILL.md   # /prd skill (Codex — same content)
.agents/skills/ralph/SKILL.md # /ralph skill (Codex — same content)
ralph/
  scripts/                    # static loop code (ralph.sh, orchestrate.sh, lib/, agent prompts)
  tasks/                      # PRD markdown authored via /prd (created on first use; never touched)
  runs/                       # active runs (created at runtime, not shipped)
  archive/                    # completed-and-consolidated runs (created at runtime)
  locks/                      # runtime lock dirs (created at runtime)
AGENTS.md                     # (created or annotated; existing content preserved)
```

Everything Ralph generates lives under `ralph/` — its code, runtime state, and archives are kept together and out of `scripts/`.

**Requirements:** Bash (macOS, Linux, or Git Bash on Windows), `git`, `jq`, and at least one agent CLI on `PATH` — `claude` (Claude Code) or `codex`.

## How it works — the full flow

### Pipeline overview

```
/prd skill (chat: clarify → confirm the need in business language)
        │
        ▼
ralph/tasks/prd-<feature>.md          human-readable PRD
        │
        │  /ralph skill (validate the approach → split into
        │  one-context-window stories)
        ▼
ralph/runs/<run_id>/prd.json          machine-readable run
  + state.json + progress/            (stories, userNeed, branchName)
        │
        │  ralph/scripts/ralph.sh --run <run_id>
        ▼
.worktrees/<run_id>  (isolated git worktree on branch ralph/<feature>)
        │
        │  iteration loop — one fresh agent per story:
        │    1. pick the first story with passes=false
        │    2. prompt = agent playbook + story JSON + memory slice
        │    3. spawn a fresh claude / codex process
        │    4. agent: implement → checks → passes=true → commit
        │    5. sync story state back into prd.json
        ▼
all stories passes=true
        │
        ▼
merge-back round     git merge --no-ff into the base branch
                     (conflicts → dedicated agent round)
        │
        ▼
consolidation round  distill learnings → docs/design-ledger/
        │
        ▼
archive              ralph/runs/<id> → ralph/archive/<date>-<id>
```

### Stage 1 — Plan: `/prd` writes a human-readable PRD

In a Claude Code chat, run `/prd` and describe the feature. The skill:

1. asks clarifying questions (lettered options, blocking questions first),
2. keeps following up until the key ambiguities are resolved,
3. restates the need in plain business language and waits for your confirmation,
4. writes `ralph/tasks/prd-<feature>.md` — goals, user stories with verifiable acceptance criteria, functional requirements, non-goals, open questions.

It deliberately does **not** implement anything. The PRD is the human-reviewable contract.

### Stage 2 — Convert: `/ralph` turns the PRD into an executable run

Run `/ralph` on the PRD. This is a thinking step, not a transcription step:

1. **Approach validation** — it recovers the user's actual need from the PRD intro, sanity-checks the solution baked into the PRD, and stops to discuss with you if a clearly better approach exists.
2. **Story splitting** — it re-derives stories from the agreed approach. The number-one rule: **each story must be completable inside one agent context window** ("add a column + migration" is right-sized; "build the whole dashboard" is not). Stories are ordered so dependencies come first (schema → backend → UI), and every acceptance criterion must be mechanically checkable ("typecheck passes", not "works well").
3. **Run scaffolding** — it writes `ralph/runs/<run_id>/`:

```
ralph/runs/<run_id>/
├── prd.json                     # branchName, userNeed, userStories[] (passes:false)
├── progress.txt                 # human-readable progress log
├── progress/shared-memory.json  # [] — cross-story patterns/gotchas
└── state.json                   # runId, baseBranch, baseSha, targetBranch, status
```

Two fields make memoryless execution work:

- **Root-level `userNeed`** — the confirmed business-language statement of what the user actually wants. The loop copies it into every story file at split time, so every agent sees the big picture without reading the full PRD.
- **A `Covers:` clause** at the end of every story description — which slice of `userNeed` this story owns. Read end to end, the clauses must tile the whole need with no gaps and no overlap.

`baseBranch` is whatever branch you had checked out at conversion time — `main` is never assumed.

(Already have a `prd.json`? `ralph/scripts/create-run.sh <run_id> path/to/prd.json` scaffolds the same layout.)

### Stage 3 — Execute: `ralph.sh` loops one fresh agent per story

```sh
ralph/scripts/ralph.sh --run <run_id> --tool claude 20   # or --tool codex (default)
```

**Startup (once):**

1. Pick the run (`--run`, or an interactive selector listing incomplete runs) and take a lock dir `ralph/locks/run-<run_id>.lock` so the same run can't start twice.
2. Read `state.json`; backfill `baseBranch`/`baseSha` from the current checkout if missing.
3. Create (or reuse) a git worktree at `.worktrees/<run_id>` checked out on `branchName` (e.g. `ralph/<feature>`), branched from the base branch, and copy the run's inputs into it if they aren't there yet. The whole run happens inside the worktree — your main checkout stays untouched.
4. Split `prd.json` into per-story files `stories/US-xxx.json`, copying the root `userNeed` into each.

**Each iteration:**

1. Sync `stories/*.json` back into `prd.json`, then pick the **first story with `passes != true`**.
2. Assemble a one-shot prompt from:
   - the agent playbook — `scripts/CLAUDE.md` (for `--tool claude`) or `scripts/CODEX.md` (for `--tool codex`),
   - run context (branches, worktree, file paths),
   - the **current story JSON only** (the agent is told not to read the full PRD),
   - a **memory slice**: the last ~40 shared-memory items plus the last ~5 progress records of this story.
3. Spawn a **fresh agent process** in the worktree (`claude --print …` or `codex exec …`, permission prompts bypassed — the loop is built for unattended runs). No chat history, no previous-iteration context.
4. The agent, per its playbook: implements **exactly that one story** (only the slice named in `Covers:`), runs the project's quality checks (typecheck/lint/tests), flips the story file to `passes: true` and writes `notes`, appends a structured progress record via `append-progress-json.sh` (one JSON line into `progress/<story_id>.jsonl`, plus optional `--shared-memory` items for reusable patterns), and commits everything as `feat: [US-xxx] - [Title]`.
5. The loop syncs story state back into `prd.json` (amending it into the story commit when safe) and **trusts only the file**: an agent claiming `<promise>COMPLETE</promise>` while `passes` is still `false` gets a warning, and the loop continues.
6. Repeat until all stories pass or `max_iterations` (default 10) is reached.

Guard rails: a per-invocation idle timeout (default 360 s of silence) and optional hard timeout; a dedicated exit code (75) that aborts the whole loop on provider rate limits; and a post-invocation process-tree sweep that reaps leftover dev servers/watchers (including Windows Git Bash handling).

### Stage 4 — Merge-back: the branch returns to base

When every story passes and `branchName != baseBranch`:

1. If the worktree still has uncommitted output, a **finalization agent round** commits it first.
2. The loop takes a merge lock and tries the cheap path itself: `git merge --no-ff --no-commit ralph/<feature>` from the base checkout, then commits — a real two-parent merge, so story commits stay visible in history.
3. If the merge conflicts (or the base worktree was dirty), it spawns a **dedicated merge-back agent round** (`MERGE_BACK.md`): resolve conflicts deliberately, never rebase/squash/abort, preserve local changes, complete the merge commit, then write the `.merge-back-done` marker file.

The marker file — not the agent's word — is what the loop trusts.

### Stage 5 — Consolidate & archive: knowledge outlives the run

One more agent round (`CONSOLIDATE.md`) runs on the base branch:

1. Read everything the run produced — `prd.json`, story files, `progress/*.jsonl`.
2. Distill **what the design IS NOW** into `docs/design-ledger/<area>.md` (one file per affected codebase area). The ledger is the authoritative answer to "how does X work today?" — future agents read it instead of mining historical PRDs.
3. Mark the source PRD `ralph/tasks/prd-<run_id>.md` with `status: merged` frontmatter pointing at the ledger files.
4. Write the consolidation marker; `ralph.sh` then mechanically moves `ralph/runs/<run_id>/` → `ralph/archive/<date>-<run_id>/` and commits the move.

The loop exits 0 and sends a desktop notification.

### How memoryless agents share knowledge

Every iteration starts cold, so all memory is files:

| Memory | Scope | Written by | Injected into prompts? |
|---|---|---|---|
| `stories/<id>.json` (`userNeed` + `Covers:`) | one story | `/ralph` + the loop | yes — the whole file |
| `progress/<id>.jsonl` | one story | `append-progress-json.sh` | last ~5 records |
| `progress/shared-memory.json` | one run | `append-progress-json.sh --shared-memory` | last ~40 items |
| `CLAUDE.md` next to source dirs | repo | agents, when they learn something reusable | read by the agent's own tooling |
| `docs/design-ledger/<area>.md` | repo, permanent | consolidation round | read on demand by future runs |

### Running several runs: `orchestrate.sh`

```sh
ralph/scripts/orchestrate.sh --tool claude --plan "1 > 2,3 > 4"
```

Lists incomplete runs, numbers them, and executes a staged plan: `,` = parallel within a stage, `>` = next stage. Parallel runs write to per-run log files; a failed or rate-limited stage stops the orchestrator. Per-run locks plus a per-base-branch merge lock keep parallel runs from stepping on each other.

### Flags & environment

| Flag / env | Default | Meaning |
|---|---|---|
| `--run <run_id>` / `RALPH_RUN_ID` | interactive selector | which run to execute |
| `--tool claude\|codex` / `RALPH_TOOL` | `codex` | which agent CLI drives iterations |
| `[max_iterations]` | `10` | loop budget |
| `--legacy` | — | single-run mode at root `ralph/prd.json` (no run dirs) |
| `RALPH_TOOL_IDLE_TIMEOUT_SECONDS` | `360` | kill an agent invocation after this much silence |
| `RALPH_TOOL_TIMEOUT_SECONDS` | `0` (off) | hard cap per invocation |
| `RALPH_SHARED_MEMORY_ITEMS` / `RALPH_STORY_PROGRESS_RECORDS` | `40` / `5` | prompt memory slice sizes |
| `RALPH_NOTIFY` / `RALPH_NOTIFY_SOUND` | `1` | desktop notifications |
| `RALPH_PLAN` | — | default plan for `orchestrate.sh` |

Exit codes: `0` complete, `1` max iterations reached / failure, `75` rate-limited, `124` tool timeout.

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

- `ralph/tasks/` — PRD markdown authored by the `/prd` skill
- `ralph/runs/` — in-progress Ralph runs
- `ralph/archive/` — completed/consolidated runs
- `ralph/locks/` — runtime lock directories
- `ralph/progress/`, `ralph/stories/`, `ralph/prd.json`, `ralph/progress.txt`, `ralph/state.json`, `ralph/.last-branch`, `ralph/.merge-back-done` — legacy-mode runtime files
- An existing `AGENTS.md` — the snippet is printed for you to paste

For every other file:

- **Target missing** → write.
- **Target identical to template** → skip (idempotent).
- **Target differs from template** → `init` skips and warns. `sync` backs up the existing file as `<file>.ralph-kit.bak` then writes the new version.

Run `ralph-kit doctor` any time to see drift.

## Attribution

The core Ralph loop (`ralph/scripts/`) is derived from [snarktank/ralph](https://github.com/snarktank/ralph) (MIT, originally laid out under `scripts/ralph/`). This kit adds:

- Multi-agent support (`CLAUDE.md` + `CODEX.md` per-agent prompts).
- Run-scoped layout (`runs/<run_id>/`) with consolidation + merge-back rounds.
- Companion `/prd` and `/ralph` skills for both Claude Code (`.claude/skills/`) and Codex (`.agents/skills/`).
- A CLI installer that keeps copies in sync across multiple projects.

> **Note:** the two skills are shipped to both `.claude/skills/` (Claude Code) and `.agents/skills/` (Codex's repo-level skill discovery) with byte-identical `SKILL.md` content. Edit both copies together — `ralph-kit doctor` flags either one if it drifts from the kit.

See [`LICENSE`](./LICENSE) for full copyright notices.
