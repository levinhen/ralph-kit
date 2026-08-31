#!/bin/bash
#
# A scoped run is more than "legacy mode with a different PRD path": it cuts a
# real branch/worktree, runs story and cleanup rounds there, merges that branch
# back into the base checkout, consolidates from the base checkout, and finally
# archives the run. This characterization test exercises that whole hand-off
# with a stub Codex process while leaving every Git operation real.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-scoped-lifecycle-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/calls"
PHASES_FILE="$TEST_ROOT/phases"
CWDS_DIR="$TEST_ROOT/cwds"
PROMPTS_DIR="$TEST_ROOT/prompts"
MARKER_LOG="$TEST_ROOT/markers"
OUTPUT_FILE="$TEST_ROOT/output"
RUN_ID="scoped-e2e"
TARGET_BRANCH="ralph/scoped-e2e"
TARGET_WORKTREE="$FIXTURE_REPO/.worktrees/$RUN_ID"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  if [[ -f "$OUTPUT_FILE" ]]; then
    echo "--- ralph output ---" >&2
    cat "$OUTPUT_FILE" >&2
  fi
  exit 1
}

mkdir -p "$FIXTURE_REPO" "$FAKE_BIN" "$CWDS_DIR" "$PROMPTS_DIR"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$FIXTURE_REPO/ralph"

# The fake tool behaves like a well-behaved agent for each of the three rounds
# that need one. In particular, the story commit happens in the linked
# worktree, while the consolidation commit happens in the base checkout. Ralph
# itself still owns worktree creation, PRD sync/amend, Git merge-back, marker
# verification, and the archive move/commit.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"
pwd > "$FAKE_CODEX_CWDS_DIR/cwd-$call_count"

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt_file="$FAKE_CODEX_PROMPTS_DIR/prompt-$call_count"
cat > "$prompt_file"

commit_if_needed() {
  local message="$1"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -qm "$message"
  fi
}

if grep -q '^## Scaffold Cleanup Context' "$prompt_file"; then
  phase="cleanup"
  cleanup_marker=$(grep -m1 '^- Cleanup marker' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  cleanup_run_id=$(grep -m1 '^- Run ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  mkdir -p "$(dirname "$cleanup_marker")"
  printf 'status=done\nrun_id=%s\n' "$cleanup_run_id" > "$cleanup_marker"
  printf 'cleanup=%s\n' "$(tr '\n' ',' < "$cleanup_marker")" >> "$FAKE_CODEX_MARKER_LOG"
  message="Scoped scaffold cleanup marker written."
elif grep -q '^## Ralph Consolidation Context' "$prompt_file"; then
  phase="consolidation"
  consolidation_marker=$(grep -m1 '^- Consolidation marker path' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  consolidation_run_id=$(grep -m1 '^- Run ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')

  mkdir -p docs/design-ledger
  cat > docs/design-ledger/scoped-e2e.md <<DOC
# Scoped lifecycle

Run \`$consolidation_run_id\` completed its story, merge-back, and consolidation lifecycle.
DOC
  git add docs/design-ledger/scoped-e2e.md
  git commit -qm "docs: consolidate scoped lifecycle"

  mkdir -p "$(dirname "$consolidation_marker")"
  printf 'status=done\nrun_id=%s\n' "$consolidation_run_id" > "$consolidation_marker"
  printf 'consolidation=%s\n' "$(tr '\n' ',' < "$consolidation_marker")" >> "$FAKE_CODEX_MARKER_LOG"
  message="Scoped knowledge consolidated."
elif grep -q '^## Ralph Current Story Context' "$prompt_file"; then
  phase="story"
  current_story=$(grep -m1 '^- Current story ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  story_file=$(grep -m1 '^- Current story file path: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')

  jq '.passes = true | .notes = "Passed in the scoped worktree lifecycle fixture."' \
    "$story_file" > "$story_file.tmp"
  mv "$story_file.tmp" "$story_file"
  printf 'implemented from %s\n' "$current_story" > scoped-feature.txt
  commit_if_needed "feat: complete $current_story in scoped worktree"
  message="Implemented $current_story in the scoped worktree."
else
  echo "Unexpected Ralph round in prompt $prompt_file" >&2
  exit 2
fi

printf '%s\n' "$phase" >> "$FAKE_CODEX_PHASES_FILE"
printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-scoped-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Ralph Test"
git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "test fixture"
git -C "$FIXTURE_REPO" branch -M main
BASE_SHA=$(git -C "$FIXTURE_REPO" rev-parse HEAD)

mkdir -p \
  "$FIXTURE_REPO/ralph/runs/$RUN_ID/progress" \
  "$FIXTURE_REPO/ralph/tasks"

cat > "$FIXTURE_REPO/ralph/runs/$RUN_ID/prd.json" <<PRD
{
  "project": "scoped lifecycle test",
  "branchName": "$TARGET_BRANCH",
  "userNeed": "A scoped run can land one isolated change on its base branch.",
  "userStories": [
    {
      "id": "US-001",
      "title": "Land an isolated scoped change",
      "description": "Covers: the real worktree, merge-back, consolidation, and archive path.",
      "acceptanceCriteria": ["The fake feature is committed from the scoped worktree."],
      "dependsOn": [],
      "passes": false,
      "notes": ""
    }
  ]
}
PRD

cat > "$FIXTURE_REPO/ralph/runs/$RUN_ID/progress.txt" <<'PROGRESS'
# Ralph Progress Log
---
PROGRESS
printf '%s\n' '[]' > "$FIXTURE_REPO/ralph/runs/$RUN_ID/progress/shared-memory.json"

jq -n \
  --arg runId "$RUN_ID" \
  --arg baseBranch "main" \
  --arg baseSha "$BASE_SHA" \
  --arg targetBranch "$TARGET_BRANCH" \
  '{
    runId: $runId,
    baseBranch: $baseBranch,
    baseSha: $baseSha,
    targetBranch: $targetBranch,
    status: "ready"
  }' > "$FIXTURE_REPO/ralph/runs/$RUN_ID/state.json"

cat > "$FIXTURE_REPO/ralph/tasks/prd-$RUN_ID.md" <<'TASK'
---
status: ready
---

# Scoped lifecycle fixture
TASK

git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "chore: initialize scoped run"

set +e
env \
  "PATH=$FAKE_BIN:$PATH" \
  "FAKE_CODEX_COUNT_FILE=$COUNT_FILE" \
  "FAKE_CODEX_PHASES_FILE=$PHASES_FILE" \
  "FAKE_CODEX_CWDS_DIR=$CWDS_DIR" \
  "FAKE_CODEX_PROMPTS_DIR=$PROMPTS_DIR" \
  "FAKE_CODEX_MARKER_LOG=$MARKER_LOG" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --run "$RUN_ID" --tool codex \
  > "$OUTPUT_FILE" 2>&1
RUN_STATUS=$?
set -e

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected the scoped lifecycle to complete, got exit $RUN_STATUS"
fi

# The normal happy path needs an agent for the story and the two semantic
# wrap-up rounds. Merge-back and archive are mechanical operations owned by
# ralph.sh and therefore must not create extra agent calls.
if [[ "$(cat "$COUNT_FILE")" -ne 3 ]]; then
  fail "Expected story, cleanup, and consolidation calls only; got $(cat "$COUNT_FILE") calls"
fi

EXPECTED_PHASES=$(printf 'story\ncleanup\nconsolidation')
if [[ "$(cat "$PHASES_FILE")" != "$EXPECTED_PHASES" ]]; then
  fail "Unexpected scoped phase order: $(tr '\n' ' ' < "$PHASES_FILE")"
fi

[[ "$(cat "$CWDS_DIR/cwd-1")" -ef "$TARGET_WORKTREE" ]] \
  || fail "The story round did not run in the scoped worktree"
[[ "$(cat "$CWDS_DIR/cwd-2")" -ef "$TARGET_WORKTREE" ]] \
  || fail "The scaffold cleanup round did not run in the scoped worktree"
[[ "$(cat "$CWDS_DIR/cwd-3")" -ef "$FIXTURE_REPO" ]] \
  || fail "The consolidation round did not run in the base checkout"

[[ -d "$TARGET_WORKTREE" ]] || fail "Ralph did not create $TARGET_WORKTREE"
[[ "$(git -C "$TARGET_WORKTREE" branch --show-current)" == "$TARGET_BRANCH" ]] \
  || fail "The scoped worktree is not checked out on $TARGET_BRANCH"
[[ "$(git -C "$FIXTURE_REPO" branch --show-current)" == "main" ]] \
  || fail "The base checkout moved away from main"

grep -Eq "Using Ralph worktree: .*/repo/\\.worktrees/$RUN_ID$" "$OUTPUT_FILE" \
  || fail "Ralph did not report the real scoped worktree"
grep -q 'Ralph finished the scaffold cleanup round. Merge-back next.' "$OUTPUT_FILE" \
  || fail "The verified cleanup marker did not advance the run to merge-back"
grep -q "Starting Git merge-back: $TARGET_BRANCH -> main" "$OUTPUT_FILE" \
  || fail "Ralph did not take the automatic Git merge-back path"
grep -q "Ralph completed merge-back + consolidation for run $RUN_ID." "$OUTPUT_FILE" \
  || fail "Ralph did not report the completed scoped lifecycle"

# Markers are the proof for semantic wrap-up rounds. The cleanup marker is
# deliberately removed with the archived run, so the stub records what Ralph
# saw before that move; the consolidation marker deliberately survives it.
grep -q 'cleanup=status=done,run_id=scoped-e2e,' "$MARKER_LOG" \
  || fail "The cleanup round did not write the scoped marker contract"
grep -q 'consolidation=status=done,run_id=scoped-e2e,' "$MARKER_LOG" \
  || fail "The consolidation round did not write the scoped marker contract"

CONSOLIDATION_MARKER="$FIXTURE_REPO/ralph/.consolidation-done-$RUN_ID"
[[ -f "$CONSOLIDATION_MARKER" ]] \
  || fail "The consolidation marker did not survive archival"
if git -C "$FIXTURE_REPO" ls-files --error-unmatch "ralph/.consolidation-done-$RUN_ID" >/dev/null 2>&1; then
  fail "The consolidation marker was committed; it is runtime control state"
fi

# The target branch must really be merged, and the merge must remain visible as
# a two-parent commit rather than being flattened into the archive commit.
git -C "$FIXTURE_REPO" merge-base --is-ancestor "$TARGET_BRANCH" main \
  || fail "$TARGET_BRANCH is not an ancestor of main after merge-back"
MERGE_COMMIT=$(git -C "$FIXTURE_REPO" log --merges --format='%H' \
  --grep="Merge branch '$TARGET_BRANCH' into main" -n 1)
[[ -n "$MERGE_COMMIT" ]] || fail "The scoped run did not produce a merge commit"
if [[ "$(git -C "$FIXTURE_REPO" rev-list --parents -n 1 "$MERGE_COMMIT" | wc -w | tr -d ' ')" -ne 3 ]]; then
  fail "The merge-back commit does not have exactly two parents"
fi

[[ "$(cat "$FIXTURE_REPO/scoped-feature.txt")" == 'implemented from US-001' ]] \
  || fail "The worktree's feature did not land on the base branch"
[[ -f "$FIXTURE_REPO/docs/design-ledger/scoped-e2e.md" ]] \
  || fail "The consolidation artifact did not land on the base branch"

ARCHIVE_DIR=$(find "$FIXTURE_REPO/ralph/archive" -mindepth 1 -maxdepth 1 \
  -type d -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$RUN_ID" -print | head -n 1)
[[ -n "$ARCHIVE_DIR" ]] || fail "Ralph did not archive the completed run"
[[ ! -e "$FIXTURE_REPO/ralph/runs/$RUN_ID" ]] \
  || fail "The completed run still exists under ralph/runs"
[[ -f "$ARCHIVE_DIR/prd-$RUN_ID.md" ]] \
  || fail "The source PRD markdown was not moved beside the archived run"
[[ "$(jq -r '.userStories[0].passes' "$ARCHIVE_DIR/prd.json")" == "true" ]] \
  || fail "The archived PRD lost the passing story state"
[[ -f "$ARCHIVE_DIR/stories/US-001.json" ]] \
  || fail "The archived run lost its per-story state"
[[ -f "$ARCHIVE_DIR/progress/MERGE-BACK.jsonl" ]] \
  || fail "The archived run lost its mechanical merge-back progress record"
[[ ! -e "$ARCHIVE_DIR/.merge-back-done" ]] \
  || fail "The merge-back marker leaked into the archive"
[[ ! -e "$ARCHIVE_DIR/.scaffold-cleanup-done" ]] \
  || fail "The scaffold cleanup marker leaked into the archive"

git -C "$FIXTURE_REPO" log -1 --format='%s' \
  | grep -q "^chore(ralph): archive completed run $RUN_ID$" \
  || fail "The final base-branch commit is not the scoped archive commit"

STATUS_FILE="$FIXTURE_REPO/ralph/status/$RUN_ID.json"
[[ -f "$STATUS_FILE" ]] || fail "The scoped run did not leave a terminal status record"
[[ "$(jq -r '.outcome' "$STATUS_FILE")" == "succeeded" ]] \
  || fail "The scoped status record did not finish as succeeded"
[[ "$(jq -r '.exitCode' "$STATUS_FILE")" == "0" ]] \
  || fail "The scoped status record did not preserve exit code 0"

echo "scoped lifecycle integration test: ok"
