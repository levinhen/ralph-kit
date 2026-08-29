#!/bin/bash
#
# End-to-end check for `--tool pi`: the loop has to pick PI.md, run both the
# implementation round and the unblock round that follows it with project trust
# and the write tools intact, and price the run from pi's own reported cost
# instead of Ralph's rate table.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-pi-tool-test.XXXXXX")
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
  "project": "pi tool test",
  "branchName": "",
  "userStories": [
    {
      "id": "US-001",
      "title": "A story that stays incomplete",
      "description": "Exercise the pi entry point.",
      "acceptanceCriteria": ["The fake implementation would need to mark this story complete."],
      "passes": false,
      "notes": ""
    }
  ]
}
EOF

cat > "$FAKE_BIN/pi" <<'EOF'
#!/bin/bash

set -e

printf '%s\n' "$*" >> "$FAKE_PI_ARGS_FILE"

call_count=0
if [[ -f "$FAKE_PI_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_PI_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_PI_COUNT_FILE"
cat > "$FAKE_PI_PROMPTS_DIR/prompt-$call_count"

if [[ "$call_count" -eq 1 ]]; then
  message="Implementation stopped before the acceptance criteria passed."
else
  message=$(printf '%s\n' \
    'Verdict: blocked, and only a human can resolve it.' \
    'US-001 needs a product decision no round can make, so restructuring the split would not help.' \
    'Leaving US-001 at passes=false.')
fi

# pi repeats the same assistant message on message_end, turn_end and agent_end.
# Emitting all three is the point: Ralph must bill the round exactly once.
assistant=$(jq -nc --arg text "$message" '{
  role: "assistant",
  content: [{type: "text", text: $text}],
  provider: "openai-codex",
  model: "gpt-5.6-sol",
  usage: {
    input: 100,
    output: 20,
    cacheRead: 10,
    cacheWrite: 5,
    totalTokens: 135,
    cost: {input: 0.0005, output: 0.0006, cacheRead: 0, cacheWrite: 0, total: 0.0011}
  },
  stopReason: "stop"
}')

printf '%s\n' '{"type":"session","version":3,"id":"fake-pi-session","cwd":"."}'
printf '%s\n' '{"type":"agent_start"}'
printf '%s\n' '{"type":"turn_start"}'
jq -nc --argjson m "$assistant" '{type:"message_end",message:$m}'
jq -nc --argjson m "$assistant" '{type:"turn_end",message:$m,toolResults:[]}'
jq -nc --argjson m "$assistant" '{type:"agent_end",messages:[$m],willRetry:false}'
printf '%s\n' '{"type":"agent_settled"}'
EOF
chmod +x "$FAKE_BIN/pi"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Ralph Test"
git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "test fixture"

set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_PI_COUNT_FILE="$COUNT_FILE" \
  FAKE_PI_ARGS_FILE="$ARGS_FILE" \
  FAKE_PI_PROMPTS_DIR="$PROMPTS_DIR" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool pi 5 \
  > "$OUTPUT_FILE" 2>&1
run_status=$?
set -e

if [[ "$run_status" -ne 1 ]]; then
  echo "Expected Ralph to exit 1 after the unblock round, got $run_status" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ "$(cat "$COUNT_FILE")" -ne 2 ]]; then
  echo "Expected one implementation call and one unblock call" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! sed -n '1p' "$ARGS_FILE" | grep -q -- '--approve'; then
  echo "Expected the implementation call to trust project-local pi resources" >&2
  cat "$ARGS_FILE" >&2
  exit 1
fi

if sed -n '1p' "$ARGS_FILE" | grep -q -- '--exclude-tools'; then
  echo "Implementation call unexpectedly gave up the write tools" >&2
  cat "$ARGS_FILE" >&2
  exit 1
fi

# The unblock round is an ordinary write round, so it is invoked exactly like
# the implementation round it follows - write tools and project trust intact,
# nothing appended, nothing removed.
if [[ "$(sed -n '1p' "$ARGS_FILE")" != "$(sed -n '2p' "$ARGS_FILE")" ]]; then
  echo "Expected the unblock call to use the implementation round's pi arguments" >&2
  cat "$ARGS_FILE" >&2
  exit 1
fi

grep -q 'Ralph Agent Instructions For pi' "$PROMPTS_DIR/prompt-1"
grep -q 'Ralph Story Unblock Round' "$PROMPTS_DIR/prompt-2"
grep -q '## Story Unblock Context' "$PROMPTS_DIR/prompt-2"
grep -q 'Implementation stopped before the acceptance criteria passed.' "$PROMPTS_DIR/prompt-2"

grep -q 'Ralph Story Unblock Round (pi)' "$OUTPUT_FILE"
grep -q 'Verdict: blocked, and only a human can resolve it.' "$OUTPUT_FILE"
grep -q 'neither finished US-001 nor restructured the backlog around it' "$OUTPUT_FILE"

# 2 calls x (100 new + 10 cache read + 5 cache write + 20 output) tokens, and
# 2 x $0.0011 reported by pi rather than derived from RALPH_PRICE_*.
grep -q 'Model:         gpt-5.6-sol' "$OUTPUT_FILE"
grep -q 'Input:         200 (new) + 20 (cache read) + 10 (cache write)' "$OUTPUT_FILE"
grep -q 'Total tokens:  270' "$OUTPUT_FILE"
grep -q 'Cost:          \$<0.01 (reported by the tool)' "$OUTPUT_FILE"

if [[ "$(jq -r '.passes' "$FIXTURE_REPO/ralph/stories/US-001.json")" != "false" ]]; then
  echo "The unblock round should not have marked the story complete" >&2
  exit 1
fi

echo "pi tool integration test: ok"
