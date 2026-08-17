#!/usr/bin/env node
// ralph-kit: install / sync the Ralph autonomous-agent loop into a target project.
// Forked from snarktank/ralph (MIT). See README.md for layout and safety guarantees.

import { readFileSync, writeFileSync, statSync, mkdirSync, readdirSync, copyFileSync, chmodSync, existsSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);
const PKG_ROOT   = resolve(__dirname, '..');
const TEMPLATE   = join(PKG_ROOT, 'template');
const PKG        = JSON.parse(readFileSync(join(PKG_ROOT, 'package.json'), 'utf8'));
const VERSION    = PKG.version;

const MANIFEST_PATH_REL = 'ralph/.ralph-kit.json';
const AGENTS_SNIPPET_NAME = 'AGENTS.snippet.md';
const AGENTS_BEGIN = '<!-- ralph-kit:begin -->';
const AGENTS_END   = '<!-- ralph-kit:end -->';

// Paths that the kit will NEVER touch in the target project, regardless of
// whether they appear in the template. These are project data / runtime state.
const PROTECTED_TARGET_PATHS = [
  'ralph/tasks',
  'ralph/runs',
  'ralph/archive',
  'ralph/locks',
  'ralph/progress',
  'ralph/stories',
  'ralph/prd.json',
  'ralph/progress.txt',
  'ralph/state.json',
  'ralph/.last-branch',
  'ralph/.merge-back-done',
];

const isWin = process.platform === 'win32';
const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const c = (code, s) => useColor ? `\x1b[${code}m${s}\x1b[0m` : s;
const green  = s => c('32', s);
const yellow = s => c('33', s);
const red    = s => c('31', s);
const dim    = s => c('2',  s);
const bold   = s => c('1',  s);

function die(msg) {
  console.error(red('error: ') + msg);
  process.exit(1);
}

function walkFiles(dir, base = dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(full, base));
    else if (entry.isFile()) out.push(relative(base, full).replaceAll('\\', '/'));
  }
  return out;
}

function sameBytes(a, b) {
  try {
    const sa = statSync(a), sb = statSync(b);
    if (sa.size !== sb.size) return false;
    return Buffer.compare(readFileSync(a), readFileSync(b)) === 0;
  } catch { return false; }
}

function ensureDir(p) { mkdirSync(p, { recursive: true }); }

function isProtected(relPath) {
  const norm = relPath.replaceAll('\\', '/');
  for (const p of PROTECTED_TARGET_PATHS) {
    if (norm === p || norm.startsWith(p + '/')) return true;
  }
  return false;
}

function writeManifest(target) {
  const manifestPath = join(target, MANIFEST_PATH_REL);
  ensureDir(dirname(manifestPath));
  const data = {
    version: VERSION,
    installedAt: new Date().toISOString(),
    source: 'github:levinhen/ralph-kit',
  };
  writeFileSync(manifestPath, JSON.stringify(data, null, 2) + '\n');
  return manifestPath;
}

function readManifest(target) {
  const p = join(target, MANIFEST_PATH_REL);
  if (!existsSync(p)) return null;
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch { return null; }
}

function copyOne(srcAbs, dstAbs) {
  ensureDir(dirname(dstAbs));
  copyFileSync(srcAbs, dstAbs);
  if (!isWin && dstAbs.endsWith('.sh')) {
    try { chmodSync(dstAbs, 0o755); } catch {}
  }
}

function renderAgentsSection() {
  return readFileSync(join(TEMPLATE, AGENTS_SNIPPET_NAME), 'utf8').trimEnd() + '\n';
}

// Insert/replace the ralph-kit section in an existing AGENTS.md.
// Returns { action: 'created' | 'updated' | 'inserted' | 'skipped-existing', changed: bool }
function handleAgentsMd(target, mode /* 'init' | 'sync' */) {
  const agentsPath = join(target, 'AGENTS.md');
  const section = renderAgentsSection();

  if (!existsSync(agentsPath)) {
    writeFileSync(agentsPath, '# AGENTS.md\n\n' + section);
    return { action: 'created', changed: true };
  }

  const cur = readFileSync(agentsPath, 'utf8');
  const hasMarkers = cur.includes(AGENTS_BEGIN) && cur.includes(AGENTS_END);

  if (hasMarkers) {
    const re = new RegExp(`${AGENTS_BEGIN}[\\s\\S]*?${AGENTS_END}\\n?`);
    const next = cur.replace(re, section.trimEnd() + '\n');
    if (next === cur) return { action: 'identical', changed: false };
    writeFileSync(agentsPath, next);
    return { action: 'updated', changed: true };
  }

  // No markers: user has a pre-existing AGENTS.md without ralph-kit content.
  if (mode === 'sync') {
    const next = cur.replace(/\s*$/, '') + '\n\n' + section;
    writeFileSync(agentsPath, next);
    return { action: 'inserted', changed: true };
  }

  // mode === 'init': do not silently append. Print the snippet for the user.
  return { action: 'skipped-existing', changed: false, snippet: section };
}

function planFiles(target) {
  // template paths to copy verbatim into target, except AGENTS.snippet.md
  // which is handled specially.
  return walkFiles(TEMPLATE).filter(p => p !== AGENTS_SNIPPET_NAME);
}

function summarize(counts) {
  const parts = [];
  if (counts.created)        parts.push(green(`${counts.created} created`));
  if (counts.updated)        parts.push(green(`${counts.updated} updated`));
  if (counts.identical)      parts.push(dim(`${counts.identical} unchanged`));
  if (counts.conflicts)      parts.push(yellow(`${counts.conflicts} conflict`));
  return parts.join(', ') || 'nothing to do';
}

// Commit only the files written by this invocation. Git is an optional
// checkpoint: a missing repository, missing identity, rejected hook, or any
// other Git failure must never make init/sync fail or print an error.
function tryCommitGeneratedFiles(target, generatedFiles, mode) {
  try {
    const probe = spawnSync('git', ['-C', target, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (probe.status !== 0) return;

    const reportedRepoRoot = probe.stdout.trim();
    if (!reportedRepoRoot) return;
    const repoRoot = realpathSync(reportedRepoRoot);

    const pathspecs = [...new Set(generatedFiles.map(file => relative(repoRoot, realpathSync(file))))]
      .filter(file => file && file !== '..' && !file.startsWith('../') &&
        !file.startsWith('..\\') && !isAbsolute(file));
    if (!pathspecs.length) return;

    const add = spawnSync('git', ['-C', repoRoot, 'add', '--force', '--', ...pathspecs], {
      stdio: 'ignore',
    });
    if (add.status !== 0) return;

    const diff = spawnSync('git', ['-C', repoRoot, 'diff', '--cached', '--quiet', '--', ...pathspecs], {
      stdio: 'ignore',
    });
    if (diff.status !== 1) return;

    const message = mode === 'init' ? 'chore: initialize ralph kit' : 'chore: sync ralph kit';
    spawnSync('git', ['-C', repoRoot, 'commit', '--only', '-m', message, '--', ...pathspecs], {
      stdio: 'ignore',
    });
  } catch {}
}

function cmdInit(target) {
  console.log(bold(`ralph-kit ${VERSION}`) + ` → init ${target}`);
  const files = planFiles(target);
  const counts = { created: 0, updated: 0, identical: 0, conflicts: 0 };
  const conflicts = [];
  const generatedFiles = [];

  for (const rel of files) {
    if (isProtected(rel)) continue;
    const src = join(TEMPLATE, rel);
    const dst = join(target, rel);
    if (!existsSync(dst)) {
      copyOne(src, dst);
      generatedFiles.push(dst);
      counts.created++;
      continue;
    }
    if (sameBytes(src, dst)) {
      counts.identical++;
      continue;
    }
    conflicts.push(rel);
    counts.conflicts++;
  }

  const agents = handleAgentsMd(target, 'init');
  if (agents.changed) generatedFiles.push(join(target, 'AGENTS.md'));
  if (agents.action === 'created')           counts.created++;
  else if (agents.action === 'updated')      counts.updated++;
  else if (agents.action === 'inserted')     counts.updated++;
  else if (agents.action === 'identical')    counts.identical++;

  generatedFiles.push(writeManifest(target));
  tryCommitGeneratedFiles(target, generatedFiles, 'init');

  console.log(summarize(counts));
  if (conflicts.length) {
    console.log('');
    console.log(yellow('Conflicting files (kept your version, did not overwrite):'));
    for (const f of conflicts) console.log('  ' + f);
    console.log(dim('  Run `ralph-kit sync` to replace them with the kit version.'));
  }
  if (agents.action === 'skipped-existing') {
    console.log('');
    console.log(yellow('AGENTS.md already exists in target — not modified.'));
    console.log(dim('Append the snippet below manually, or run `ralph-kit sync` to insert it for you:'));
    console.log('');
    console.log(agents.snippet);
  }
}

function cmdSync(target) {
  console.log(bold(`ralph-kit ${VERSION}`) + ` → sync ${target}`);
  const files = planFiles(target);
  const counts = { created: 0, updated: 0, identical: 0, conflicts: 0 };
  const generatedFiles = [];

  for (const rel of files) {
    if (isProtected(rel)) continue;
    const src = join(TEMPLATE, rel);
    const dst = join(target, rel);
    if (!existsSync(dst)) {
      copyOne(src, dst);
      generatedFiles.push(dst);
      counts.created++;
      continue;
    }
    if (sameBytes(src, dst)) {
      counts.identical++;
      continue;
    }
    // Differs — replace the target with the kit version.
    copyOne(src, dst);
    generatedFiles.push(dst);
    counts.updated++;
  }

  const agents = handleAgentsMd(target, 'sync');
  if (agents.changed) generatedFiles.push(join(target, 'AGENTS.md'));
  if (agents.action === 'created')        counts.created++;
  else if (agents.action === 'updated')   counts.updated++;
  else if (agents.action === 'inserted')  counts.updated++;
  else if (agents.action === 'identical') counts.identical++;

  generatedFiles.push(writeManifest(target));
  tryCommitGeneratedFiles(target, generatedFiles, 'sync');

  console.log(summarize(counts));
}

function cmdDoctor(target) {
  console.log(bold(`ralph-kit ${VERSION}`) + ` → doctor ${target}`);
  const manifest = readManifest(target);
  if (!manifest) {
    console.log(yellow('No ralph-kit manifest found — kit is not installed in this project.'));
    console.log(dim('Run `npx github:levinhen/ralph-kit init` first.'));
    return;
  }
  console.log(`installed:  ${manifest.version}  (at ${manifest.installedAt})`);
  console.log(`available:  ${VERSION}`);
  if (manifest.version !== VERSION) {
    console.log(yellow(`  → kit is out of date. Run \`ralph-kit sync\` to update.`));
  }

  const files = planFiles(target);
  const missing = [], drifted = [], identical = [];
  for (const rel of files) {
    if (isProtected(rel)) continue;
    const src = join(TEMPLATE, rel);
    const dst = join(target, rel);
    if (!existsSync(dst))      missing.push(rel);
    else if (!sameBytes(src, dst)) drifted.push(rel);
    else                       identical.push(rel);
  }

  console.log('');
  console.log(`${identical.length} files match the kit`);
  if (missing.length) {
    console.log(yellow(`${missing.length} files missing from project:`));
    for (const f of missing) console.log('  ' + f);
  }
  if (drifted.length) {
    console.log(yellow(`${drifted.length} files differ from the kit (local edits or stale version):`));
    for (const f of drifted) console.log('  ' + f);
    console.log(dim('  Run `ralph-kit sync` to replace them with the kit version.'));
  }
  if (!missing.length && !drifted.length) {
    console.log(green('clean — project matches the kit exactly.'));
  }
}

function printHelp() {
  console.log(`ralph-kit ${VERSION}
Install / sync the Ralph autonomous-agent loop into a project.

Usage:
  ralph-kit init    [target]   Install the kit into <target> (default: cwd).
                               Existing files are NEVER overwritten.
  ralph-kit sync    [target]   Update an installed kit, replacing locally-changed
                               managed files with the kit version.
  ralph-kit doctor  [target]   Report installed version, missing files, and
                               files that differ from the kit.

Protected paths (never touched by init or sync):
  ralph/tasks/, ralph/runs/, ralph/archive/, ralph/locks/, ralph/progress/,
  ralph/stories/, and these files at ralph/: prd.json, progress.txt,
  state.json, .last-branch, .merge-back-done.

Source: https://github.com/levinhen/ralph-kit
Derived from https://github.com/snarktank/ralph (MIT).
`);
}

function main() {
  const [cmd, rawTarget] = process.argv.slice(2);
  const target = resolve(rawTarget || process.cwd());

  if (!cmd || cmd === '--help' || cmd === '-h' || cmd === 'help') {
    printHelp();
    return;
  }
  if (!existsSync(target)) die(`target does not exist: ${target}`);
  if (!statSync(target).isDirectory()) die(`target is not a directory: ${target}`);

  switch (cmd) {
    case 'init':   cmdInit(target);   break;
    case 'sync':   cmdSync(target);   break;
    case 'doctor': cmdDoctor(target); break;
    default:
      console.error(red(`unknown command: ${cmd}`));
      printHelp();
      process.exit(2);
  }
}

main();
