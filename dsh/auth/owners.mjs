import { readFile } from 'node:fs/promises';

export async function readOwners(path = '/owner/emails') {
  // Reopen the path on every check: Kubernetes replaces ConfigMap symlink targets.
  const contents = await readFile(path, 'utf8');
  return new Set(contents.split(/\r?\n/).map(line => line.trim().toLowerCase())
    .filter(line => line && !line.startsWith('#')));
}
