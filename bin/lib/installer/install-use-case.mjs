import { join } from 'node:path';

import { reconcileAgentsFile } from './agents-file.mjs';
import { TEMPLATE_ROOT, VERSION } from './context.mjs';
import { commitGeneratedFiles } from './git-checkpoint.mjs';
import { writeManifest } from './manifest.mjs';
import { reconcileManagedFiles } from './managed-files.mjs';
import { bold, dim, summarizeChanges, yellow } from './presentation.mjs';

function countAgentsResult(counts, agents) {
  if (agents.action === 'created') counts.created++;
  else if (agents.action === 'updated' || agents.action === 'inserted') counts.updated++;
  else if (agents.action === 'identical') counts.identical++;
}

function printInitNotes(conflicts, agents) {
  if (conflicts.length) {
    console.log('');
    console.log(yellow('Conflicting files (kept your version, did not overwrite):'));
    for (const file of conflicts) console.log('  ' + file);
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

function applyKit(target, mode) {
  console.log(bold(`ralph-kit ${VERSION}`) + ` → ${mode} ${target}`);

  const { conflicts, counts, generatedFiles } = reconcileManagedFiles({
    mode,
    target,
    templateRoot: TEMPLATE_ROOT,
  });
  const agents = reconcileAgentsFile({ mode, target, templateRoot: TEMPLATE_ROOT });

  if (agents.changed) generatedFiles.push(join(target, 'AGENTS.md'));
  countAgentsResult(counts, agents);

  generatedFiles.push(writeManifest(target, VERSION));
  commitGeneratedFiles(target, generatedFiles, mode);

  console.log(summarizeChanges(counts));
  if (mode === 'init') printInitNotes(conflicts, agents);
}

export function initKit(target) {
  applyKit(target, 'init');
}

export function syncKit(target) {
  applyKit(target, 'sync');
}
