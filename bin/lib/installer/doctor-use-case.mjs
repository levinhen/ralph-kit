import { TEMPLATE_ROOT, VERSION } from './context.mjs';
import { readManifest } from './manifest.mjs';
import { inspectManagedFiles } from './managed-files.mjs';
import { bold, dim, green, yellow } from './presentation.mjs';

export function doctorKit(target) {
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
    console.log(yellow('  → kit is out of date. Run `ralph-kit sync` to update.'));
  }

  const { missing, drifted, identical } = inspectManagedFiles({
    target,
    templateRoot: TEMPLATE_ROOT,
  });

  console.log('');
  console.log(`${identical.length} files match the kit`);
  if (missing.length) {
    console.log(yellow(`${missing.length} files missing from project:`));
    for (const file of missing) console.log('  ' + file);
  }
  if (drifted.length) {
    console.log(yellow(`${drifted.length} files differ from the kit (local edits or stale version):`));
    for (const file of drifted) console.log('  ' + file);
    console.log(dim('  Run `ralph-kit sync` to replace them with the kit version.'));
  }
  if (!missing.length && !drifted.length) {
    console.log(green('clean — project matches the kit exactly.'));
  }
}
