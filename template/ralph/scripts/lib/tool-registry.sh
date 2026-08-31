#!/bin/bash

# Supported agent identities and their playbook mapping. Invocation details
# remain in tools.sh because each CLI has a different argument protocol, but
# entrypoints should never duplicate the supported-name list or prompt mapping.

if [[ "${RALPH_TOOL_REGISTRY_LOADED:-}" == "true" ]] \
  && type ralph_tool_is_supported >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
RALPH_TOOL_REGISTRY_LOADED="true"

ralph_tool_is_supported() {
  case "${1:-}" in
    claude | codex | pi) return 0 ;;
  esac
  return 1
}

ralph_tool_validate() {
  local tool="${1:-}"

  if ralph_tool_is_supported "$tool"; then
    return 0
  fi
  echo "Error: Invalid tool '$tool'. Must be 'claude', 'codex', or 'pi'."
  return 1
}

resolve_tool_prompt() {
  case "${1:-${TOOL:-}}" in
    claude) echo "$CLAUDE_PROMPT_FILE" ;;
    codex) echo "$CODEX_PROMPT_FILE" ;;
    pi) echo "$PI_PROMPT_FILE" ;;
    *) return 1 ;;
  esac
}
