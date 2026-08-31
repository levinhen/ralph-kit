#!/bin/bash
#
# installer.sh characterizes the public init/sync/doctor contract. The target
# is deliberately not a Git repository so optional installer commits cannot
# hide or alter the filesystem behavior under test.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/bin/ralph-kit.mjs"
TEMPLATE="$REPO_ROOT/template"
AGENTS_SNIPPET="$TEMPLATE/AGENTS.snippet.md"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ralph-installer-test.XXXXXX")"
TARGET="$TEST_ROOT/target"
PROTECTED_SNAPSHOT="$TEST_ROOT/protected-before"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  printf 'installer test failed: %s\n' "$*" >&2
  exit 1
}

run_kit() {
  local command_name="$1"

  set +e
  KIT_OUTPUT="$(NO_COLOR=1 node "$INSTALLER" "$command_name" "$TARGET" 2>&1)"
  KIT_STATUS=$?
  set -e

  if [[ "$KIT_STATUS" -ne 0 ]]; then
    printf '%s\n' "$KIT_OUTPUT" >&2
    fail "ralph-kit $command_name exited with status $KIT_STATUS"
  fi
}

assert_output_contains() {
  local expected="$1"

  if [[ "$KIT_OUTPUT" != *"$expected"* ]]; then
    printf '%s\n' "$KIT_OUTPUT" >&2
    fail "output did not contain: $expected"
  fi
}

assert_same_file() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [[ -f "$actual" ]] || fail "$label is missing: $actual"
  if ! cmp -s "$expected" "$actual"; then
    printf '%s\n' "$label differs:" >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
  fi
}

json_version() {
  node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(value.version);
  ' "$1"
}

assert_manifest_version() {
  local actual

  [[ -f "$TARGET/ralph/.ralph-kit.json" ]] || fail "manifest was not created"
  actual="$(json_version "$TARGET/ralph/.ralph-kit.json")"
  [[ "$actual" == "$PACKAGE_VERSION" ]] || \
    fail "manifest version was '$actual', expected '$PACKAGE_VERSION'"
}

PROTECTED_FILES=(
  "ralph/tasks/product.md"
  "ralph/runs/run-a/prd.json"
  "ralph/archive/archive-a/state.txt"
  "ralph/locks/run-a/owner"
  "ralph/status/run-a.json"
  "ralph/progress/events.jsonl"
  "ralph/stories/US-001.json"
  "ralph/prd.json"
  "ralph/progress.txt"
  "ralph/progress.json"
  "ralph/state.json"
  "ralph/.last-branch"
  "ralph/.merge-back-done"
  "ralph/.scaffold-cleanup-done"
  "ralph/.consolidation-done-run-a"
)

seed_protected_files() {
  local rel

  for rel in "${PROTECTED_FILES[@]}"; do
    mkdir -p "$(dirname "$TARGET/$rel")" "$(dirname "$PROTECTED_SNAPSHOT/$rel")"
    printf 'project-owned sentinel for %s\n' "$rel" > "$TARGET/$rel"
    cp "$TARGET/$rel" "$PROTECTED_SNAPSHOT/$rel"
  done
}

assert_protected_files_unchanged() {
  local rel

  for rel in "${PROTECTED_FILES[@]}"; do
    assert_same_file "$PROTECTED_SNAPSHOT/$rel" "$TARGET/$rel" \
      "protected path $rel"
  done
}

command -v node >/dev/null 2>&1 || fail "node is required"
mkdir -p "$TARGET" "$PROTECTED_SNAPSHOT"

# The managed-file planner itself must reject runtime namespaces. Merely
# keeping extra target files is not enough: a future template file under one of
# these paths must never become installer-owned.
node --input-type=module - "$REPO_ROOT/bin/lib/installer/managed-files.mjs" <<'NODE'
import { pathToFileURL } from 'node:url';

const moduleUrl = pathToFileURL(process.argv[2]).href;
const { isProtectedTargetPath } = await import(moduleUrl);
const protectedPaths = [
  'ralph/status/run-a.json',
  'ralph/runs/run-a/prd.json',
  'ralph/progress.json',
  'ralph/.scaffold-cleanup-done',
  'ralph/.consolidation-done-run-a',
];
for (const path of protectedPaths) {
  if (!isProtectedTargetPath(path)) {
    throw new Error(`runtime path was not protected: ${path}`);
  }
}
if (isProtectedTargetPath('ralph/scripts/ralph.sh')) {
  throw new Error('managed script was classified as protected');
}
NODE

PACKAGE_VERSION="$(json_version "$REPO_ROOT/package.json")"
RENDERED_AGENTS_SNIPPET="$(<"$AGENTS_SNIPPET")"

seed_protected_files

# init preserves both ordinary managed-file conflicts and a pre-existing
# markerless AGENTS.md. It still installs every absent template file.
printf '# Project instructions\n\nKeep this user-owned line.\n' > "$TARGET/AGENTS.md"
cp "$TARGET/AGENTS.md" "$TEST_ROOT/agents-before-init.md"

mkdir -p "$TARGET/ralph/scripts"
printf '#!/bin/bash\nprintf "project-owned conflict\\n"\n' \
  > "$TARGET/ralph/scripts/ralph.sh"
chmod 0600 "$TARGET/ralph/scripts/ralph.sh"
cp "$TARGET/ralph/scripts/ralph.sh" "$TEST_ROOT/ralph-before-init.sh"

run_kit init
assert_output_contains "ralph/scripts/ralph.sh"
assert_output_contains "AGENTS.md already exists in target"
assert_same_file "$TEST_ROOT/ralph-before-init.sh" \
  "$TARGET/ralph/scripts/ralph.sh" "init conflict"
assert_same_file "$TEST_ROOT/agents-before-init.md" \
  "$TARGET/AGENTS.md" "markerless AGENTS.md after init"
assert_manifest_version
assert_protected_files_unchanged

[[ -x "$TARGET/ralph/scripts/orchestrate.sh" ]] || \
  fail "newly installed shell scripts should be executable"

# doctor exposes the conflict that init retained.
run_kit doctor
assert_output_contains "files differ from the kit"
assert_output_contains "ralph/scripts/ralph.sh"

# sync replaces managed drift, restores executable mode through copyOne, and
# appends exactly one canonical managed section to markerless AGENTS.md.
run_kit sync
assert_same_file "$TEMPLATE/ralph/scripts/ralph.sh" \
  "$TARGET/ralph/scripts/ralph.sh" "ralph.sh after sync"
assert_same_file "$TEMPLATE/.agents/skills/prd/SKILL.md" \
  "$TARGET/.agents/skills/prd/SKILL.md" "canonical .agents PRD Skill"
assert_same_file "$TEMPLATE/.agents/skills/prd/SKILL.md" \
  "$TARGET/.claude/skills/prd/SKILL.md" "projected .claude PRD Skill"
assert_same_file "$TEMPLATE/.agents/skills/ralph/SKILL.md" \
  "$TARGET/.agents/skills/ralph/SKILL.md" "canonical .agents Ralph Skill"
assert_same_file "$TEMPLATE/.agents/skills/ralph/SKILL.md" \
  "$TARGET/.claude/skills/ralph/SKILL.md" "projected .claude Ralph Skill"
[[ -x "$TARGET/ralph/scripts/ralph.sh" ]] || \
  fail "a synced shell script should be executable"

printf '# Project instructions\n\nKeep this user-owned line.\n\n%s\n' \
  "$RENDERED_AGENTS_SNIPPET" > "$TEST_ROOT/agents-after-insert.md"
assert_same_file "$TEST_ROOT/agents-after-insert.md" \
  "$TARGET/AGENTS.md" "AGENTS.md inserted section"
assert_manifest_version
assert_protected_files_unchanged

# With markers already present, sync replaces only the managed span and keeps
# project-owned material on both sides byte-for-byte.
{
  printf '# Project instructions\n\nKeep this user-owned line.\n'
  printf '%s\n' '<!-- ralph-kit:begin -->'
  printf 'stale managed content\n'
  printf '%s\n' '<!-- ralph-kit:end -->'
  printf '\n# Project tail\n\nKeep this tail, too.\n'
} > "$TARGET/AGENTS.md"

printf '# Project instructions\n\nKeep this user-owned line.\n%s\n\n# Project tail\n\nKeep this tail, too.\n' \
  "$RENDERED_AGENTS_SNIPPET" > "$TEST_ROOT/agents-after-replace.md"

run_kit sync
assert_same_file "$TEST_ROOT/agents-after-replace.md" \
  "$TARGET/AGENTS.md" "AGENTS.md replaced section"
assert_protected_files_unchanged

# doctor reports both version skew and byte-level missing/drifted files. sync
# then repairs both conditions and rewrites the manifest to this package.
printf 'locally edited prompt\n' > "$TARGET/ralph/scripts/CODEX.md"
rm "$TARGET/ralph/scripts/PI.md"
printf '{"version":"0.0.0-characterization","installedAt":"2000-01-01T00:00:00.000Z","source":"test"}\n' \
  > "$TARGET/ralph/.ralph-kit.json"

run_kit doctor
assert_output_contains "installed:  0.0.0-characterization"
assert_output_contains "available:  $PACKAGE_VERSION"
assert_output_contains "kit is out of date"
assert_output_contains "files missing from project"
assert_output_contains "ralph/scripts/PI.md"
assert_output_contains "files differ from the kit"
assert_output_contains "ralph/scripts/CODEX.md"

run_kit sync
assert_same_file "$TEMPLATE/ralph/scripts/CODEX.md" \
  "$TARGET/ralph/scripts/CODEX.md" "drifted prompt after sync"
assert_same_file "$TEMPLATE/ralph/scripts/PI.md" \
  "$TARGET/ralph/scripts/PI.md" "missing prompt after sync"
assert_same_file "$TEST_ROOT/agents-after-replace.md" \
  "$TARGET/AGENTS.md" "AGENTS.md after unrelated sync"
assert_manifest_version
assert_protected_files_unchanged

# Every shipped shell script is made executable in the target even though the
# source template itself need not carry executable mode in the npm package.
SHELL_SCRIPT_COUNT=0
while IFS= read -r source_file; do
  rel="${source_file#"$TEMPLATE/"}"
  [[ -x "$TARGET/$rel" ]] || fail "installed script is not executable: $rel"
  SHELL_SCRIPT_COUNT=$((SHELL_SCRIPT_COUNT + 1))
done < <(find "$TEMPLATE" -type f -name '*.sh' -print)
[[ "$SHELL_SCRIPT_COUNT" -gt 0 ]] || fail "template contained no shell scripts"

run_kit doctor
assert_output_contains "clean — project matches the kit exactly."

printf 'installer tests passed\n'
