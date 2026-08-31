#!/bin/bash

# Fan run lifecycle events out to their independent projections.
#
# run-status.sh persists a machine-readable snapshot and progress-bar.sh owns
# the optional interactive terminal row. Neither module knows about the other;
# ralph.sh and tools.sh speak only to this composition layer so adding or
# replacing an observer does not spread coordination logic across call sites.
# All projections are best-effort: reporting must never stop the run itself.

ralph_observers_start() {
  local status_dir="$1"
  local prd_file="$2"
  local run_id="$3"
  local tool="$4"
  local progress_label="${5:-}"

  # Preserve the historical startup order. The usage ledger is started by the
  # caller first because the progress ticker reads it; the terminal row then
  # comes up before the durable status file is published.
  ralph_progress_start "$prd_file" "$progress_label" || true
  ralph_status_start "$status_dir" "$prd_file" "$run_id" "$tool" || true
}

ralph_observers_update() {
  local phase="${1:-working}"
  local story_id="${2:-}"
  local round="${3:-0}"

  ralph_progress_update "$phase" "$story_id" "$round" || true
  ralph_status_update "$phase" "$story_id" "$round" || true
}

ralph_observers_activity() {
  local activity_file="${1:-}"

  ralph_progress_set_activity "$activity_file" || true
  ralph_status_set_activity "$activity_file" || true
}

ralph_observers_unblock() {
  ralph_status_unblock_outcome "${1:-}" || true
}

ralph_observers_finish() {
  ralph_status_finish "${1:-}" "${2:-}" || true
}

ralph_observers_stop() {
  ralph_progress_stop || true
}

ralph_observers_resize() {
  ralph_progress_resize || true
}
