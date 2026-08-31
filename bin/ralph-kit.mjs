#!/usr/bin/env node
// ralph-kit: install / sync the Ralph autonomous-agent loop into a target project.
// Forked from snarktank/ralph (MIT). See README.md for layout and safety guarantees.

import { existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  PROTECTED_TARGET_PATHS,
  PROTECTED_TARGET_PREFIXES,
} from './lib/installer/constants.mjs';
import { VERSION } from './lib/installer/context.mjs';
import { doctorKit } from './lib/installer/doctor-use-case.mjs';
import { initKit, syncKit } from './lib/installer/install-use-case.mjs';
import { red } from './lib/installer/presentation.mjs';

function die(msg) {
  console.error(red('error: ') + msg);
  process.exit(1);
}

function printHelp() {
  const protectedPaths = [
    ...PROTECTED_TARGET_PATHS,
    ...PROTECTED_TARGET_PREFIXES.map(prefix => prefix + '*'),
  ].map(path => `  ${path}`).join('\n');

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
${protectedPaths}

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
    case 'init':   initKit(target);   break;
    case 'sync':   syncKit(target);   break;
    case 'doctor': doctorKit(target); break;
    default:
      console.error(red(`unknown command: ${cmd}`));
      printHelp();
      process.exit(2);
  }
}

main();
