#!/bin/bash

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-failure-diagnosis-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/calls"
ARGS_FILE="$TEST_ROOT/args"
OUTPUT_FILE="$TEST_ROOT/output"
PROMPTS_DIR="$TEST_ROOT/prompts"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FIXTURE_REPO" "$FAKE_BIN" "$PROMPTS_DIR"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$FIXTURE_REPO/ralph"

cat > "$FIXTURE_REPO/ralph/prd.json" <<'EOF'
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
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

printf '%s\n' "$*" >> "$FAKE_CODEX_ARGS_FILE"

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

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"
cat > "$FAKE_CODEX_PROMPTS_DIR/prompt-$call_count"

if [[ "$call_count" -eq 1 ]]; then
  message="Implementation stopped before the acceptance criteria passed."
else
  message=$(printf '%s\n' \
    'Story' \
    'US-001' \
    'What failed' \
    'The story remained passes=false.' \
    'Likely root cause' \
    'The implementation round did not update the story state (high confidence).' \
    'Evidence' \
    'The authoritative story JSON is still incomplete.' \
    'Recommended human action' \
    'Inspect the implementation round before rerunning.')
fi

printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Ralph Test"
git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "test fixture"

set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_COUNT_FILE="$COUNT_FILE" \
  FAKE_CODEX_ARGS_FILE="$ARGS_FILE" \
  FAKE_CODEX_PROMPTS_DIR="$PROMPTS_DIR" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
  > "$OUTPUT_FILE" 2>&1
run_status=$?
set -e

if [[ "$run_status" -ne 1 ]]; then
  echo "Expected Ralph to exit 1 after diagnosis, got $run_status" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  echo "Expected exactly one implementation call and one diagnosis call" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! sed -n '2p' "$ARGS_FILE" | grep -q -- '--sandbox read-only'; then
  echo "Expected the diagnosis call to use the Codex read-only sandbox" >&2
  cat "$ARGS_FILE" >&2
  exit 1
fi

if sed -n '2p' "$ARGS_FILE" | grep -q -- '--dangerously-bypass-approvals-and-sandbox'; then
  echo "Diagnosis call unexpectedly bypassed the sandbox" >&2
  cat "$ARGS_FILE" >&2
  exit 1
fi

grep -q 'Implementation stopped before the acceptance criteria passed.' "$PROMPTS_DIR/prompt-2"
grep -q 'A story that stays incomplete' "$PROMPTS_DIR/prompt-2"
grep -q 'Read-Only Contract' "$PROMPTS_DIR/prompt-2"

grep -q 'Ralph Failure Diagnosis Round' "$OUTPUT_FILE"
grep -q 'The story remained passes=false.' "$OUTPUT_FILE"
grep -q 'Ralph stopped after diagnosing US-001' "$OUTPUT_FILE"

if grep -q 'Ralph Round 2 ' "$OUTPUT_FILE"; then
  echo "Ralph incorrectly started a second implementation round" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ "$(jq -r '.passes' "$FIXTURE_REPO/ralph/stories/US-001.json")" != "false" ]]; then
  echo "The read-only diagnosis unexpectedly changed the story" >&2
  exit 1
fi

echo "failure diagnosis integration test: ok"
