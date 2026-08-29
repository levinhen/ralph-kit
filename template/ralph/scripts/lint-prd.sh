#!/bin/bash
# Lint a Ralph prd.json: story ids, `dependsOn` edges between stories, and
# `dependsOnRuns` references to other runs.
#
# Usage:
#   ./lint-prd.sh --run <run_id>       Lint ralph/runs/<run_id>/prd.json
#   ./lint-prd.sh <path/to/prd.json>   Lint the PRD file at that path
#   ./lint-prd.sh --all                Lint every ralph/runs/*/prd.json
#
# Prints `ERROR: <file>: <message>` once per problem and exits 1 if any file has
# one; otherwise prints `OK: <file>` per linted file and exits 0.

set -e

MODE=""
RUN_ID=""
PRD_PATH=""

set_mode() {
  local requested="$1"

  if [[ -n "$MODE" && "$MODE" != "$requested" ]]; then
    echo "Error: Choose one of --run <run_id>, <path/to/prd.json>, or --all." >&2
    exit 1
  fi

  MODE="$requested"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "Error: --run requires a run id." >&2
        exit 1
      fi
      set_mode "run"
      RUN_ID="$2"
      shift 2
      ;;
    --run=*)
      set_mode "run"
      RUN_ID="${1#*=}"
      if [[ -z "$RUN_ID" ]]; then
        echo "Error: --run requires a run id." >&2
        exit 1
      fi
      shift
      ;;
    --all)
      set_mode "all"
      shift
      ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Error: Unknown argument '$1'" >&2
      exit 1
      ;;
    *)
      if [[ -n "$PRD_PATH" ]]; then
        echo "Error: Lint one PRD path at a time." >&2
        exit 1
      fi
      set_mode "path"
      PRD_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Error: Nothing to lint." >&2
  echo "Usage: $0 --run <run_id> | <path/to/prd.json> | --all" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNS_ROOT="$RALPH_ROOT/runs"

source "$SCRIPT_DIR/lib/run-deps.sh"

# Structural checks that need nothing but the file itself. One message per line.
LINT_JQ="$(
  cat <<'JQ'
def reachability($adj; $nodes):
  reduce range(0; ($nodes | length)) as $_ ($adj;
    . as $cur
    | reduce $nodes[] as $k (.;
        .[$k] = ((($cur[$k] // []) + (($cur[$k] // []) | map($cur[.] // []) | add // [])) | unique)
      )
  );

(
  (
    if (has("dependsOnRuns") and ((.dependsOnRuns | type) != "array")) then
      "dependsOnRuns must be an array of run ids"
    else
      empty
    end
  ),
  (
    if (.dependsOnRuns | type) == "array" then
      (.dependsOnRuns[] | select(type != "string") | "dependsOnRuns entry \(tojson) is not a string")
    else
      empty
    end
  ),
  (
    if (.userStories | type) != "array" then
      "userStories must be an array"
    elif (.userStories | length) == 0 then
      "userStories must be a non-empty array"
    else
      .userStories as $stories
      | [$stories[] | .id] as $allIds
      | [$allIds[] | select(type == "string") | select(test("^[[:space:]]*$") | not)] as $ids
      | ([$stories[]
          | select((.id | type) == "string")
          | {key: .id,
             value: (if (.dependsOn | type) == "array"
                     then [.dependsOn[] | select(type == "string")]
                     else [] end)}
         ] | from_entries) as $adj
      | ($adj | keys) as $nodes
      | reachability($adj; $nodes) as $reach
      | (
          ($stories | to_entries[]
            | select(((.value.id | type) != "string") or (.value.id | test("^[[:space:]]*$")))
            | "userStories[\(.key)] has a missing or empty id"),
          ($ids | group_by(.) | map(select(length > 1)) | .[]
            | "duplicate story id '\(.[0])'"),
          ($stories[]
            | select(has("dependsOn") and ((.dependsOn | type) != "array"))
            | "story '\(.id // "?")' has a dependsOn that is not an array"),
          ($stories[] | . as $s
            | select((.dependsOn | type) == "array")
            | .dependsOn[] | select(type != "string")
            | "story '\($s.id // "?")' has a non-string dependsOn entry \(tojson)"),
          ($stories | to_entries[] | . as $e
            | select(($e.value.id | type) == "string")
            | select(($e.value.dependsOn | type) == "array")
            | $e.value.dependsOn[] | select(type == "string") | . as $dep
            | ($allIds | index($dep)) as $depIndex
            | if $dep == $e.value.id then
                "story '\($e.value.id)' dependsOn itself"
              elif $depIndex == null then
                "story '\($e.value.id)' dependsOn unknown story id '\($dep)'"
              elif $depIndex >= $e.key then
                "story '\($e.value.id)' at index \($e.key) dependsOn '\($dep)' at index \($depIndex); a dependency must come earlier in userStories because array order is execution order"
              else
                empty
              end),
          ([$nodes[] | . as $n | select((($reach[$n] // []) | index($n)) != null)] as $cyclic
            | [$cyclic[] | . as $n
               | [$cyclic[] | . as $m
                  | select(((($reach[$n] // []) | index($m)) != null)
                       and ((($reach[$m] // []) | index($n)) != null))]
                 | unique]
            | unique | .[]
            | "dependency cycle detected among story ids: \(join(", "))")
        )
    end
  )
)
JQ
)"

ERROR_COUNT=0
LINT_RUN_ID=""
LINT_RALPH_ROOT=""

report_error() {
  printf 'ERROR: %s: %s\n' "$1" "$2"
  ERROR_COUNT=$((ERROR_COUNT + 1))
}

# `dependsOnRuns` names sibling runs, so the checks that touch the filesystem
# need to know which ralph/ tree the file belongs to. Derive it from the path:
# ralph/runs/<run_id>/prd.json gives both the run id and the root; a legacy
# ralph/prd.json gives only the root; anything else gives neither, and those
# checks are skipped rather than guessed at.
infer_run_context() {
  local prd_file="$1"
  local prd_dir
  local parent_dir

  LINT_RUN_ID=""
  LINT_RALPH_ROOT=""

  prd_dir="$(cd "$(dirname "$prd_file")" 2>/dev/null && pwd || echo "")"
  if [[ -z "$prd_dir" ]]; then
    return
  fi

  parent_dir="$(dirname "$prd_dir")"

  if [[ "$(basename "$parent_dir")" == "runs" ]]; then
    LINT_RUN_ID="$(basename "$prd_dir")"
    LINT_RALPH_ROOT="$(dirname "$parent_dir")"
  elif [[ "$(basename "$prd_dir")" == "ralph" ]]; then
    LINT_RALPH_ROOT="$prd_dir"
  fi
}

lint_depends_on_runs() {
  local prd_file="$1"
  local entry

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue

    if [[ ! "$entry" =~ ^[A-Za-z0-9._-]+$ ]]; then
      report_error "$prd_file" "dependsOnRuns entry '$entry' must use only letters, numbers, dot, underscore, and dash"
      continue
    fi

    if [[ -n "$LINT_RUN_ID" && "$entry" == "$LINT_RUN_ID" ]]; then
      report_error "$prd_file" "dependsOnRuns must not reference its own run '$entry'"
      continue
    fi

    if [[ -z "$LINT_RALPH_ROOT" ]]; then
      continue
    fi

    if [[ ! -f "$LINT_RALPH_ROOT/runs/$entry/prd.json" ]] \
      && [[ -z "$(find_archived_run_dir "$LINT_RALPH_ROOT" "$entry")" ]]; then
      report_error "$prd_file" "dependsOnRuns references run '$entry', which has no runs/$entry/prd.json and no archived run directory under $LINT_RALPH_ROOT"
    fi
  done < <(jq -r '
    (.dependsOnRuns // [])
    | if type == "array" then .[] else empty end
    | select(type == "string")
  ' "$prd_file" 2>/dev/null || true)
}

lint_prd_file() {
  local prd_file="$1"
  local errors_before="$ERROR_COUNT"
  local message

  if ! jq -e . "$prd_file" >/dev/null 2>&1; then
    report_error "$prd_file" "not valid JSON"
    return
  fi

  if [[ "$(jq -r 'type' "$prd_file")" != "object" ]]; then
    report_error "$prd_file" "top-level JSON value must be an object"
    return
  fi

  while IFS= read -r message; do
    [[ -n "$message" ]] || continue
    report_error "$prd_file" "$message"
  done < <(jq -r "$LINT_JQ" "$prd_file")

  infer_run_context "$prd_file"
  lint_depends_on_runs "$prd_file"

  if [[ "$ERROR_COUNT" -eq "$errors_before" ]]; then
    printf 'OK: %s\n' "$prd_file"
  fi
}

PRD_FILES=()

case "$MODE" in
  run)
    if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "Error: Invalid run id '$RUN_ID'. Use only letters, numbers, dot, underscore, and dash." >&2
      exit 1
    fi
    if [[ ! -f "$RUNS_ROOT/$RUN_ID/prd.json" ]]; then
      echo "Error: Ralph run PRD not found: $RUNS_ROOT/$RUN_ID/prd.json" >&2
      exit 1
    fi
    PRD_FILES=("$RUNS_ROOT/$RUN_ID/prd.json")
    ;;
  path)
    if [[ ! -f "$PRD_PATH" ]]; then
      echo "Error: PRD file not found: $PRD_PATH" >&2
      exit 1
    fi
    PRD_FILES=("$PRD_PATH")
    ;;
  all)
    if [[ ! -d "$RUNS_ROOT" ]]; then
      echo "No Ralph runs directory found: $RUNS_ROOT"
      exit 0
    fi
    while IFS= read -r prd_file; do
      PRD_FILES+=("$prd_file")
    done < <(find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type f -name prd.json -print | sort)
    if [[ "${#PRD_FILES[@]}" -eq 0 ]]; then
      echo "No Ralph run PRD files found under: $RUNS_ROOT"
      exit 0
    fi
    ;;
esac

for prd_file in "${PRD_FILES[@]}"; do
  lint_prd_file "$prd_file"
done

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
