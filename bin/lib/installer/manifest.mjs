import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { MANIFEST_PATH_REL } from './constants.mjs';

export function writeManifest(target, version) {
  const manifestPath = join(target, MANIFEST_PATH_REL);
  mkdirSync(dirname(manifestPath), { recursive: true });
  const manifest = {
    version,
    installedAt: new Date().toISOString(),
    source: 'github:levinhen/ralph-kit',
  };
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  return manifestPath;
}

export function readManifest(target) {
  const manifestPath = join(target, MANIFEST_PATH_REL);
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
}
