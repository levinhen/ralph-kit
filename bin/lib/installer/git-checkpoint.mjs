import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  realpathSync,
  rmSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { isAbsolute, join, relative, resolve } from 'node:path';

// Git is an optional checkpoint. Any repository, identity, hook, or commit
// failure is intentionally silent and must never make installation fail.
export function commitGeneratedFiles(target, generatedFiles, mode) {
  let checkpointDir = '';
  let indexPath = '';
  let indexBackup = '';
  let indexExisted = false;
  let restoreIndex = false;

  try {
    const probe = spawnSync('git', ['-C', target, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (probe.status !== 0) return;

    const reportedRepoRoot = probe.stdout.trim();
    if (!reportedRepoRoot) return;
    const repoRoot = realpathSync(reportedRepoRoot);

    const indexProbe = spawnSync('git', ['-C', repoRoot, 'rev-parse', '--git-path', 'index'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (indexProbe.status !== 0 || !indexProbe.stdout.trim()) return;
    indexPath = indexProbe.stdout.trim();
    if (!isAbsolute(indexPath)) indexPath = resolve(repoRoot, indexPath);

    // Installation is allowed to proceed when this optional commit fails, but
    // it must not leave the caller's index altered. Snapshot the complete index
    // so pre-existing staged work (including on managed paths) is restored
    // exactly on every no-commit path.
    checkpointDir = mkdtempSync(join(tmpdir(), 'ralph-kit-index-'));
    indexBackup = join(checkpointDir, 'index');
    indexExisted = existsSync(indexPath);
    if (indexExisted) copyFileSync(indexPath, indexBackup);
    restoreIndex = true;

    const pathspecs = [...new Set(generatedFiles.map(file =>
      relative(repoRoot, realpathSync(file))))]
      .filter(file => file && file !== '..' && !file.startsWith('../') &&
        !file.startsWith('..\\') && !isAbsolute(file));
    if (!pathspecs.length) return;

    const add = spawnSync('git', ['-C', repoRoot, 'add', '--force', '--', ...pathspecs], {
      stdio: 'ignore',
    });
    if (add.status !== 0) return;

    const diff = spawnSync(
      'git',
      ['-C', repoRoot, 'diff', '--cached', '--quiet', '--', ...pathspecs],
      { stdio: 'ignore' },
    );
    if (diff.status !== 1) return;

    const message = mode === 'init'
      ? 'chore: initialize ralph kit'
      : 'chore: sync ralph kit';
    const commit = spawnSync(
      'git',
      ['-C', repoRoot, 'commit', '--only', '-m', message, '--', ...pathspecs],
      { stdio: 'ignore' },
    );
    if (commit.status === 0) restoreIndex = false;
  } catch {
    // Git checkpointing is best-effort; filesystem installation has already
    // succeeded. The finally block still restores any index snapshot.
  } finally {
    if (restoreIndex && indexPath) {
      try {
        if (indexExisted) copyFileSync(indexBackup, indexPath);
        else rmSync(indexPath, { force: true });
      } catch {}
    }
    if (checkpointDir) {
      try {
        rmSync(checkpointDir, { recursive: true, force: true });
      } catch {}
    }
  }
}
