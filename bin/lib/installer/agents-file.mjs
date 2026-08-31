import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  AGENTS_BEGIN,
  AGENTS_END,
  AGENTS_SNIPPET_NAME,
} from './constants.mjs';

function renderAgentsSection(templateRoot) {
  return readFileSync(join(templateRoot, AGENTS_SNIPPET_NAME), 'utf8').trimEnd() + '\n';
}

// The installer owns only the marker-delimited span. A markerless existing
// file is left alone by init and receives the section automatically on sync.
export function reconcileAgentsFile({ mode, target, templateRoot }) {
  const agentsPath = join(target, 'AGENTS.md');
  const section = renderAgentsSection(templateRoot);

  if (!existsSync(agentsPath)) {
    writeFileSync(agentsPath, '# AGENTS.md\n\n' + section);
    return { action: 'created', changed: true };
  }

  const current = readFileSync(agentsPath, 'utf8');
  const hasMarkers = current.includes(AGENTS_BEGIN) && current.includes(AGENTS_END);

  if (hasMarkers) {
    const managedSection = new RegExp(`${AGENTS_BEGIN}[\\s\\S]*?${AGENTS_END}\\n?`);
    const next = current.replace(managedSection, section.trimEnd() + '\n');
    if (next === current) return { action: 'identical', changed: false };
    writeFileSync(agentsPath, next);
    return { action: 'updated', changed: true };
  }

  if (mode === 'sync') {
    const next = current.replace(/\s*$/, '') + '\n\n' + section;
    writeFileSync(agentsPath, next);
    return { action: 'inserted', changed: true };
  }

  return { action: 'skipped-existing', changed: false, snippet: section };
}
