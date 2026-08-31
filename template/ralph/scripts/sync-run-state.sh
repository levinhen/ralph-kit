#!/bin/bash
# Sync Ralph per-story state files back into the run PRD.

set -e

RUN_ID=""
USE_LEGACY="false"
USE_CURRENT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_ID="$2"
      shift 2
      ;;
    --run=*)
      RUN_ID="${1#*=}"
      shift
      ;;
    --legacy)
      USE_LEGACY="true"
      shift
      ;;
    --current)
      USE_CURRENT="true"
      shift
      ;;
    *)
      echo "Usage: $0 (--run <run_id>|--legacy|--current)" >&2
      exit 1
      ;;
  esac
done

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/run-context.sh"

if [[ "$USE_CURRENT" == "true" ]]; then
  if [[ -d "$ROOT_STORIES_DIR" && -f "$ROOT_PRD_FILE" ]]; then
    USE_LEGACY="true"
  else
    mapfile -t current_runs < <(
      find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type d -name stories 2>/dev/null \
        | sed "s|^$RUNS_ROOT/||; s|/stories$||" \
        | sort
    )
    if [[ "${#current_runs[@]}" -ne 1 ]]; then
      echo "Error: --current requires exactly one run with a stories directory. Use --run <run_id>." >&2
      exit 1
    fi
    RUN_ID="${current_runs[0]}"
  fi
fi

if [[ "$USE_LEGACY" == "true" && -n "$RUN_ID" ]]; then
  echo "Error: Use either --run <run_id> or --legacy, not both." >&2
  exit 1
fi

if [[ "$USE_LEGACY" != "true" && -z "$RUN_ID" ]]; then
  echo "Usage: $0 (--run <run_id>|--legacy|--current)" >&2
  exit 1
fi

if [[ -n "$RUN_ID" ]] && ! ralph_run_id_is_valid "$RUN_ID"; then
  ralph_print_invalid_run_id "$RUN_ID"
  exit 1
fi

if [[ "$USE_LEGACY" == "true" ]]; then
  ralph_context_set_root_paths "legacy" ""
else
  ralph_context_set_root_paths "scoped" "$RUN_ID"
fi
ralph_context_set_active_paths "$REPO_ROOT" "$RUN_MODE" "$RUN_ID"

if [[ ! -f "$PRD_FILE" ]]; then
  echo "Error: Missing Ralph PRD file: $PRD_FILE" >&2
  exit 1
fi

if [[ ! -d "$STORIES_DIR" ]]; then
  echo "Error: Missing Ralph stories directory: $STORIES_DIR" >&2
  exit 1
fi

source "$SCRIPT_DIR/lib/story-state.sh"

ensure_progress_dir
sync_story_files_to_prd

echo "Synced Ralph story files into $PRD_FILE"
