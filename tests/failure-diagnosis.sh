#!/bin/bash
#
# A failed story round is not a dead end: Ralph runs one read-only diagnosis
# round, then one escalated recovery round that is handed that diagnosis. Only
# when the recovery round also leaves the story failing does Ralph stop for a
# human. Three fixtures cover the two outcomes plus the escalation override.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-failure-diagnosis-test.XXXXXX")
TEMPLATE_RALPH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph"
FAKE_BIN="$TEST_ROOT/bin"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FAKE_BIN"

# Call 1 is the implementation round and always leaves the story failing. Call 2
# is the diagnosis round. Call 3 is the recovery round, which completes the story
# only when the scenario asks it to.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

# One argument per line: the escalation args have to land in a specific place in
# the argv, not merely be present somewhere in it.
printf '%s\n' "$@" > "$FAKE_CODEX_ARGS_DIR/argv-$call_count"

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

cat > "$FAKE_CODEX_PROMPTS_DIR/prompt-$call_count"

case "$call_count" in
  1)
    message="Implementation stopped before the acceptance criteria passed."
    ;;
  2)
    message=$(printf '%s\n' \
      'Story' \
      'US-001' \
      'What failed' \
      'The story remained passes=false.' \
      'Likely root cause' \
      'The implementation round did not update the story state (high confidence).' \
      'Evidence' \
      'The authoritative story JSON is still incomplete.' \
      'Recommended next action' \
      'Finish the story state update in the recovery round.')
    ;;
  *)
    if [[ "$FAKE_CODEX_RECOVER" == "1" ]]; then
      for story_file in "$FAKE_CODEX_STORIES_DIR"/*.json; do
        [[ -f "$story_file" ]] || continue
        jq '.passes = true' "$story_file" > "$story_file.tmp"
        mv "$story_file.tmp" "$story_file"
      done
      message="Recovery round finished the story."
    else
      message="Recovery round could not finish the story either."
    fi
    ;;
esac

printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

SCENARIO=""
FIXTURE_REPO=""
COUNT_FILE=""
ARGS_DIR=""
PROMPTS_DIR=""
OUTPUT_FILE=""
RECOVER="0"
RUN_STATUS=0

fail() {
  echo "$1" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
}

# Each scenario gets its own fixture repo: the story state one run leaves behind
# would otherwise decide what the next run does.
setup_scenario() {
  SCENARIO="$1"
  RECOVER="$2"
  local scenario_dir="$TEST_ROOT/$SCENARIO"

  FIXTURE_REPO="$scenario_dir/repo"
  COUNT_FILE="$scenario_dir/calls"
  ARGS_DIR="$scenario_dir/argv"
  PROMPTS_DIR="$scenario_dir/prompts"
  OUTPUT_FILE="$scenario_dir/output"

  mkdir -p "$FIXTURE_REPO" "$ARGS_DIR" "$PROMPTS_DIR"
  cp -R "$TEMPLATE_RALPH" "$FIXTURE_REPO/ralph"

  cat > "$FIXTURE_REPO/ralph/prd.json" <<'PRD'
{
  "project": "failure diagnosis test",
  "branchName": "",
  "userStories": [
    {
      "id": "US-001",
      "title": "A story that stays incomplete",
      "description": "Exercise the failure diagnosis handoff.",
      "acceptanceCriteria": ["The fake implementation would need to mark this story complete."],
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

# `env` rather than a bare assignment prefix, so a scenario can pass extra
# variables through "$@" - an expanded word is no longer parsed as an assignment.
run_ralph() {
  set +e
  env \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_CODEX_COUNT_FILE=$COUNT_FILE" \
    "FAKE_CODEX_ARGS_DIR=$ARGS_DIR" \
    "FAKE_CODEX_PROMPTS_DIR=$PROMPTS_DIR" \
    "FAKE_CODEX_STORIES_DIR=$FIXTURE_REPO/ralph/stories" \
    "FAKE_CODEX_RECOVER=$RECOVER" \
    RALPH_NOTIFY=0 \
    RALPH_PROGRESS=0 \
    "$@" \
    bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
    > "$OUTPUT_FILE" 2>&1
  RUN_STATUS=$?
  set -e
}

# 1-based position of an exact argv entry, empty when it is not there at all.
argv_index() {
  grep -n -x -F -- "$2" "$ARGS_DIR/argv-$1" | head -n 1 | cut -d: -f1
}

argv_count() {
  wc -l < "$ARGS_DIR/argv-$1" | tr -d ' '
}

# --- recovery round runs, and still cannot finish the story ------------------

setup_scenario "recovery-fails" "0"
run_ralph

if [[ "$RUN_STATUS" -ne 1 ]]; then
  fail "Expected Ralph to exit 1 after the recovery round, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 3 ]]; then
  fail "Expected implementation, diagnosis and recovery calls, got $(cat "$COUNT_FILE")"
fi

if ! grep -q -x -- '--sandbox' "$ARGS_DIR/argv-2"; then
  fail "Expected the diagnosis call to use the Codex read-only sandbox"
fi

if grep -q -x -- '--dangerously-bypass-approvals-and-sandbox' "$ARGS_DIR/argv-2"; then
  fail "Diagnosis call unexpectedly bypassed the sandbox"
fi

if grep -q -x -- '--sandbox' "$ARGS_DIR/argv-3"; then
  fail "Recovery call ran read-only instead of with write access"
fi

if ! grep -q -x -- '--dangerously-bypass-approvals-and-sandbox' "$ARGS_DIR/argv-3"; then
  fail "Expected the recovery call to run with write access"
fi

XHIGH_INDEX="$(argv_index 3 'model_reasoning_effort=xhigh')"
DASH_INDEX="$(argv_index 3 '-')"
if [[ -z "$XHIGH_INDEX" ]]; then
  fail "Expected the recovery call to escalate the Codex reasoning effort"
fi
if [[ -z "$DASH_INDEX" || "$DASH_INDEX" -ne "$(argv_count 3)" ]]; then
  fail "Expected Codex's prompt-from-stdin '-' to stay the last argument"
fi
if [[ "$XHIGH_INDEX" -ge "$DASH_INDEX" ]]; then
  fail "Escalation args landed after '-', where Codex reads them as positionals"
fi

grep -q 'Implementation stopped before the acceptance criteria passed.' "$PROMPTS_DIR/prompt-2"
grep -q 'A story that stays incomplete' "$PROMPTS_DIR/prompt-2"
grep -q 'Read-Only Contract' "$PROMPTS_DIR/prompt-2"

grep -q 'Ralph Story Recovery Round' "$PROMPTS_DIR/prompt-3"
grep -q '## Story Recovery Context' "$PROMPTS_DIR/prompt-3"
# Rebuilt from the normal story prompt, not a copy of the failed round's file.
grep -q '### Relevant Progress JSON (sliced)' "$PROMPTS_DIR/prompt-3"
grep -q 'The implementation round did not update the story state (high confidence).' "$PROMPTS_DIR/prompt-3"
grep -q 'Implementation stopped before the acceptance criteria passed.' "$PROMPTS_DIR/prompt-3"
grep -q 'A story that stays incomplete' "$PROMPTS_DIR/prompt-3"

grep -q 'Ralph Failure Diagnosis Round' "$OUTPUT_FILE"
grep -q 'The story remained passes=false.' "$OUTPUT_FILE"
grep -q 'Recovery round could not finish the story either.' "$OUTPUT_FILE"
grep -q 'Ralph stopped after diagnosing US-001' "$OUTPUT_FILE"

if grep -q 'Ralph Round 2 ' "$OUTPUT_FILE"; then
  fail "Ralph incorrectly started a second implementation round"
fi

if [[ "$(jq -r '.passes' "$FIXTURE_REPO/ralph/stories/US-001.json")" != "false" ]]; then
  fail "The failing run unexpectedly marked the story complete"
fi

# --- recovery round rescues the story ----------------------------------------

setup_scenario "recovery-succeeds" "1"
run_ralph

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected Ralph to finish the run after a successful recovery, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 3 ]]; then
  fail "Expected exactly three agent calls after a successful recovery, got $(cat "$COUNT_FILE")"
fi

grep -q 'Ralph recovered US-001 in the escalated recovery round.' "$OUTPUT_FILE"
grep -q 'Ralph completed all tasks!' "$OUTPUT_FILE"

if [[ "$(jq -r '.userStories[0].passes' "$FIXTURE_REPO/ralph/prd.json")" != "true" ]]; then
  fail "Expected the recovered story to be synced back into the PRD"
fi

# --- RALPH_CODEX_RECOVERY_ARGS replaces the default escalation ----------------

setup_scenario "recovery-args-override" "0"
run_ralph "RALPH_CODEX_RECOVERY_ARGS=-c model_reasoning_effort=high"

if [[ "$RUN_STATUS" -ne 1 ]]; then
  fail "Expected Ralph to exit 1 after the recovery round, got $RUN_STATUS"
fi

if grep -q -x -- 'model_reasoning_effort=xhigh' "$ARGS_DIR/argv-3"; then
  fail "RALPH_CODEX_RECOVERY_ARGS did not replace the default escalation args"
fi

HIGH_INDEX="$(argv_index 3 'model_reasoning_effort=high')"
DASH_INDEX="$(argv_index 3 '-')"
if [[ -z "$HIGH_INDEX" ]]; then
  fail "Expected the overridden escalation args on the recovery call"
fi
if [[ -z "$DASH_INDEX" || "$HIGH_INDEX" -ge "$DASH_INDEX" ]]; then
  fail "Overridden escalation args landed after Codex's trailing '-'"
fi

echo "failure diagnosis integration test: ok"
