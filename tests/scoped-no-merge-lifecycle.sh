#!/bin/bash
#
# A scoped run does not need a target branch to have a scoped lifecycle. With
# branchName empty, story work stays in the base checkout and merge-back is a
# no-op, but consolidation and archival are still mandatory.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-scoped-no-merge-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/calls"
PHASES_FILE="$TEST_ROOT/phases"
CWDS_DIR="$TEST_ROOT/cwds"
PROMPTS_DIR="$TEST_ROOT/prompts"
OUTPUT_FILE="$TEST_ROOT/output"
RUN_ID="scoped-no-merge"

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

# The fake Codex process owns only the two semantic rounds. Ralph itself owns
# PRD synchronization plus the archive move and archive commit.
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

if grep -q '^## Ralph Consolidation Context' "$prompt_file"; then
  phase="consolidation"
  marker=$(grep -m1 '^- Consolidation marker path' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  marker_run_id=$(grep -m1 '^- Run ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')

  mkdir -p docs/design-ledger
  printf '# No-merge scoped lifecycle\n\nRun `%s` was consolidated without merge-back.\n' \
    "$marker_run_id" > docs/design-ledger/scoped-no-merge.md
  git add docs/design-ledger/scoped-no-merge.md
  git commit -qm "docs: consolidate no-merge scoped lifecycle"

  mkdir -p "$(dirname "$marker")"
  printf 'status=done\nrun_id=%s\n' "$marker_run_id" > "$marker"
  message="Scoped knowledge consolidated without merge-back."
elif grep -q '^## Ralph Current Story Context' "$prompt_file"; then
  phase="story"
  story_id=$(grep -m1 '^- Current story ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  story_file=$(grep -m1 '^- Current story file path: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')

  jq '.passes = true | .notes = "Passed in the base checkout fixture."' \
    "$story_file" > "$story_file.tmp"
  mv "$story_file.tmp" "$story_file"
  printf 'implemented from %s\n' "$story_id" > no-merge-feature.txt
  git add "$story_file" no-merge-feature.txt
  git commit -qm "feat: complete $story_id without a target branch"
  message="Implemented $story_id in the base checkout."
else
  echo "Unexpected Ralph round in prompt $prompt_file" >&2
  exit 2
fi

printf '%s\n' "$phase" >> "$FAKE_CODEX_PHASES_FILE"
printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-no-merge-session"}'
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

cat > "$FIXTURE_REPO/ralph/runs/$RUN_ID/prd.json" <<'PRD'
{
  "project": "scoped no-merge lifecycle test",
  "branchName": "",
  "userNeed": "A scoped run can finish without creating or merging a branch.",
  "userStories": [
    {
      "id": "US-001",
      "title": "Finish a scoped run in the base checkout",
      "description": "Covers the story, consolidation, and archive path without merge-back.",
      "acceptanceCriteria": ["The fake feature is committed in the base checkout."],
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
  --arg baseSha "$BASE_SHA" \
  '{
    runId: $runId,
    baseBranch: "main",
    baseSha: $baseSha,
    targetBranch: "",
    status: "ready"
  }' > "$FIXTURE_REPO/ralph/runs/$RUN_ID/state.json"

cat > "$FIXTURE_REPO/ralph/tasks/prd-$RUN_ID.md" <<'TASK'
---
status: ready
---

# Scoped no-merge lifecycle fixture
TASK

git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "chore: initialize scoped no-merge run"

set +e
env \
  "PATH=$FAKE_BIN:$PATH" \
  "FAKE_CODEX_COUNT_FILE=$COUNT_FILE" \
  "FAKE_CODEX_PHASES_FILE=$PHASES_FILE" \
  "FAKE_CODEX_CWDS_DIR=$CWDS_DIR" \
  "FAKE_CODEX_PROMPTS_DIR=$PROMPTS_DIR" \
  RALPH_SKIP_SCAFFOLD_CLEANUP=1 \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --run "$RUN_ID" --tool codex \
  > "$OUTPUT_FILE" 2>&1
RUN_STATUS=$?
set -e

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected the scoped no-merge lifecycle to complete, got exit $RUN_STATUS"
fi

[[ -f "$COUNT_FILE" ]] || fail "The scoped no-merge lifecycle never invoked Codex"
if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  fail "Expected story and consolidation calls only; got $(cat "$COUNT_FILE") calls"
fi

EXPECTED_PHASES=$(printf 'story\nconsolidation')
if [[ "$(cat "$PHASES_FILE")" != "$EXPECTED_PHASES" ]]; then
  fail "Unexpected scoped phase order: $(tr '\n' ' ' < "$PHASES_FILE")"
fi

[[ "$(cat "$CWDS_DIR/cwd-1")" -ef "$FIXTURE_REPO" ]] \
  || fail "The story round did not run in the base checkout"
[[ "$(cat "$CWDS_DIR/cwd-2")" -ef "$FIXTURE_REPO" ]] \
  || fail "The consolidation round did not run in the base checkout"

if grep -Eq 'Scaffold Cleanup Round|Merge-Back Round|Starting Git merge-back' "$OUTPUT_FILE"; then
  fail "The no-merge lifecycle ran cleanup or merge-back"
fi
grep -q "Ralph completed consolidation for run $RUN_ID." "$OUTPUT_FILE" \
  || fail "Ralph did not report consolidation without merge-back"

[[ "$(git -C "$FIXTURE_REPO" branch --show-current)" == "main" ]] \
  || fail "The base checkout moved away from main"
if [[ -n "$(git -C "$FIXTURE_REPO" log --merges --format='%H')" ]]; then
  fail "The no-merge lifecycle created a merge commit"
fi
[[ "$(cat "$FIXTURE_REPO/no-merge-feature.txt")" == 'implemented from US-001' ]] \
  || fail "The story artifact is missing from the base checkout"
[[ -f "$FIXTURE_REPO/docs/design-ledger/scoped-no-merge.md" ]] \
  || fail "The consolidation artifact is missing from the base checkout"

ARCHIVE_DIR=$(find "$FIXTURE_REPO/ralph/archive" -mindepth 1 -maxdepth 1 \
  -type d -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$RUN_ID" -print | head -n 1)
[[ -n "$ARCHIVE_DIR" ]] || fail "Ralph did not archive the completed run"
[[ ! -e "$FIXTURE_REPO/ralph/runs/$RUN_ID" ]] \
  || fail "The completed run still exists under ralph/runs"
[[ ! -e "$FIXTURE_REPO/ralph/tasks/prd-$RUN_ID.md" ]] \
  || fail "The source PRD markdown still exists under ralph/tasks"
[[ -f "$ARCHIVE_DIR/prd-$RUN_ID.md" ]] \
  || fail "The source PRD markdown was not archived beside the run"
[[ "$(jq -r '.userStories[0].passes' "$ARCHIVE_DIR/prd.json")" == "true" ]] \
  || fail "The archived PRD lost the passing story state"
[[ -f "$ARCHIVE_DIR/stories/US-001.json" ]] \
  || fail "The archived run lost its per-story state"
[[ ! -e "$ARCHIVE_DIR/progress/MERGE-BACK.jsonl" ]] \
  || fail "A no-merge run recorded mechanical merge-back progress"

CONSOLIDATION_MARKER="$FIXTURE_REPO/ralph/.consolidation-done-$RUN_ID"
[[ -f "$CONSOLIDATION_MARKER" ]] \
  || fail "The consolidation marker did not survive archival"
if git -C "$FIXTURE_REPO" ls-files --error-unmatch "ralph/.consolidation-done-$RUN_ID" >/dev/null 2>&1; then
  fail "The consolidation marker was committed; it is runtime control state"
fi

git -C "$FIXTURE_REPO" log -1 --format='%s' \
  | grep -q "^chore(ralph): archive completed run $RUN_ID$" \
  || fail "The final base-branch commit is not the archive commit"

echo "scoped no-merge lifecycle integration test: ok"
