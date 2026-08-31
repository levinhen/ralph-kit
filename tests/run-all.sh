#!/usr/bin/env bash
# Run every repository gate and report all failures together. Individual tests
# remain directly runnable; this file is only the ordered top-level manifest.

set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

TESTS=(
  static-checks.sh
  architecture.sh
  installer.sh
  installer-git-checkpoint.sh
  run-context.sh
  tool-registry.sh
  playbook-render.sh
  run-observers.sh
  story-state-queries.sh
  phase-controller.sh
  story-unblock.sh
  scaffold-cleanup.sh
  run-status.sh
  pi-tool.sh
  pi-stream-extensions.sh
  story-budget.sh
  orchestrator-stage-gate.sh
  lint-prd.sh
  orchestrator-graph.sh
  orchestrator-selection.sh
  archive-collision.sh
  scoped-lifecycle.sh
  scoped-no-merge-lifecycle.sh
  package-smoke.sh
)

FAILURES=()

for test_name in "${TESTS[@]}"; do
  printf '\n==> %s\n' "$test_name"
  if bash "$REPO_ROOT/tests/$test_name"; then
    continue
  else
    status=$?
  fi
  FAILURES+=("$test_name:$status")
done

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  printf '\nFailed test gates:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s (exit %s)\n' "${failure%%:*}" "${failure#*:}" >&2
  done
  exit 1
fi

printf '\nAll %d test gates passed.\n' "${#TESTS[@]}"
