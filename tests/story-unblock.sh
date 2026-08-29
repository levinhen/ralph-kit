#!/bin/bash
#
# A failed story round is not a dead end and not a blind retry: Ralph runs one
# story unblock round that first decides whether the story is genuinely blocked
# or was merely unfinished. Unfinished stories get finished there; blocked ones
# get the backlog restructured around them and the loop continues on the new
# split; anything else stops the run. Four fixtures cover those three outcomes
# plus the restructure cap.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-story-unblock-test.XXXXXX")
TEMPLATE_RALPH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph"
FAKE_BIN="$TEST_ROOT/bin"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FAKE_BIN"

# The stub tells the two round kinds apart the way a real agent would - by what
# the prompt it was handed says - rather than by counting calls.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

# One argument per line: argv position matters for some of these flags.
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

prompt_file="$FAKE_CODEX_PROMPTS_DIR/prompt-$call_count"
cat > "$prompt_file"

current_story=$(grep -m1 '^- Current story ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')

pass_current_story() {
  local story_file="$FAKE_CODEX_STORIES_DIR/$current_story.json"
  [[ -f "$story_file" ]] || return 0
  jq '.passes = true' "$story_file" > "$story_file.tmp"
  mv "$story_file.tmp" "$story_file"
}

# What a real unblock round does when it judges the story blocked: carve the
# prerequisite out in front of it, point the blocked story at the new one, and
# keep the story files it already has in step with the PRD. The new story's own
# file is deliberately left for Ralph to back-fill.
restructure_backlog() {
  local new_id="US-90$call_count"
  local tmp="$FAKE_CODEX_PRD_FILE.tmp"
  local sid

  jq --arg id "$new_id" '
    .userStories = (
      [{
        id: $id,
        title: "Prerequisite carved out of the blocked story",
        description: "Covers: the setup slice the blocked story assumed.",
        acceptanceCriteria: ["Typecheck passes"],
        dependsOn: [],
        passes: false,
        notes: ""
      }]
      + (.userStories | map(
          if .passes == true then .
          else .dependsOn = ((.dependsOn // []) + [$id])
          end))
    )
  ' "$FAKE_CODEX_PRD_FILE" > "$tmp"
  mv "$tmp" "$FAKE_CODEX_PRD_FILE"

  for story_file in "$FAKE_CODEX_STORIES_DIR"/*.json; do
    [[ -f "$story_file" ]] || continue
    sid=$(jq -r '.id' "$story_file")
    jq --arg id "$sid" '.userStories[] | select(.id == $id)' "$FAKE_CODEX_PRD_FILE" > "$story_file.tmp"
    mv "$story_file.tmp" "$story_file"
  done

  printf 'x\n' >> "$FAKE_CODEX_RESTRUCTURE_FILE"
}

if grep -q 'Ralph Story Unblock Round' "$prompt_file"; then
  case "$FAKE_CODEX_UNBLOCK_MODE" in
    finish)
      pass_current_story
      message="Verdict: not blocked, only unfinished. Finished $current_story from the previous round's checkpoint."
      ;;
    restructure)
      restructure_backlog
      message="Verdict: blocked. The observation point lives in a later story, so I carved out the prerequisite and re-ran the dependency audit."
      ;;
    *)
      message="Verdict: blocked on a decision only a human can make. Leaving $current_story at passes=false."
      ;;
  esac
else
  if [[ "$FAKE_CODEX_STORY_MODE" == "pass-after-restructure" && -s "$FAKE_CODEX_RESTRUCTURE_FILE" ]]; then
    pass_current_story
    message="Implemented $current_story on the restructured split."
  else
    message="Implementation stopped before the acceptance criteria passed."
  fi
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
ARGS_DIR=""
PROMPTS_DIR=""
OUTPUT_FILE=""
RESTRUCTURE_FILE=""
UNBLOCK_MODE=""
STORY_MODE=""
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
  UNBLOCK_MODE="$2"
  STORY_MODE="$3"
  local scenario_dir="$TEST_ROOT/$SCENARIO"

  FIXTURE_REPO="$scenario_dir/repo"
  COUNT_FILE="$scenario_dir/calls"
  ARGS_DIR="$scenario_dir/argv"
  PROMPTS_DIR="$scenario_dir/prompts"
  OUTPUT_FILE="$scenario_dir/output"
  RESTRUCTURE_FILE="$scenario_dir/restructures"

  mkdir -p "$FIXTURE_REPO" "$ARGS_DIR" "$PROMPTS_DIR"
  : > "$RESTRUCTURE_FILE"
  cp -R "$TEMPLATE_RALPH" "$FIXTURE_REPO/ralph"

  cat > "$FIXTURE_REPO/ralph/prd.json" <<'PRD'
{
  "project": "story unblock test",
  "branchName": "",
  "userNeed": "A worker can see the thing happen.",
  "userStories": [
    {
      "id": "US-001",
      "title": "A story that stays incomplete",
      "description": "Exercise the unblock round. Covers: the whole need.",
      "acceptanceCriteria": ["The fake implementation would need to mark this story complete."],
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
    "FAKE_CODEX_PRD_FILE=$FIXTURE_REPO/ralph/prd.json" \
    "FAKE_CODEX_RESTRUCTURE_FILE=$RESTRUCTURE_FILE" \
    "FAKE_CODEX_UNBLOCK_MODE=$UNBLOCK_MODE" \
    "FAKE_CODEX_STORY_MODE=$STORY_MODE" \
    RALPH_NOTIFY=0 \
    RALPH_PROGRESS=0 \
    "$@" \
    bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
    > "$OUTPUT_FILE" 2>&1
  RUN_STATUS=$?
  set -e
}

# --- not blocked: the unblock round finishes the story -----------------------

setup_scenario "unfinished" "finish" "always-fail"
run_ralph

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected Ralph to finish the run after the unblock round completed the story, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  fail "Expected exactly one implementation call and one unblock call, got $(cat "$COUNT_FILE")"
fi

# One round, not a diagnosis/recovery relay: the second call already has write
# access, and nothing escalates its reasoning budget.
if grep -q -x -- '--sandbox' "$ARGS_DIR/argv-2"; then
  fail "The unblock call ran read-only instead of with write access"
fi

if ! grep -q -x -- '--dangerously-bypass-approvals-and-sandbox' "$ARGS_DIR/argv-2"; then
  fail "Expected the unblock call to run with write access"
fi

if grep -q -- 'model_reasoning_effort' "$ARGS_DIR/argv-2"; then
  fail "The unblock call escalated the reasoning effort; it is meant to be an ordinary round"
fi

if [[ "$(tail -n 1 "$ARGS_DIR/argv-2")" != "-" ]]; then
  fail "Expected Codex's prompt-from-stdin '-' to stay the last argument"
fi

# Rebuilt from the normal story prompt, with the unblock contract and the failed
# round's evidence layered on top.
grep -q 'Ralph Story Unblock Round' "$PROMPTS_DIR/prompt-2"
grep -q '## Story Unblock Context' "$PROMPTS_DIR/prompt-2"
grep -q 'Step 1: Decide Whether the Story Is Blocked' "$PROMPTS_DIR/prompt-2"
grep -q '### Relevant Progress JSON (sliced)' "$PROMPTS_DIR/prompt-2"
grep -q 'Implementation stopped before the acceptance criteria passed.' "$PROMPTS_DIR/prompt-2"
grep -q 'A story that stays incomplete' "$PROMPTS_DIR/prompt-2"

grep -q 'Ralph Story Unblock Round' "$OUTPUT_FILE"
grep -q 'it was unfinished, not blocked' "$OUTPUT_FILE"
grep -q 'Ralph completed all tasks!' "$OUTPUT_FILE"

if [[ "$(jq -r '.userStories[0].passes' "$FIXTURE_REPO/ralph/prd.json")" != "true" ]]; then
  fail "Expected the finished story to be synced back into the PRD"
fi

# --- blocked: the unblock round restructures and the loop continues ----------

setup_scenario "blocked" "restructure" "pass-after-restructure"
run_ralph

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected Ralph to finish the run on the restructured split, got $RUN_STATUS"
fi

# implementation, unblock/restructure, then one round per story on the new split.
if [[ "$(cat "$COUNT_FILE")" -ne 4 ]]; then
  fail "Expected four agent calls across the restructured split, got $(cat "$COUNT_FILE")"
fi

grep -q 'judged US-001 blocked and restructured the backlog' "$OUTPUT_FILE"
grep -q 'Restructure 1 of 2 for this run' "$OUTPUT_FILE"
grep -q 'Ralph completed all tasks!' "$OUTPUT_FILE"

if [[ "$(jq -r '.userStories | length' "$FIXTURE_REPO/ralph/prd.json")" -ne 2 ]]; then
  fail "Expected the restructured PRD to carry the carved-out prerequisite story"
fi

if [[ "$(jq -r '.userStories[0].id' "$FIXTURE_REPO/ralph/prd.json")" == "US-001" ]]; then
  fail "Expected the prerequisite story to sit ahead of the story it unblocks"
fi

if [[ "$(jq -r 'all(.userStories[]; .passes == true)' "$FIXTURE_REPO/ralph/prd.json")" != "true" ]]; then
  fail "Expected every story on the restructured split to end up passing"
fi

# The restructure only wrote the PRD entry for the new story; Ralph back-fills
# its story file so the next round treats it as an ordinary story.
NEW_STORY_ID=$(jq -r '.userStories[0].id' "$FIXTURE_REPO/ralph/prd.json")
if [[ ! -f "$FIXTURE_REPO/ralph/stories/$NEW_STORY_ID.json" ]]; then
  fail "Ralph did not back-fill the story file for the restructured story $NEW_STORY_ID"
fi

if [[ "$(jq -r '.userNeed // "missing"' "$FIXTURE_REPO/ralph/stories/$NEW_STORY_ID.json")" == "missing" ]]; then
  fail "The back-filled story file did not inherit the root userNeed"
fi

# The restructured dependency edge survived the story-file sync.
if [[ "$(jq -r --arg id "$NEW_STORY_ID" '.userStories[] | select(.id == "US-001") | .dependsOn | index($id) != null' "$FIXTURE_REPO/ralph/prd.json")" != "true" ]]; then
  fail "US-001 lost the dependency edge the restructure added"
fi

# --- neither finished nor restructured: Ralph stops for a human --------------

setup_scenario "human-only" "stuck" "always-fail"
run_ralph

if [[ "$RUN_STATUS" -ne 1 ]]; then
  fail "Expected Ralph to exit 1 when the unblock round could do neither, got $RUN_STATUS"
fi

if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  fail "Expected exactly one implementation call and one unblock call, got $(cat "$COUNT_FILE")"
fi

grep -q 'blocked on a decision only a human can make' "$OUTPUT_FILE"
grep -q 'neither finished US-001 nor restructured the backlog around it' "$OUTPUT_FILE"

if grep -q 'Ralph Round 2 ' "$OUTPUT_FILE"; then
  fail "Ralph incorrectly started a second implementation round"
fi

if [[ "$(jq -r '.userStories[0].passes' "$FIXTURE_REPO/ralph/prd.json")" != "false" ]]; then
  fail "The failing run unexpectedly marked the story complete"
fi

# --- a split that keeps needing repair hits the restructure cap --------------

setup_scenario "restructure-cap" "restructure" "always-fail"
run_ralph "RALPH_MAX_RESTRUCTURES=1"

if [[ "$RUN_STATUS" -ne 1 ]]; then
  fail "Expected Ralph to exit 1 once the restructure cap was reached, got $RUN_STATUS"
fi

# implementation, restructure (1 of 1), implementation, restructure (over cap).
if [[ "$(cat "$COUNT_FILE")" -ne 4 ]]; then
  fail "Expected the run to stop on the second restructure, got $(cat "$COUNT_FILE") calls"
fi

grep -q 'Restructure 1 of 1 for this run' "$OUTPUT_FILE"
grep -q 'restructured the backlog 2 times in this run (limit 1)' "$OUTPUT_FILE"

echo "story unblock integration test: ok"
