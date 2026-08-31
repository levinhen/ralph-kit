import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
} from 'node:fs';
import { dirname, join, relative } from 'node:path';

import {
  AGENTS_SNIPPET_NAME,
  PROTECTED_TARGET_PATHS,
  PROTECTED_TARGET_PREFIXES,
} from './constants.mjs';

const isWindows = process.platform === 'win32';

function walkFiles(directory, base = directory) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...walkFiles(absolutePath, base));
    else if (entry.isFile()) {
      files.push(relative(base, absolutePath).replaceAll('\\', '/'));
    }
  }
  return files;
}

function sameBytes(left, right) {
  try {
    const leftStat = statSync(left);
    const rightStat = statSync(right);
    if (leftStat.size !== rightStat.size) return false;
    return Buffer.compare(readFileSync(left), readFileSync(right)) === 0;
  } catch {
    return false;
  }
}

export function isProtectedTargetPath(relativePath) {
  const normalized = relativePath.replaceAll('\\', '/');
  return PROTECTED_TARGET_PATHS.some(path =>
    normalized === path || normalized.startsWith(path + '/'))
    || PROTECTED_TARGET_PREFIXES.some(prefix => normalized.startsWith(prefix));
}

function copyManagedFile(source, destination) {
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(source, destination);
  if (!isWindows && destination.endsWith('.sh')) {
    try {
      chmodSync(destination, 0o755);
    } catch {}
  }
}

function targetPathsForSource(relativePath) {
  const targets = [relativePath];
  const agentsSkillPrefix = '.agents/skills/';

  // Skills have one canonical source under .agents/. Claude Code needs the
  // same bytes under .claude/, so the install plan projects that source to a
  // second destination instead of keeping two editable template copies.
  if (relativePath.startsWith(agentsSkillPrefix)) {
    targets.push('.claude/skills/' + relativePath.slice(agentsSkillPrefix.length));
  }

  return targets;
}

export function planManagedFiles(templateRoot) {
  const plan = [];

  for (const sourcePath of walkFiles(templateRoot)) {
    if (sourcePath === AGENTS_SNIPPET_NAME) continue;

    for (const targetPath of targetPathsForSource(sourcePath)) {
      if (!isProtectedTargetPath(targetPath)) plan.push({ sourcePath, targetPath });
    }
  }

  return plan;
}

// init and sync differ only when an existing managed file has drifted: init
// records a conflict, while sync copies the template over it.
export function reconcileManagedFiles({ mode, target, templateRoot }) {
  const counts = { created: 0, updated: 0, identical: 0, conflicts: 0 };
  const conflicts = [];
  const generatedFiles = [];

  for (const { sourcePath, targetPath } of planManagedFiles(templateRoot)) {
    const source = join(templateRoot, sourcePath);
    const destination = join(target, targetPath);

    if (!existsSync(destination)) {
      copyManagedFile(source, destination);
      generatedFiles.push(destination);
      counts.created++;
      continue;
    }

    if (sameBytes(source, destination)) {
      counts.identical++;
      continue;
    }

    if (mode === 'init') {
      conflicts.push(targetPath);
      counts.conflicts++;
      continue;
    }

    copyManagedFile(source, destination);
    generatedFiles.push(destination);
    counts.updated++;
  }

  return { conflicts, counts, generatedFiles };
}

export function inspectManagedFiles({ target, templateRoot }) {
  const result = { missing: [], drifted: [], identical: [] };

  for (const { sourcePath, targetPath } of planManagedFiles(templateRoot)) {
    const source = join(templateRoot, sourcePath);
    const destination = join(target, targetPath);
    if (!existsSync(destination)) result.missing.push(targetPath);
    else if (!sameBytes(source, destination)) result.drifted.push(targetPath);
    else result.identical.push(targetPath);
  }

  return result;
}
