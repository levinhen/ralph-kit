#!/bin/bash
#
# lint-prd.sh pins the shape of a run backlog: unique story ids, `dependsOn`
# edges that point backwards at real stories, no cycles, `dependsOnRuns`
# entries naming runs that exist, and a deps-audit.json that still describes the
# split beside it. ralph.sh lints the active PRD at startup and, for a scoped
# run, additionally refuses to start while a run it depends on has not landed on
# the base branch.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-lint-prd-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
RALPH_ROOT="$FIXTURE_REPO/ralph"
SCRIPTS_DIR="$RALPH_ROOT/scripts"
LINT="$SCRIPTS_DIR/lint-prd.sh"
SCRATCH="$TEST_ROOT/scratch"
FAKE_BIN="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/calls"
OUTPUT_FILE="$TEST_ROOT/output"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FIXTURE_REPO" "$SCRATCH" "$FAKE_BIN"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$RALPH_ROOT"

LINT_OUTPUT=""
LINT_STATUS=0

run_lint() {
  set +e
  LINT_OUTPUT="$(bash "$LINT" "$@" 2>&1)"
  LINT_STATUS=$?
  set -e
}

expect_lint_ok() {
  local label="$1"
  shift

  run_lint "$@"

  if [[ "$LINT_STATUS" -ne 0 ]]; then
    echo "$label: expected the lint to pass, got exit $LINT_STATUS" >&2
    printf '%s\n' "$LINT_OUTPUT" >&2
    exit 1
  fi

  if ! printf '%s\n' "$LINT_OUTPUT" | grep -q '^OK: '; then
    echo "$label: expected an OK line from a passing lint" >&2
    printf '%s\n' "$LINT_OUTPUT" >&2
    exit 1
  fi
}

expect_lint_error() {
  local label="$1"
  local pattern="$2"
  shift 2

  run_lint "$@"

  if [[ "$LINT_STATUS" -eq 0 ]]; then
    echo "$label: expected the lint to fail" >&2
    printf '%s\n' "$LINT_OUTPUT" >&2
    exit 1
  fi

  if ! printf '%s\n' "$LINT_OUTPUT" | grep -q "$pattern"; then
    echo "$label: expected an error matching '$pattern'" >&2
    printf '%s\n' "$LINT_OUTPUT" >&2
    exit 1
  fi
}

write_stories_prd() {
  local target="$1"
  local stories="$2"

  jq -n --argjson stories "$stories" '
    {
      project: "lint prd test",
      branchName: "",
      userStories: $stories
    }
  ' > "$target"
}

# --- Story-level dependsOn ----------------------------------------------------

write_stories_prd "$SCRATCH/clean.json" '[
  {"id": "US-001", "title": "First", "dependsOn": [], "passes": false},
  {"id": "US-002", "title": "Second", "dependsOn": ["US-001"], "passes": false}
]'
expect_lint_ok "clean prd" "$SCRATCH/clean.json"

# The shipped example is the template every generated PRD starts from.
expect_lint_ok "shipped example prd" "$SCRIPTS_DIR/prd.example.json"

write_stories_prd "$SCRATCH/dangling.json" '[
  {"id": "US-001", "title": "First", "passes": false},
  {"id": "US-002", "title": "Second", "dependsOn": ["US-404"], "passes": false}
]'
expect_lint_error "dangling dependsOn" \
  "dependsOn unknown story id 'US-404'" "$SCRATCH/dangling.json"

write_stories_prd "$SCRATCH/forward.json" '[
  {"id": "US-001", "title": "First", "dependsOn": ["US-002"], "passes": false},
  {"id": "US-002", "title": "Second", "passes": false}
]'
expect_lint_error "forward dependsOn" \
  "must come earlier in userStories" "$SCRATCH/forward.json"

write_stories_prd "$SCRATCH/self.json" '[
  {"id": "US-001", "title": "First", "dependsOn": ["US-001"], "passes": false}
]'
expect_lint_error "self dependsOn" \
  "story 'US-001' dependsOn itself" "$SCRATCH/self.json"

write_stories_prd "$SCRATCH/cycle.json" '[
  {"id": "US-001", "title": "First", "dependsOn": ["US-003"], "passes": false},
  {"id": "US-002", "title": "Second", "dependsOn": ["US-001"], "passes": false},
  {"id": "US-003", "title": "Third", "dependsOn": ["US-002"], "passes": false}
]'
expect_lint_error "dependency cycle" \
  "dependency cycle detected among story ids: US-001, US-002, US-003" \
  "$SCRATCH/cycle.json"

write_stories_prd "$SCRATCH/duplicate.json" '[
  {"id": "US-001", "title": "First", "passes": false},
  {"id": "US-001", "title": "Also first", "passes": false}
]'
expect_lint_error "duplicate story id" \
  "duplicate story id 'US-001'" "$SCRATCH/duplicate.json"

# --- Run-level dependsOnRuns --------------------------------------------------

new_run_prd() {
  local run_id="$1"
  local depends_on_runs="$2"

  mkdir -p "$RALPH_ROOT/runs/$run_id"
  jq -n --argjson dependsOnRuns "$depends_on_runs" '
    {
      project: "lint prd test",
      branchName: "",
      dependsOnRuns: $dependsOnRuns,
      userStories: [
        {
          id: "US-001",
          title: "A story",
          description: "Keeps the run incomplete.",
          acceptanceCriteria: ["Never satisfied in this test."],
          passes: false,
          notes: ""
        }
      ]
    }
  ' > "$RALPH_ROOT/runs/$run_id/prd.json"

  write_deps_audit "$run_id"
}

# A run-scoped PRD only lints once a dependency audit sits beside it. The
# single-story fixture above has one story and no edges, so its audit is fixed.
write_deps_audit() {
  local run_id="$1"

  jq -n --arg runId "$run_id" '
    {
      runId: $runId,
      storyOrder: ["US-001"],
      edges: {"US-001": []},
      coverage: "complete",
      findings: []
    }
  ' > "$RALPH_ROOT/runs/$run_id/deps-audit.json"
}

new_run_prd "needs-missing" '["ghost-run"]'
expect_lint_error "missing run dependency" \
  "dependsOnRuns references run 'ghost-run'" --run needs-missing

# Both archive layouts count as "this run already landed": the dated dir written
# by ralph.sh consolidation, and the batch dir written by archive-runs.sh.
mkdir -p "$RALPH_ROOT/archive/2024-01-01-archived-a"
mkdir -p "$RALPH_ROOT/archive/20240202-030405/archived-b"
new_run_prd "needs-archived" '["archived-a", "archived-b"]'
expect_lint_ok "archived run dependency" --run needs-archived

new_run_prd "needs-self" '["needs-self"]'
expect_lint_error "self run dependency" \
  "must not reference its own run 'needs-self'" --run needs-self

new_run_prd "needs-bad-charset" '["not a run id"]'
expect_lint_error "run id charset" \
  "must use only letters, numbers, dot, underscore, and dash" --run needs-bad-charset

# A bare path carries no run context, so only the charset check applies.
jq -n '{
  dependsOnRuns: ["ghost-run"],
  userStories: [{id: "US-001", title: "First", passes: false}]
}' > "$SCRATCH/bare-deps.json"
expect_lint_ok "bare path skips run existence" "$SCRATCH/bare-deps.json"

rm -rf "$RALPH_ROOT/runs/needs-missing" "$RALPH_ROOT/runs/needs-archived" \
  "$RALPH_ROOT/runs/needs-self" "$RALPH_ROOT/runs/needs-bad-charset"

# --- Dependency audit ---------------------------------------------------------

# A run-scoped PRD carries deps-audit.json: the record of a separate agent
# re-deriving the edges. Without it, or once it stops describing the split it
# audited, the run must not start.

audit_run_prd() {
  local run_id="$1"
  local stories="$2"

  mkdir -p "$RALPH_ROOT/runs/$run_id"
  jq -n --argjson stories "$stories" '
    {
      project: "audit test",
      branchName: "",
      dependsOnRuns: [],
      userStories: $stories
    }
  ' > "$RALPH_ROOT/runs/$run_id/prd.json"
}

audit_json() {
  cat > "$RALPH_ROOT/runs/audited/deps-audit.json"
}

audit_run_prd "audited" '[
  {"id": "US-001", "title": "Schema", "dependsOn": [], "passes": false},
  {"id": "US-002", "title": "Badge", "dependsOn": ["US-001"], "passes": false}
]'

expect_lint_error "missing deps audit" \
  "no deps-audit.json beside it" --run audited

# The gate exists for runs written after the audit landed; older runs opt out.
# Set and unset explicitly: a `VAR=1 func` prefix on a shell function has
# unspecified scope, and a leak would silently disable every case below.
export RALPH_SKIP_DEPS_AUDIT=1
expect_lint_ok "deps audit bypass" --run audited
unset RALPH_SKIP_DEPS_AUDIT

audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": ["US-001"]},
  "coverage": "complete",
  "findings": [
    {
      "kind": "missing-edge",
      "storyId": "US-002",
      "detail": "Observing the badge needs the column US-001 adds.",
      "resolution": "applied"
    }
  ]
}
JSON
expect_lint_ok "matching deps audit" --run audited

audit_json <<'JSON'
{
  "runId": "some-other-run",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": ["US-001"]},
  "coverage": "complete",
  "findings": []
}
JSON
expect_lint_error "audit run id mismatch" \
  "does not match the run directory 'audited'" --run audited

# The edge comparison is what makes the audit outlive nothing: editing a
# dependsOn after the audit ran invalidates it instead of passing unnoticed.
audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": []},
  "coverage": "complete",
  "findings": []
}
JSON
expect_lint_error "audit disagrees on an edge" \
  "edges\['US-002'\] is \[\] but prd.json's dependsOn is \[\"US-001\"\]" --run audited

audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001"],
  "edges": {"US-001": []},
  "coverage": "complete",
  "findings": []
}
JSON
expect_lint_error "audit predates a story" \
  "does not match prd.json's story order" --run audited

audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": ["US-001"]},
  "coverage": "gaps",
  "findings": []
}
JSON
expect_lint_error "audit reports an unresolved coverage gap" \
  'coverage is "gaps"; it must be "complete"' --run audited

audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": ["US-001"]},
  "coverage": "complete",
  "findings": [{"kind": "missing-edge", "storyId": "US-002", "detail": "Needs the column."}]
}
JSON
expect_lint_error "audit finding without a resolution" \
  'needs a resolution of "applied" or "rejected: <reason>"' --run audited

audit_json <<'JSON'
{
  "runId": "audited",
  "storyOrder": ["US-001", "US-002"],
  "edges": {"US-001": [], "US-002": ["US-001"]},
  "coverage": "complete",
  "findings": [{"kind": "looks-off", "detail": "Something.", "resolution": "applied"}]
}
JSON
expect_lint_error "audit finding with an unknown kind" \
  'has kind "looks-off"' --run audited

# A legacy ralph/prd.json has no run directory to hold an audit, so it is exempt
# — which is also what keeps the rest of the suite on the legacy path working.
jq -n '{
  userStories: [{id: "US-001", title: "First", passes: false}]
}' > "$RALPH_ROOT/prd.json"
expect_lint_ok "legacy prd needs no audit" "$RALPH_ROOT/prd.json"
rm -f "$RALPH_ROOT/prd.json"

rm -rf "$RALPH_ROOT/runs/audited"

# --- ralph.sh startup gate ----------------------------------------------------

# dep-run stays unfinished, so gated-run must not be allowed to start: its
# worktree would be cut from a base branch that has none of dep-run's work.
new_run_prd "dep-run" '[]'
new_run_prd "gated-run" '["dep-run"]'

cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

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

cat > /dev/null

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

for story_file in "$FAKE_CODEX_STORIES_DIR"/*.json; do
  [[ -f "$story_file" ]] || continue
  if [[ "$(jq -r '.passes' "$story_file")" != "true" ]]; then
    jq '.passes = true' "$story_file" > "$story_file.tmp"
    mv "$story_file.tmp" "$story_file"
    break
  fi
done

message="Completed one story."
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
  FAKE_CODEX_STORIES_DIR="$RALPH_ROOT/runs/gated-run/stories" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$SCRIPTS_DIR/ralph.sh" --run gated-run --tool codex \
  > "$OUTPUT_FILE" 2>&1
gated_status=$?
set -e

if [[ "$gated_status" -eq 0 ]]; then
  echo "Expected Ralph to refuse a run with an unmet run dependency" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! grep -q 'Error: Ralph run gated-run depends on runs that have not landed' "$OUTPUT_FILE"; then
  echo "Expected the unmet run dependency error" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! grep -q -- '- dep-run' "$OUTPUT_FILE"; then
  echo "Expected the unmet run dependency error to name dep-run" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ -f "$COUNT_FILE" ]]; then
  echo "Ralph invoked the agent despite the unmet run dependency" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

# RALPH_IGNORE_RUN_DEPS=1 downgrades the gate to a warning. The run then reaches
# its story round; it still ends non-zero because the wrap-up consolidation
# round never writes its marker, which is not what this case is about.
set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_COUNT_FILE="$COUNT_FILE" \
  FAKE_CODEX_STORIES_DIR="$RALPH_ROOT/runs/gated-run/stories" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  RALPH_IGNORE_RUN_DEPS=1 \
  RALPH_MAX_CONSOLIDATION_ROUNDS=1 \
  bash "$SCRIPTS_DIR/ralph.sh" --run gated-run --tool codex \
  > "$OUTPUT_FILE" 2>&1
set -e

if grep -q 'Error: Ralph run gated-run depends on runs that have not landed' "$OUTPUT_FILE"; then
  echo "RALPH_IGNORE_RUN_DEPS=1 did not bypass the run dependency gate" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! grep -q 'Starting anyway because RALPH_IGNORE_RUN_DEPS=1.' "$OUTPUT_FILE"; then
  echo "Expected a warning that the run dependency gate was bypassed" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ ! -f "$COUNT_FILE" ]]; then
  echo "Expected Ralph to reach a story round after bypassing the gate" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ "$(jq -r '.passes' "$RALPH_ROOT/runs/gated-run/stories/US-001.json")" != "true" ]]; then
  echo "Expected the bypassed run to actually work its story" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

# A PRD that cannot be executed is rejected at startup, before any story state.
jq '.userStories[0].dependsOn = ["US-404"]' "$RALPH_ROOT/runs/dep-run/prd.json" \
  > "$RALPH_ROOT/runs/dep-run/prd.json.tmp"
mv "$RALPH_ROOT/runs/dep-run/prd.json.tmp" "$RALPH_ROOT/runs/dep-run/prd.json"

set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_COUNT_FILE="$TEST_ROOT/unused-calls" \
  FAKE_CODEX_STORIES_DIR="$RALPH_ROOT/runs/dep-run/stories" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$SCRIPTS_DIR/ralph.sh" --run dep-run --tool codex \
  > "$OUTPUT_FILE" 2>&1
lint_gate_status=$?
set -e

if [[ "$lint_gate_status" -eq 0 ]]; then
  echo "Expected Ralph to refuse a PRD that fails the lint" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if ! grep -q "dependsOn unknown story id 'US-404'" "$OUTPUT_FILE"; then
  echo "Expected the startup lint to report the bad dependsOn edge" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ -d "$RALPH_ROOT/runs/dep-run/stories" ]]; then
  echo "Ralph derived story state from a PRD that failed the lint" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

echo "prd lint integration test: ok"
