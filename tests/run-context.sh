#!/bin/bash

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-run-context-test.XXXXXX")
REPO_ROOT_EXPECTED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_ROOT_EXPECTED="$REPO_ROOT_EXPECTED/template/ralph/scripts"
RALPH_ROOT_EXPECTED="$REPO_ROOT_EXPECTED/template/ralph"
MODULE="$SCRIPT_ROOT_EXPECTED/lib/run-context.sh"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

# Poison every familiar caller variable and source from an unrelated cwd. The
# module must derive its roots from its own BASH_SOURCE rather than source order
# or whatever happened to be in the parent script.
cd "$TEST_ROOT"
SCRIPT_DIR="/caller/scripts"
LIB_DIR="/caller/lib"
PROMPT_ROOT="/caller/prompts"
RALPH_ROOT="/caller/ralph"
REPO_ROOT="/caller/repo"
RUNS_ROOT="/caller/runs"
STATUS_ROOT="/caller/status"
WORKTREE_ROOT="/caller/worktrees"
LOCK_ROOT="/caller/locks"

source "$MODULE"

assert_eq "$SCRIPT_ROOT_EXPECTED" "$SCRIPT_DIR" "script root"
assert_eq "$SCRIPT_ROOT_EXPECTED/lib" "$LIB_DIR" "library root"
assert_eq "$SCRIPT_ROOT_EXPECTED" "$PROMPT_ROOT" "prompt root"
assert_eq "$RALPH_ROOT_EXPECTED" "$RALPH_ROOT" "Ralph root"
assert_eq "$REPO_ROOT_EXPECTED/template" "$REPO_ROOT" "repository root"
assert_eq "$RALPH_ROOT_EXPECTED/runs" "$RUNS_ROOT" "runs root"
assert_eq "$RALPH_ROOT_EXPECTED/status" "$STATUS_ROOT" "status root"
assert_eq "$REPO_ROOT_EXPECTED/template/.worktrees" "$WORKTREE_ROOT" "worktree root"
assert_eq "$RALPH_ROOT_EXPECTED/locks" "$LOCK_ROOT" "lock root"

assert_eq "$SCRIPT_ROOT_EXPECTED/CLAUDE.md" "$CLAUDE_PROMPT_FILE" "Claude prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/CODEX.md" "$CODEX_PROMPT_FILE" "Codex prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/PI.md" "$PI_PROMPT_FILE" "pi prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/MERGE_BACK.md" "$MERGE_BACK_PROMPT_FILE" "merge prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/CLEANUP_SCAFFOLD.md" "$CLEANUP_SCAFFOLD_PROMPT_FILE_TEMPLATE" "cleanup prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/CONSOLIDATE.md" "$CONSOLIDATE_PROMPT_FILE_TEMPLATE" "consolidation prompt"
assert_eq "$SCRIPT_ROOT_EXPECTED/UNBLOCK_STORY.md" "$UNBLOCK_STORY_PROMPT_FILE_TEMPLATE" "unblock prompt"

# Direct sourcing starts in the base checkout's legacy layout.
assert_eq "legacy" "$RUN_MODE" "default run mode"
assert_eq "legacy" "$RUN_ID_LABEL" "legacy label"
assert_eq "$RALPH_ROOT_EXPECTED/prd.json" "$ROOT_PRD_FILE" "legacy root PRD"
assert_eq "$RALPH_ROOT_EXPECTED/progress.txt" "$ROOT_PROGRESS_FILE" "legacy root progress"
assert_eq "$RALPH_ROOT_EXPECTED/progress" "$ROOT_PROGRESS_DIR" "legacy root progress dir"
assert_eq "$RALPH_ROOT_EXPECTED/progress/shared-memory.json" "$ROOT_SHARED_MEMORY_FILE" "legacy root memory"
assert_eq "$RALPH_ROOT_EXPECTED/stories" "$ROOT_STORIES_DIR" "legacy root stories"
assert_eq "$RALPH_ROOT_EXPECTED/state.json" "$ROOT_STATE_FILE" "legacy root state"
assert_eq "$RALPH_ROOT_EXPECTED/.merge-back-done" "$MERGE_BACK_STATE_FILE" "legacy merge marker"
assert_eq "$RALPH_ROOT_EXPECTED/.scaffold-cleanup-done" "$SCAFFOLD_CLEANUP_STATE_FILE" "legacy cleanup marker"
assert_eq "" "$CONSOLIDATION_STATE_FILE" "legacy consolidation marker"

# Scoped root-side control state and active-worktree story state are configured
# separately. This is the split ralph.sh needs throughout merge-back.
RUN_ID="run.one"
ralph_context_set_root_paths "scoped" "$RUN_ID"
assert_eq "scoped" "$RUN_MODE" "scoped run mode"
assert_eq "$RUN_ID" "$RUN_ID_LABEL" "scoped run label"
assert_eq "$RUNS_ROOT/$RUN_ID" "$RUN_DIR" "scoped run dir"
assert_eq "$RUNS_ROOT/$RUN_ID/prd.json" "$ROOT_PRD_FILE" "scoped root PRD"
assert_eq "$RUNS_ROOT/$RUN_ID/progress" "$ROOT_PROGRESS_DIR" "scoped root progress dir"
assert_eq "$RUNS_ROOT/$RUN_ID/stories" "$ROOT_STORIES_DIR" "scoped root stories"
assert_eq "$RUNS_ROOT/$RUN_ID/state.json" "$ROOT_STATE_FILE" "scoped root state"
assert_eq "$RUNS_ROOT/$RUN_ID/.merge-back-done" "$MERGE_BACK_STATE_FILE" "scoped merge marker"
assert_eq "$RALPH_ROOT_EXPECTED/.consolidation-done-$RUN_ID" "$CONSOLIDATION_STATE_FILE" "scoped consolidation marker"
assert_eq "ralph/.consolidation-done-$RUN_ID" "$CONSOLIDATION_STATE_REL_PATH" "relative consolidation marker"
assert_eq "$LOCK_ROOT/run-$RUN_ID.lock" "$RUN_LOCK_DIR" "scoped lock path"

ACTIVE_FIXTURE="$TEST_ROOT/active-worktree"
mkdir -p "$ACTIVE_FIXTURE"
ralph_context_set_active_paths "$ACTIVE_FIXTURE" "scoped" "$RUN_ID"
assert_eq "$ACTIVE_FIXTURE" "$ACTIVE_WORKTREE" "active worktree"
assert_eq "$ACTIVE_FIXTURE/ralph" "$ACTIVE_RALPH_ROOT" "active Ralph root"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID" "$ACTIVE_RUN_DIR" "active run dir"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID/prd.json" "$PRD_FILE" "active scoped PRD"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID/progress.txt" "$PROGRESS_FILE" "active scoped progress"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID/progress" "$PROGRESS_DIR" "active scoped progress dir"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID/stories" "$STORIES_DIR" "active scoped stories"
assert_eq "ralph/runs/$RUN_ID/prd.json" "$PRD_REL_PATH" "relative scoped PRD"
assert_eq "ralph/runs/$RUN_ID/progress" "$PROGRESS_REL_DIR" "relative scoped progress dir"
assert_eq "ralph/runs/$RUN_ID/stories" "$STORIES_REL_DIR" "relative scoped stories"

# Library re-sourcing must not silently reset a scoped context to the module's
# default legacy context.
source "$MODULE"
assert_eq "scoped" "$RUN_MODE" "idempotent source run mode"
assert_eq "$RUNS_ROOT/$RUN_ID/prd.json" "$ROOT_PRD_FILE" "idempotent source root PRD"
assert_eq "$ACTIVE_FIXTURE/ralph/runs/$RUN_ID/prd.json" "$PRD_FILE" "idempotent source active PRD"

assert_eq "$WORKTREE_ROOT/$RUN_ID" \
  "$(ralph_context_worktree_path scoped "$RUN_ID" 'ignored/branch')" \
  "scoped worktree path"
assert_eq "ralph-feature-one-two" \
  "$(sanitize_branch_name 'refs/heads/ralph/feature:one\two')" \
  "sanitized branch"
assert_eq "$WORKTREE_ROOT/ralph-feature-one-two" \
  "$(ralph_context_worktree_path legacy "" 'refs/heads/ralph/feature:one\two')" \
  "legacy worktree path"

for valid_id in "run-1" "run.one" "run_one" "US-001"; do
  ralph_run_id_is_valid "$valid_id" || fail "Rejected valid run ID: $valid_id"
  ralph_story_id_is_valid "$valid_id" || fail "Rejected valid story ID: $valid_id"
done

for invalid_id in "" "." ".." "run/one" "run one" "run:one"; do
  if ralph_run_id_is_valid "$invalid_id"; then
    fail "Accepted invalid run ID: $invalid_id"
  fi
  if ralph_story_id_is_valid "$invalid_id"; then
    fail "Accepted invalid story ID: $invalid_id"
  fi
done

if RUN_ERROR=$( (validate_run_id 'bad/run') 2>&1); then
  fail "validate_run_id accepted a path-like ID"
fi
assert_eq "Error: Invalid run id 'bad/run'. Use only letters, numbers, dot, underscore, and dash; '.' and '..' are not allowed." \
  "$RUN_ERROR" "run ID error"

if STORY_ERROR=$( (validate_story_id_for_file 'bad/story') 2>&1); then
  fail "validate_story_id_for_file accepted a path-like ID"
fi
assert_eq "Error: Story id 'bad/story' cannot be used as a Ralph story filename." \
  "$STORY_ERROR" "story ID error"

# Switching back clears every scoped-only path instead of leaking state into a
# later legacy operation in the same shell.
ralph_context_set_root_paths "legacy" ""
ralph_context_set_active_paths "$ACTIVE_FIXTURE" "legacy" ""
assert_eq "legacy" "$RUN_MODE" "reset legacy mode"
assert_eq "" "$RUN_DIR" "reset scoped run dir"
assert_eq "" "$ACTIVE_RUN_DIR" "reset active run dir"
assert_eq "" "$RUN_LOCK_DIR" "reset scoped lock"
assert_eq "" "$CONSOLIDATION_STATE_FILE" "reset consolidation marker"
assert_eq "$ACTIVE_FIXTURE/ralph/prd.json" "$PRD_FILE" "active legacy PRD"
assert_eq "ralph/prd.json" "$PRD_REL_PATH" "relative legacy PRD"
assert_eq "ralph/progress" "$PROGRESS_REL_DIR" "relative legacy progress dir"
assert_eq "ralph/stories" "$STORIES_REL_DIR" "relative legacy stories"

# Exercise the three small state CLIs from an installed-shaped temporary repo.
# This catches a caller that sources the module but then quietly reconstructs a
# different path of its own.
CLI_REPO="$TEST_ROOT/cli-repo"
mkdir -p "$CLI_REPO"
cp -R "$RALPH_ROOT_EXPECTED" "$CLI_REPO/ralph"

cat > "$CLI_REPO/ralph/prd.json" <<'PRD'
{
  "project": "run context cli fixture",
  "branchName": "ralph/run-context-cli",
  "userNeed": "State helpers agree on one run layout.",
  "userStories": [
    {
      "id": "US-001",
      "title": "Share the scoped layout",
      "description": "Covers: create, append, and sync helpers.",
      "acceptanceCriteria": ["Every helper writes under the same run directory."],
      "dependsOn": [],
      "passes": false,
      "notes": ""
    }
  ]
}
PRD

git -C "$CLI_REPO" init -q
git -C "$CLI_REPO" config user.name "Ralph Test"
git -C "$CLI_REPO" config user.email "ralph-test@example.com"
git -C "$CLI_REPO" add .
git -C "$CLI_REPO" commit -qm "run context cli fixture"
git -C "$CLI_REPO" branch -M main

# A run id is used as a directory component with no suffix. Exact dot segments
# must be rejected before any helper can escape runs/<run_id>/ and mutate legacy
# state instead. Exercise both a writer and the lint front door so they cannot
# drift back to their own regexes.
cp "$CLI_REPO/ralph/prd.json" "$TEST_ROOT/escape-source.json"
if bash "$CLI_REPO/ralph/scripts/create-run.sh" --force .. \
  "$TEST_ROOT/escape-source.json" > "$TEST_ROOT/dotdot-create-output" 2>&1; then
  fail "create-run accepted '..' as a run ID"
fi
if bash "$CLI_REPO/ralph/scripts/lint-prd.sh" --run .. \
  > "$TEST_ROOT/dotdot-lint-output" 2>&1; then
  fail "lint-prd accepted '..' as a run ID"
fi
assert_eq "run context cli fixture" \
  "$(jq -r '.project' "$CLI_REPO/ralph/prd.json")" \
  "dot-segment rejection preserved legacy PRD"

CREATE_OUTPUT="$TEST_ROOT/create-run-output"
bash "$CLI_REPO/ralph/scripts/create-run.sh" context-cli \
  "$CLI_REPO/ralph/prd.json" > "$CREATE_OUTPUT"

CLI_RUN_DIR="$CLI_REPO/ralph/runs/context-cli"
[[ -f "$CLI_RUN_DIR/prd.json" ]] || fail "create-run missed the canonical scoped PRD path"
[[ -f "$CLI_RUN_DIR/progress.txt" ]] || fail "create-run missed the canonical scoped progress path"
[[ -f "$CLI_RUN_DIR/progress/shared-memory.json" ]] \
  || fail "create-run missed the canonical scoped memory path"
assert_eq "main" "$(jq -r '.baseBranch' "$CLI_RUN_DIR/state.json")" "created run base branch"
assert_eq "ralph/run-context-cli" "$(jq -r '.targetBranch' "$CLI_RUN_DIR/state.json")" "created run target branch"

cat > "$TEST_ROOT/progress-record.json" <<'RECORD'
{
  "summary": "The state helpers used one scoped context."
}
RECORD

bash "$CLI_REPO/ralph/scripts/append-progress-json.sh" \
  --run context-cli \
  --story US-001 \
  --record "$TEST_ROOT/progress-record.json" \
  --shared-memory "Scoped paths come from run-context.sh." \
  > "$TEST_ROOT/append-output"

[[ -f "$CLI_RUN_DIR/progress/US-001.jsonl" ]] \
  || fail "append-progress-json missed the canonical scoped story progress path"
assert_eq "The state helpers used one scoped context." \
  "$(jq -r '.summary' "$CLI_RUN_DIR/progress/US-001.jsonl")" \
  "appended scoped progress"
assert_eq "Scoped paths come from run-context.sh." \
  "$(jq -r '.[0]' "$CLI_RUN_DIR/progress/shared-memory.json")" \
  "appended scoped memory"

mkdir -p "$CLI_RUN_DIR/stories"
jq '.userStories[0] | .passes = true' "$CLI_RUN_DIR/prd.json" \
  > "$CLI_RUN_DIR/stories/US-001.json"
bash "$CLI_REPO/ralph/scripts/sync-run-state.sh" --run context-cli \
  > "$TEST_ROOT/sync-output"
assert_eq "true" "$(jq -r '.userStories[0].passes' "$CLI_RUN_DIR/prd.json")" \
  "synced scoped story state"

# The same helpers must reset cleanly to legacy paths in their own processes.
mkdir -p "$CLI_REPO/ralph/stories"
jq '.userStories[0] | .passes = true' "$CLI_REPO/ralph/prd.json" \
  > "$CLI_REPO/ralph/stories/US-001.json"
bash "$CLI_REPO/ralph/scripts/sync-run-state.sh" --legacy \
  > "$TEST_ROOT/sync-legacy-output"
assert_eq "true" "$(jq -r '.userStories[0].passes' "$CLI_REPO/ralph/prd.json")" \
  "synced legacy story state"

bash "$CLI_REPO/ralph/scripts/append-progress-json.sh" \
  --legacy \
  --story LEGACY-ROUND \
  --record "$TEST_ROOT/progress-record.json" \
  > "$TEST_ROOT/append-legacy-output"
[[ -f "$CLI_REPO/ralph/progress/LEGACY-ROUND.jsonl" ]] \
  || fail "append-progress-json missed the canonical legacy progress path"

echo "run context integration test: ok"
