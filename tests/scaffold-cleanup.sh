#!/bin/bash
#
# A story round proves one slice and props itself up to do it: a per-story test
# command, a fixture, a stub for something that lands two stories later. None of
# that should reach the base branch, and no story round can remove it - each one
# only ever sees its own slice. So Ralph runs one scaffold cleanup round after
# the last story passes and before anything merges back.
#
# Three fixtures: the round runs exactly once and last, it is trusted only via
# its marker file, and it can be switched off.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-scaffold-cleanup-test.XXXXXX")
TEMPLATE_RALPH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph"
FAKE_BIN="$TEST_ROOT/bin"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FAKE_BIN"

# The stub tells the cleanup round from a story round the way a real agent
# would - by the prompt it was handed - and satisfies it the way a real one has
# to: by writing the marker file. FAKE_CLEANUP_MODE=ignore models the agent that
# says it is done without writing one.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

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

if grep -q '^## Scaffold Cleanup Context' "$prompt_file"; then
  if [[ "$FAKE_CLEANUP_MODE" == "ignore" ]]; then
    # The failure mode the marker exists to catch: a confident report, no marker.
    message="Removed the scaffolding. <promise>COMPLETE</promise>"
  else
    cleanup_marker=$(grep -m1 '^- Cleanup marker' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
    cleanup_run_id=$(grep -m1 '^- Run ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
    printf 'status=done\nrun_id=%s\n' "$cleanup_run_id" > "$cleanup_marker"
    message="Removed the run's per-story scaffolding."
  fi
else
  current_story=$(grep -m1 '^- Current story ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  story_file="$FAKE_CODEX_STORIES_DIR/$current_story.json"
  if [[ -f "$story_file" ]]; then
    jq '.passes = true' "$story_file" > "$story_file.tmp"
    mv "$story_file.tmp" "$story_file"
  fi
  message="Implemented $current_story."
fi

printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

SCENARIO=""
FIXTURE_REPO=""
COUNT_FILE=""
PROMPTS_DIR=""
OUTPUT_FILE=""
MARKER_FILE=""
RUN_STATUS=0

fail() {
  echo "$1" >&2
  if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
    echo "--- ralph output ---" >&2
    cat "$OUTPUT_FILE" >&2
  fi
  exit 1
}

setup_scenario() {
  SCENARIO="$1"
  local scenario_dir="$TEST_ROOT/$SCENARIO"

  FIXTURE_REPO="$scenario_dir/repo"
  COUNT_FILE="$scenario_dir/calls"
  PROMPTS_DIR="$scenario_dir/prompts"
  OUTPUT_FILE="$scenario_dir/output"
  MARKER_FILE="$FIXTURE_REPO/ralph/.scaffold-cleanup-done"

  mkdir -p "$FIXTURE_REPO" "$PROMPTS_DIR"
  cp -R "$TEMPLATE_RALPH" "$FIXTURE_REPO/ralph"

  # Two stories, so "the cleanup round runs after the last one" is a claim the
  # call order can actually falsify.
  cat > "$FIXTURE_REPO/ralph/prd.json" <<'PRD'
{
  "project": "scaffold cleanup test",
  "branchName": "",
  "userNeed": "The branch that merges back carries the feature and not its propping.",
  "userStories": [
    {
      "id": "US-001",
      "title": "First slice",
      "description": "Covers: the first half of the need.",
      "acceptanceCriteria": ["The fake implementation marks this complete."],
      "dependsOn": [],
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Second slice",
      "description": "Covers: the second half of the need.",
      "acceptanceCriteria": ["The fake implementation marks this complete."],
      "dependsOn": [],
      "passes": false,
      "notes": ""
    }
  ]
}
PRD

  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.name "Ralph Test"
  git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
  git -C "$FIXTURE_REPO" add .
  git -C "$FIXTURE_REPO" commit -qm "test fixture"
}

run_ralph() {
  local cleanup_mode="$1"
  local skip="${2:-0}"

  set +e
  env \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_CODEX_COUNT_FILE=$COUNT_FILE" \
    "FAKE_CODEX_PROMPTS_DIR=$PROMPTS_DIR" \
    "FAKE_CODEX_STORIES_DIR=$FIXTURE_REPO/ralph/stories" \
    "FAKE_CLEANUP_MODE=$cleanup_mode" \
    "RALPH_SKIP_SCAFFOLD_CLEANUP=$skip" \
    RALPH_NOTIFY=0 \
    RALPH_PROGRESS=0 \
    bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
    > "$OUTPUT_FILE" 2>&1
  RUN_STATUS=$?
  set -e
}

# --- One round, after the last story, carrying what it needs to do the job ----

setup_scenario "happy"
run_ralph "write-marker"

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected the run to finish once the cleanup round wrote its marker, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 3 ]]; then
  fail "Expected one round per story plus one cleanup round, got $(cat "$COUNT_FILE")"
fi

# Last, not first: a round that ran while stories were still failing would be
# deleting propping the remaining stories still stand on.
if grep -q '^## Scaffold Cleanup Context' "$PROMPTS_DIR/prompt-1"; then
  fail "The cleanup round ran before the first story was implemented"
fi
if grep -q '^## Scaffold Cleanup Context' "$PROMPTS_DIR/prompt-2"; then
  fail "The cleanup round ran before the last story was implemented"
fi
grep -q '^## Scaffold Cleanup Context' "$PROMPTS_DIR/prompt-3" \
  || fail "The round after the last story was not the scaffold cleanup round"

# The round is the tool playbook plus CLEANUP_SCAFFOLD.md plus the context that
# tells it what this run changed. Missing any one of those makes it guess.
grep -q '## Ralph Run Context' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt lost the shared run context"
grep -q '^# Scaffold Cleanup Round' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt did not include CLEANUP_SCAFFOLD.md"
grep -q '^- Base commit this run started from: ' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt did not say which commit this run started from"
grep -q '^- Cleanup marker' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt did not name the marker file it must write"
grep -q -- '--legacy --story SCAFFOLD-CLEANUP' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt did not carry an append command for its own progress record"
grep -q 'US-002' "$PROMPTS_DIR/prompt-3" \
  || fail "The cleanup prompt did not list the run's stories"

grep -q 'Ralph Scaffold Cleanup Round' "$OUTPUT_FILE" \
  || fail "The loop did not announce the scaffold cleanup round"
grep -q 'Ralph completed all tasks!' "$OUTPUT_FILE" \
  || fail "The run did not finish after the cleanup round"

[[ -f "$MARKER_FILE" ]] || fail "The cleanup marker was not left behind at $MARKER_FILE"

# Runtime control state, not a repository artifact: it must not be committed,
# and the loop must not have staged it on the way out.
if git -C "$FIXTURE_REPO" ls-files --error-unmatch ralph/.scaffold-cleanup-done >/dev/null 2>&1; then
  fail "The cleanup marker was committed; it is runtime control state"
fi

# --- The marker is what the loop trusts, not the agent's report ---------------

setup_scenario "no-marker"
run_ralph "ignore"

if [[ "$RUN_STATUS" -eq 0 ]]; then
  fail "Expected the run to stop when the cleanup round never wrote its marker"
fi

# Two stories, then the cleanup round retried up to its budget.
if [[ "$(cat "$COUNT_FILE")" -ne 5 ]]; then
  fail "Expected the cleanup round to retry three times, got $(cat "$COUNT_FILE") calls in total"
fi

grep -q 'reported COMPLETE, but the scaffold cleanup marker was not written' "$OUTPUT_FILE" \
  || fail "The loop took the agent's word for a round it could not verify"
grep -q 'Ralph ran the scaffold cleanup round 3 times without it completing' "$OUTPUT_FILE" \
  || fail "The cleanup round did not stop at its retry budget"

if [[ -f "$MARKER_FILE" ]]; then
  fail "A marker exists for a round that never completed"
fi

# --- It can be switched off ---------------------------------------------------

setup_scenario "skipped"
run_ralph "write-marker" 1

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected the run to finish with the cleanup round disabled, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  fail "Expected one round per story and nothing else, got $(cat "$COUNT_FILE")"
fi

if grep -q 'Scaffold Cleanup Round' "$OUTPUT_FILE"; then
  fail "RALPH_SKIP_SCAFFOLD_CLEANUP=1 still ran the cleanup round"
fi

echo "scaffold cleanup integration test: ok"
