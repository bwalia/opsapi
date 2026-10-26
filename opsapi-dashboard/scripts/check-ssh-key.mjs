// Check lib/ssh-key.ts against the real ssh-keygen: the key it makes opens with its passphrase and gives the same
// public key, a wrong passphrase is refused, and it signs a sign-in challenge that verifies.
//   node scripts/check-ssh-key.mjs
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeTerminalKey } from '../lib/ssh-key.ts';

const dir = mkdtempSync(join(tmpdir(), 'ssh-key-check-'));
const run = (...args) => execFileSync('ssh-keygen', args, { stdio: 'pipe' }).toString().trim();
try {
  const k = await makeTerminalKey('priya@example.com');
  assert.match(k.passphrase, /^[a-z2-9]{4}(-[a-z2-9]{4}){5}$/);
  const file = join(dir, 'key');
  writeFileSync(file, k.privateKey, { mode: 0o600 });
  const pub = run('-y', '-P', k.passphrase, '-f', file);
  assert.equal(pub.split(' ').slice(0, 2).join(' '), k.publicKey.split(' ').slice(0, 2).join(' '));
  assert.throws(() => run('-y', '-P', 'not-the-passphrase', '-f', file));

  // -Y sign asks for the passphrase on a terminal, so sign with an unlocked copy.
  const open = join(dir, 'open');
  writeFileSync(open, k.privateKey, { mode: 0o600 });
  run('-p', '-P', k.passphrase, '-N', '', '-f', open);
  writeFileSync(join(dir, 'msg'), 'challenge');
  run('-Y', 'sign', '-n', 'sshweb-auth', '-f', open, join(dir, 'msg'));
  writeFileSync(join(dir, 'signers'), `priya ${k.publicKey}\n`);
  execFileSync('ssh-keygen', ['-Y', 'verify', '-f', join(dir, 'signers'), '-I', 'priya', '-n', 'sshweb-auth',
    '-s', join(dir, 'msg.sig')], { input: 'challenge', stdio: 'pipe' });
  console.log('ok: ssh-keygen opens the key with its passphrase, refuses a wrong one, and its signature verifies');
} finally {
  rmSync(dir, { recursive: true, force: true });
}
