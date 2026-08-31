export const MANIFEST_PATH_REL = 'ralph/.ralph-kit.json';

export const AGENTS_SNIPPET_NAME = 'AGENTS.snippet.md';
export const AGENTS_BEGIN = '<!-- ralph-kit:begin -->';
export const AGENTS_END = '<!-- ralph-kit:end -->';

// Project data and runtime state are permanently outside installer ownership.
export const PROTECTED_TARGET_PATHS = Object.freeze([
  'ralph/tasks',
  'ralph/runs',
  'ralph/archive',
  'ralph/locks',
  'ralph/status',
  'ralph/progress',
  'ralph/stories',
  'ralph/prd.json',
  'ralph/progress.txt',
  'ralph/progress.json',
  'ralph/state.json',
  'ralph/.last-branch',
  'ralph/.merge-back-done',
  'ralph/.scaffold-cleanup-done',
]);

// Some runtime markers include a run id and therefore cannot be enumerated as
// exact paths. Keep their namespace outside installer ownership as well.
export const PROTECTED_TARGET_PREFIXES = Object.freeze([
  'ralph/.consolidation-done-',
]);
