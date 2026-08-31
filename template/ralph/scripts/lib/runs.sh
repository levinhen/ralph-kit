#!/bin/bash

# run_prd_all_passed / run_merge_back_complete live in run-deps.sh so ralph.sh,
# archive-runs.sh, and lint-prd.sh all judge run completion the same way.
_RALPH_RUNS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RALPH_RUNS_LIB_DIR/run-context.sh"
source "$_RALPH_RUNS_LIB_DIR/run-deps.sh"

run_is_complete() {
  local run_dir="$1"
  local prd_file="$run_dir/prd.json"

  run_prd_all_passed "$prd_file" && run_merge_back_complete "$run_dir" "$REPO_ROOT"
}

# A run directory that exists, whether or not this invocation scheduled it.
# Separates "a run you left out of the selection" from "an id naming nothing".
run_dir_exists() {
  [[ -f "$RUNS_ROOT/$1/prd.json" ]]
}

any_run_exists() {
  [[ -d "$RUNS_ROOT" ]] \
    && find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type f -name prd.json -print -quit | grep -q .
}

discover_run_ids() {
  if [[ ! -d "$RUNS_ROOT" ]]; then
    return
  fi

  find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type f -name prd.json -print \
    | while IFS= read -r prd_file; do
      run_dir="$(dirname "$prd_file")"
      if ! run_is_complete "$run_dir"; then
        basename "$run_dir"
      fi
    done \
    | sort
}

print_noninteractive_run_error() {
  local has_legacy="$1"
  shift

  echo "Error: No Ralph run selected and stdin is not interactive."
  if [[ "$#" -gt 0 ]]; then
    echo "Available runs:"
    printf '  --run %s\n' "$@"
  fi
  if [[ "$has_legacy" == "true" ]]; then
    echo "Legacy root run:"
    echo "  --legacy"
  fi
}

select_ralph_run() {
  local runs=()
  local has_legacy="false"
  local option_count=0
  local choice
  local legacy_choice=0
  local index
  local discovered_run

  while IFS= read -r discovered_run; do
    runs+=("$discovered_run")
  done < <(discover_run_ids)

  if [[ -f "$ROOT_PRD_FILE" ]]; then
    has_legacy="true"
  fi

  if [[ "${#runs[@]}" -eq 0 && "$has_legacy" != "true" ]]; then
    if any_run_exists; then
      echo "Error: No incomplete Ralph runs found."
      echo "Completed runs are hidden from the default selector. Use --run <run_id> to rerun one explicitly."
    else
      echo "Error: No Ralph runs found."
      echo "Create a run at ralph/runs/<run_id>/prd.json, then rerun with --run <run_id>."
    fi
    exit 1
  fi

  if [[ ! -t 0 ]]; then
    print_noninteractive_run_error "$has_legacy" "${runs[@]}"
    exit 1
  fi

  echo "Select Ralph run:"
  for index in "${!runs[@]}"; do
    printf "  %d) %s\n" "$((index + 1))" "${runs[$index]}"
  done

  option_count="${#runs[@]}"
  if [[ "$has_legacy" == "true" ]]; then
    legacy_choice=$((option_count + 1))
    printf "  %d) legacy (%s)\n" "$legacy_choice" "$ROOT_PRD_FILE"
    option_count="$legacy_choice"
  fi

  while true; do
    read -r -p "Run number: " choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$option_count" ]]; then
      if [[ "$has_legacy" == "true" && "$choice" -eq "$legacy_choice" ]]; then
        USE_LEGACY="true"
        RUN_ID=""
      else
        RUN_ID="${runs[$((choice - 1))]}"
      fi
      return
    fi

    echo "Enter a number from 1 to $option_count."
  done
}
