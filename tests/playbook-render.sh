#!/usr/bin/env bash
# Common agent instructions live once under playbooks/ and are expanded into
# every tool-specific prompt before a round starts.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS_DIR="$REPO_ROOT/template/ralph/scripts"
PLAYBOOK_DIR="$SCRIPTS_DIR/playbooks"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-playbook-render.XXXXXX")

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

# shellcheck source=../template/ralph/scripts/lib/tools.sh
source "$SCRIPTS_DIR/lib/tools.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

for tool_prompt in CLAUDE.md CODEX.md PI.md; do
  rendered="$TEST_ROOT/$tool_prompt"
  render_tool_prompt "$SCRIPTS_DIR/$tool_prompt" "$rendered"

  if grep -q '<!-- ralph-include:' "$rendered"; then
    fail_test "$tool_prompt retained an unresolved Ralph include marker"
  fi

  for fragment in "$PLAYBOOK_DIR"/*.md; do
    node -e '
      const fs = require("node:fs");
      const rendered = fs.readFileSync(process.argv[1], "utf8");
      const fragment = fs.readFileSync(process.argv[2], "utf8");
      const occurrences = rendered.split(fragment).length - 1;
      if (occurrences !== 1) {
        console.error(`${process.argv[2]} occurs ${occurrences} times in ${process.argv[1]}`);
        process.exit(1);
      }
    ' "$rendered" "$fragment"
  done
done

printf '%s\n' '<!-- ralph-include:missing.md -->' > "$TEST_ROOT/missing.md"
if render_tool_prompt "$TEST_ROOT/missing.md" "$TEST_ROOT/missing-rendered.md" 2>/dev/null; then
  fail_test "A missing playbook fragment was accepted"
fi

printf '%s\n' '<!-- ralph-include:../escape.md -->' > "$TEST_ROOT/invalid.md"
if render_tool_prompt "$TEST_ROOT/invalid.md" "$TEST_ROOT/invalid-rendered.md" 2>/dev/null; then
  fail_test "A playbook include outside the fragment directory was accepted"
fi

echo "playbook render integration test: ok"
