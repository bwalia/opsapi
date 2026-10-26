/**
 * An ed25519 SSH key pair made in this browser for a web terminal (docs/AI_RUNNER_WEB_TERMINAL.md §10). Only the
 * public half is sent to OpsAPI; the private key leaves the browser only as the file the manager saves. That file is
 * an OpenSSH private key locked with a passphrase (bcrypt KDF + aes256-ctr, exactly what `ssh-keygen -N` writes), so
 * `ssh-keygen -Y sign -f <file>` asks for the passphrase before it signs anything.
 * Check: node scripts/check-ssh-key.mts (round-trips a key through the real ssh-keygen).
 */
import nacl from 'tweetnacl';
import bcryptPbkdf from 'bcrypt-pbkdf';

const enc = new TextEncoder();
const ROUNDS = 16; // ssh-keygen's default
// No look-alikes (0/o, 1/l/i): it's read out or typed by hand.
const PASS_ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';

function u32(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n);
  return b;
}

function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** An SSH wire-format string: uint32 length + bytes. */
function sshString(data: Uint8Array | string): Uint8Array {
  const d = typeof data === 'string' ? enc.encode(data) : data;
  return concat(u32(d.length), d);
}

function base64(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

/** 6 groups of 4 letters/digits (~119 bits), e.g. "k7m3-x9q2-…". */
export function newPassphrase(): string {
  const out: string[] = [];
  while (out.length < 24) {
    for (const b of crypto.getRandomValues(new Uint8Array(32))) {
      // 248 = 8 × 31: drop the rest so every character is equally likely.
      if (b < 248 && out.length < 24) out.push(PASS_ALPHABET[b % PASS_ALPHABET.length]);
    }
  }
  return out.join('').match(/.{4}/g)!.join('-');
}

export interface TerminalKey {
  /** `ssh-ed25519 AAAA… comment` — the only part sent to OpsAPI. */
  publicKey: string;
  /** The passphrase-locked OpenSSH private key file. */
  privateKey: string;
  passphrase: string;
}

/** Make a key pair; `comment` names it inside the files (e.g. the person's email). */
export async function makeTerminalKey(comment: string, passphrase: string = newPassphrase()): Promise<TerminalKey> {
  const pair = nacl.sign.keyPair(); // secretKey = 32-byte seed + 32-byte public key, as OpenSSH stores it
  const pubBlob = concat(sshString('ssh-ed25519'), sshString(pair.publicKey));
  const check = crypto.getRandomValues(new Uint8Array(4));
  let secret = concat(check, check, sshString('ssh-ed25519'), sshString(pair.publicKey), sshString(pair.secretKey),
    sshString(comment));
  // Pad to the cipher's block size with 1, 2, 3, …
  secret = concat(secret, Uint8Array.from({ length: (16 - (secret.length % 16)) % 16 }, (_, i) => i + 1));

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const pass = enc.encode(passphrase);
  const derived = new Uint8Array(48); // aes-256 key + 16-byte counter
  if (bcryptPbkdf.pbkdf(pass, pass.length, salt, salt.length, derived, derived.length, ROUNDS) !== 0) {
    throw new Error('Could not lock the key with its passphrase');
  }
  const aes = await crypto.subtle.importKey('raw', derived.slice(0, 32), 'AES-CTR', false, ['encrypt']);
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-CTR', counter: derived.slice(32, 48), length: 128 }, aes, secret));
  pair.secretKey.fill(0);
  secret.fill(0);
  derived.fill(0);

  const file = concat(enc.encode('openssh-key-v1\0'), sshString('aes256-ctr'), sshString('bcrypt'),
    sshString(concat(sshString(salt), u32(ROUNDS))), u32(1), sshString(pubBlob), sshString(sealed));
  return {
    publicKey: `ssh-ed25519 ${base64(pubBlob)} ${comment}`,
    privateKey: `-----BEGIN OPENSSH PRIVATE KEY-----\n${base64(file).replace(/(.{70})/g, '$1\n').replace(/\n$/, '')}\n`
      + '-----END OPENSSH PRIVATE KEY-----\n',
    passphrase,
  };
}
