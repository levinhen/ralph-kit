import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const moduleDir = dirname(fileURLToPath(import.meta.url));

export const PACKAGE_ROOT = resolve(moduleDir, '../../..');
export const TEMPLATE_ROOT = join(PACKAGE_ROOT, 'template');
export const VERSION = JSON.parse(
  readFileSync(join(PACKAGE_ROOT, 'package.json'), 'utf8'),
).version;
