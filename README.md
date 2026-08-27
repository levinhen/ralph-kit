# ralph-kit

English | [简体中文](./README.zh-CN.md)

One-command installer for the [Ralph](https://github.com/snarktank/ralph) autonomous-agent loop, packaged with companion `/prd` and `/ralph` skills for both Claude Code (`.claude/skills/`) and Codex/pi (`.agents/skills/`), plus `AGENTS.md` integration.

The whole idea in one paragraph: **you describe a feature in chat; it becomes a PRD you review; the PRD is split into small, verifiable user stories; a shell loop then spawns one fresh AI agent per story inside an isolated git worktree — each implements, checks, and commits its slice — until every story passes; the branch is merged back into your base branch, the run's design decisions are distilled into a long-lived design ledger, and the run directory is archived together with its PRD.** Files are the memory, git is the checkpoint, and every agent invocation starts from a clean context window.

Drops the following into any project:

```
.claude/skills/prd/SKILL.md   # /prd skill (Claude Code)
.claude/skills/ralph/SKILL.md # /ralph skill (Claude Code)
.agents/skills/prd/SKILL.md   # /prd skill (Codex, pi — same content)
.agents/skills/ralph/SKILL.md # /ralph skill (Codex, pi — same content)
ralph/
  scripts/                    # static loop code (ralph.sh, orchestrate.sh, lib/, agent prompts)
  tasks/                      # PRD markdown for runs still in play (created on first use; never touched)
  runs/                       # active runs (created at runtime, not shipped)
  archive/                    # completed-and-consolidated runs + their source PRDs (created at runtime)
  locks/                      # runtime lock dirs (created at runtime)
AGENTS.md                     # (created or annotated; existing content preserved)
```

Everything Ralph generates lives under `ralph/` — its code, runtime state, and archives are kept together and out of `scripts/`.

**Requirements:** Bash (macOS, Linux, or Git Bash on Windows), `git`, `jq`, Node.js 18+, and at least one agent CLI on `PATH` — `claude` (Claude Code), `codex`, or `pi` ([pi-coding-agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)).

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
        │    3. spawn a fresh claude / codex / pi process
        │    4. agent: implement → checks → passes=true → commit
        │    5. sync story state back into prd.json
        │       passes!=true → read-only diagnosis round → terminal → stop
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
archive              ralph/runs/<id> + ralph/tasks/prd-<id>.md
                     → ralph/archive/<date>-<id>
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
ralph/scripts/ralph.sh --run <run_id> --tool claude 20   # or --tool codex (default) / --tool pi
```

**Startup (once):**

1. Pick the run (`--run`, or an interactive selector listing incomplete runs) and take a lock dir `ralph/locks/run-<run_id>.lock` so the same run can't start twice.
2. Read `state.json`; backfill `baseBranch`/`baseSha` from the current checkout if missing.
3. Create (or reuse) a git worktree at `.worktrees/<run_id>` checked out on `branchName` (e.g. `ralph/<feature>`), branched from the base branch, and copy the run's inputs into it if they aren't there yet. The whole run happens inside the worktree — your main checkout stays untouched.
4. Split `prd.json` into per-story files `stories/US-xxx.json`, copying the root `userNeed` into each.

**Each iteration:**

1. Sync `stories/*.json` back into `prd.json`, then pick the **first story with `passes != true`**.
2. Assemble a one-shot prompt from:
   - the agent playbook — `scripts/CLAUDE.md` (for `--tool claude`), `scripts/CODEX.md` (for `--tool codex`), or `scripts/PI.md` (for `--tool pi`),
   - run context (branches, worktree, file paths),
   - the **current story JSON only** (the agent is told not to read the full PRD),
   - a **memory slice**: the last ~40 shared-memory items plus the last ~5 progress records of this story.
3. Spawn a **fresh agent process** in the worktree (`claude --print …`, `codex exec …`, or `pi --print --mode json …`, permission prompts bypassed — the loop is built for unattended runs). No chat history, no previous-iteration context.
4. The agent, per its playbook: implements **exactly that one story** (only the slice named in `Covers:`), runs the project's quality checks (typecheck/lint/tests), flips the story file to `passes: true` and writes `notes`, appends a structured progress record via `append-progress-json.sh` (one JSON line into `progress/<story_id>.jsonl`, plus optional `--shared-memory` items for reusable patterns), and commits everything as `feat: [US-xxx] - [Title]`.
   Every agent round also receives a shared **Round Commit Contract**: all intended repository artifacts produced by that round must be committed before it ends, rather than being left for a later story, finalization, merge-back, or consolidation round. A safe, coherent partial result is committed as a checkpoint while the story remains incomplete. Runtime markers, temporary diagnostics, and artifact-free idempotent retries do not require empty commits.
5. The loop syncs story state back into `prd.json` (amending it into the story commit when safe) and **trusts only the file**. If the current story now has `passes: true`, Ralph advances normally. If it still has `passes != true`—regardless of what the agent claimed—Ralph does not retry the implementation round.
6. An incomplete story triggers exactly one dedicated **failure diagnosis round** (`DIAGNOSE_FAILURE.md`). It receives the story, recent progress, Git heads, the previous agent message, and raw tool events when available. The diagnosis runs with read-only agent permissions, prints a structured root-cause report to the terminal, and exits `1`; every later normal iteration is skipped. This special round is outside `max_iterations`.
7. Successful story rounds repeat until all stories pass or `max_iterations` (default 10) is reached.

Interactive terminals keep a progress bar pinned to the bottom row while agent logs scroll above it:

```
Ralph:20260817-a [█████░░░░░░░░░░░] 3/8 done | US-004 | working 4m12s | iter 7/30 | total 1h06m | eta ~2h45m | ~$4.18 | 3.7M tok | Add token accounting
```

Segments are added in priority order and the row degrades from the right as the terminal narrows, so a 40-column window still shows the bar and the current story. The run id (or branch, in legacy mode) appears from 90 columns up — it is what tells parallel runs apart when several orchestrator windows are open.

Two of the segments only appear when they have something to say:

- **`idle 2m05s/6m00s`** turns the whole row yellow once the agent has been silent for `RALPH_PROGRESS_IDLE_MIN` seconds (default 30), counting up to the idle timeout that will kill the invocation. Without it a long test run and a wedged CLI look identical — the phase clock advances the same way in both.
- **`eta ~2h45m`** extrapolates from the stories *this* run completed, so resuming a half-finished run does not divide the elapsed time by someone else's work. Merge-back and consolidation rounds are not stories, so it drifts near the end of a run; hence the tilde.

A background ticker redraws it every `RALPH_PROGRESS_TICK_SECONDS` (default 2) so the clocks keep moving while an agent is silent, and it restores the terminal on its own if Ralph is killed outright. It disables itself when output is redirected (including parallel orchestrator logs) — control codes only ever go to `/dev/tty`, never into a log; set `RALPH_PROGRESS=0` to turn it off explicitly.

### Token and cost accounting

Ralph normalises the usage each agent CLI reports and sums it across the run. Both the running total in the status row and the closing bill on stdout come from the same ledger, so it is also there for non-interactive runs where the pinned row is off:

```
Ralph usage for this run:
  Tool calls:    12
  Model:         gpt-5.6-sol
  Input:         412000 (new) + 3140000 (cache read) + 88000 (cache write)
  Output:        61000
  Total tokens:  3701000
  Cost:          ~$4.18 (estimated at 5/0.5/6.25/30 USD per 1M in/cached/write/out)
```

Where the money comes from depends on the tool, and the row marks the difference — `$4.18` is a bill, `~$4.18` is an estimate:

- **claude** reports `total_cost_usd` itself, so Ralph uses the CLI's own number and never prices it. On a subscription plan that figure is API-equivalent pricing, not what you are actually charged.
- **codex** reports tokens but no cost, so Ralph prices it from a rate table. The defaults are the gpt-5.6-sol standard tier ($5 input, $0.50 cached input, $6.25 cache writes, $30 output per 1M tokens); override them if you run a different model. Prompts over 272K input tokens bill at a higher long-context tier that the event stream does not expose per request, so a run that lives there is under-counted unless you raise the rates.
- **pi** prices each message from its own model catalogue and reports the result, so Ralph uses that number and the real model name — whichever provider/model pi is configured for. The `RALPH_PRICE_*` rates are ignored for pi runs.

Guard rails: a per-invocation idle timeout (default 360 s of silence) and optional hard timeout; a dedicated exit code (75) that aborts the whole loop on provider rate limits; and a post-invocation process-tree sweep that reaps leftover dev servers/watchers (including Windows Git Bash handling). Codex runs with `--json` and pi with `--mode json`, both keeping their normal session: Ralph parses JSONL directly from a pipe, keeps only the latest 100 events in an in-memory ring, and writes those raw events to a temporary diagnostic file only when the invocation fails. The final diagnosis round can inspect that file but cannot modify the repository (`codex --sandbox read-only`; Claude plan permission mode).

The diagnosis round is weaker on pi, and deliberately so: pi ships no sandbox, so Ralph bounds that round with what it can actually control — `--exclude-tools edit,write` removes the file-writing tools, and `--no-approve` keeps project-local pi extensions from loading. `bash` stays available because the round has to read Git state, so the no-writes rule there rests on `DIAGNOSE_FAILURE.md` rather than on an enforced boundary. Implementation rounds run `pi --approve`, which does trust project-local `.pi/` settings, extensions, and skills.

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
4. Write the consolidation marker; `ralph.sh` then mechanically moves both `ralph/runs/<run_id>/` and the source PRD `ralph/tasks/prd-<run_id>.md` into `ralph/archive/<date>-<run_id>/`, and commits that move as a separate archive commit. `ralph/tasks/` is left holding only PRDs still in play, while a finished run and its PRD sit in one archive directory.

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
| `--tool claude\|codex\|pi` / `RALPH_TOOL` | `codex` | which agent CLI drives iterations |
| `[max_iterations]` | `10` | normal loop budget; the one final failure diagnosis is extra |
| `--legacy` | — | single-run mode at root `ralph/prd.json` (no run dirs) |
| `RALPH_TOOL_IDLE_TIMEOUT_SECONDS` | `360` | kill an agent invocation after this much silence |
| `RALPH_TOOL_TIMEOUT_SECONDS` | `0` (off) | hard cap per invocation |
| `RALPH_SHARED_MEMORY_ITEMS` / `RALPH_STORY_PROGRESS_RECORDS` | `40` / `5` | prompt memory slice sizes |
| `RALPH_PROGRESS` | `1` | pinned story progress in interactive terminals; set to `0` to disable |
| `RALPH_PROGRESS_IDLE_MIN` | `30` | seconds of agent silence before the idle clock appears |
| `RALPH_PRICE_INPUT_USD` / `RALPH_PRICE_CACHED_INPUT_USD` | `5` / `0.5` | USD per 1M tokens, used to estimate codex cost (claude and pi report their own) |
| `RALPH_PRICE_CACHE_WRITE_USD` / `RALPH_PRICE_OUTPUT_USD` | `6.25` / `30` | USD per 1M tokens, used to estimate codex cost (claude and pi report their own) |
| `RALPH_PRICE_MODEL` | `gpt-5.6-sol` | model label shown next to an estimated cost |
| `RALPH_NOTIFY` / `RALPH_NOTIFY_SOUND` | `1` | desktop notifications |
| `RALPH_PLAN` | — | default plan for `orchestrate.sh` |

Exit codes: `0` complete, `1` max iterations reached / story failed after diagnosis, `75` rate-limited, `124` tool timeout.

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

After `init` or `sync`, ralph-kit makes a best-effort Git commit containing only
the files generated or updated by that invocation. Git failures (for example,
when the target is not a repository or no author identity is configured) are
silently ignored and never make the command fail.

## Safety guarantees

`init` and `sync` **never** touch:

- `ralph/tasks/` — PRD markdown authored by the `/prd` skill
- `ralph/runs/` — in-progress Ralph runs
- `ralph/archive/` — completed/consolidated runs and their source PRDs
- `ralph/locks/` — runtime lock directories
- `ralph/progress/`, `ralph/stories/`, `ralph/prd.json`, `ralph/progress.txt`, `ralph/state.json`, `ralph/.last-branch`, `ralph/.merge-back-done` — legacy-mode runtime files
- An existing `AGENTS.md` — the snippet is printed for you to paste

For every other file:

- **Target missing** → write.
- **Target identical to template** → skip (idempotent).
- **Target differs from template** → `init` skips and warns. `sync` replaces it with the kit version.

Run `ralph-kit doctor` any time to see drift.

## Attribution

The core Ralph loop (`ralph/scripts/`) is derived from [snarktank/ralph](https://github.com/snarktank/ralph) (MIT, originally laid out under `scripts/ralph/`). This kit adds:

- Multi-agent support (`CLAUDE.md` + `CODEX.md` + `PI.md` per-agent prompts).
- Run-scoped layout (`runs/<run_id>/`) with consolidation + merge-back rounds.
- Companion `/prd` and `/ralph` skills for both Claude Code (`.claude/skills/`) and Codex/pi (`.agents/skills/`).
- A CLI installer that keeps copies in sync across multiple projects.

> **Note:** the two skills are shipped to both `.claude/skills/` (Claude Code) and `.agents/skills/` (the repo-level skill directory Codex and pi both read) with byte-identical `SKILL.md` content. Edit both copies together — `ralph-kit doctor` flags either one if it drifts from the kit.

See [`LICENSE`](./LICENSE) for full copyright notices.
