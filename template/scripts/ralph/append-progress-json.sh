#!/bin/bash
# Append a Ralph progress record + optional shared-memory items.
#
# Layout:
#   runs/<run_id>/progress/shared-memory.json   # JSON array, deduped
#   runs/<run_id>/progress/<story_id>.jsonl     # one JSON record per line, append-only
#
# Records are appended; the shared-memory file is rewritten with the merged
# unique union. The full progress files are never read into the agent prompt;
# `ralph.sh` slices them for context.

set -e

RUN_ID=""
USE_LEGACY="false"
STORY_ID=""
RECORD_FILE=""
SHARED_MEMORY_ITEMS=()

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
    --story)
      STORY_ID="$2"
      shift 2
      ;;
    --story=*)
      STORY_ID="${1#*=}"
      shift
      ;;
    --record)
      RECORD_FILE="$2"
      shift 2
      ;;
    --record=*)
      RECORD_FILE="${1#*=}"
      shift
      ;;
    --shared-memory)
      SHARED_MEMORY_ITEMS+=("$2")
      shift 2
      ;;
    --shared-memory=*)
      SHARED_MEMORY_ITEMS+=("${1#*=}")
      shift
      ;;
    *)
      echo "Usage: $0 (--run <run_id>|--legacy) --story <story_id> [--record record.json] [--shared-memory text]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$USE_LEGACY" == "true" && -n "$RUN_ID" ]]; then
  echo "Error: Use either --run <run_id> or --legacy, not both." >&2
  exit 1
fi

if [[ "$USE_LEGACY" != "true" && -z "$RUN_ID" ]]; then
  echo "Usage: $0 (--run <run_id>|--legacy) --story <story_id> [--record record.json] [--shared-memory text]" >&2
  exit 1
fi

if [[ -z "$STORY_ID" ]]; then
  echo "Error: Missing --story <story_id>." >&2
  exit 1
fi

if [[ -n "$RUN_ID" && ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: Invalid run id '$RUN_ID'." >&2
  exit 1
fi

if [[ ! "$STORY_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: Invalid story id '$STORY_ID'." >&2
  exit 1
fi

if [[ "$USE_LEGACY" == "true" ]]; then
  PROGRESS_DIR="$SCRIPT_DIR/progress"
else
  PROGRESS_DIR="$SCRIPT_DIR/runs/$RUN_ID/progress"
fi

SHARED_MEMORY_FILE="$PROGRESS_DIR/shared-memory.json"
STORY_JSONL_FILE="$PROGRESS_DIR/$STORY_ID.jsonl"

mkdir -p "$PROGRESS_DIR"
if [[ ! -f "$SHARED_MEMORY_FILE" ]]; then
  echo '[]' > "$SHARED_MEMORY_FILE"
fi

if [[ -n "$RECORD_FILE" ]]; then
  if [[ ! -f "$RECORD_FILE" ]]; then
    echo "Error: Missing progress record file: $RECORD_FILE" >&2
    exit 1
  fi
  if ! jq -e 'type == "object"' "$RECORD_FILE" >/dev/null; then
    echo "Error: Progress record must be a JSON object: $RECORD_FILE" >&2
    exit 1
  fi
  # Compact to one line, then append.
  jq -c . "$RECORD_FILE" >> "$STORY_JSONL_FILE"
  echo "Appended record to $STORY_JSONL_FILE"
fi

if [[ "${#SHARED_MEMORY_ITEMS[@]}" -gt 0 ]]; then
  memory_file=$(mktemp)
  temp_file=$(mktemp)

  printf '%s\n' "${SHARED_MEMORY_ITEMS[@]}" | jq -R -s '
    split("\n") | map(select(length > 0))
  ' > "$memory_file"

  jq \
    --slurpfile incoming "$memory_file" \
    '. + ($incoming[0] // []) | unique' \
    "$SHARED_MEMORY_FILE" > "$temp_file"

  mv "$temp_file" "$SHARED_MEMORY_FILE"
  rm -f "$memory_file"
  echo "Updated shared memory: $SHARED_MEMORY_FILE"
fi
