#!/bin/bash

set -e

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGISTRY="$REPO_ROOT/template/ralph/scripts/lib/tool-registry.sh"

CLAUDE_PROMPT_FILE="/prompts/CLAUDE.md"
CODEX_PROMPT_FILE="/prompts/CODEX.md"
PI_PROMPT_FILE="/prompts/PI.md"

source "$REGISTRY"

for tool in claude codex pi; do
  ralph_tool_is_supported "$tool" || {
    echo "Registry rejected supported tool: $tool" >&2
    exit 1
  }
done

for tool in "" Claude gemini "../codex"; do
  if ralph_tool_is_supported "$tool"; then
    echo "Registry accepted unsupported tool: $tool" >&2
    exit 1
  fi
done

[[ "$(resolve_tool_prompt claude)" == "$CLAUDE_PROMPT_FILE" ]]
[[ "$(resolve_tool_prompt codex)" == "$CODEX_PROMPT_FILE" ]]
[[ "$(resolve_tool_prompt pi)" == "$PI_PROMPT_FILE" ]]

if VALIDATION_OUTPUT=$(ralph_tool_validate gemini 2>&1); then
  echo "Registry validation accepted an unsupported tool" >&2
  exit 1
fi
[[ "$VALIDATION_OUTPUT" == "Error: Invalid tool 'gemini'. Must be 'claude', 'codex', or 'pi'." ]]

echo "tool registry test: ok"
