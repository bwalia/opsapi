declare module 'bcrypt-pbkdf' {
  const bcryptPbkdf: {
    /** OpenBSD bcrypt_pbkdf: fills `key` from the passphrase and salt. @returns 0, or -1 on bad input */
    pbkdf(pass: Uint8Array, passlen: number, salt: Uint8Array, saltlen: number, key: Uint8Array, keylen: number,
      rounds: number): number;
  };
  export default bcryptPbkdf;
}
