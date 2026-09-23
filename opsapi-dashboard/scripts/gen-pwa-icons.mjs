// Generate PWA icons from public/opsapi-logo.svg.
// Run: node scripts/gen-pwa-icons.mjs  (sharp is already a dependency via Next)
// Regenerate whenever the brand mark changes.
import sharp from 'sharp';
import { readFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const svg = readFileSync(join(root, 'public/opsapi-logo.svg'));
const out = join(root, 'public/icons');
mkdirSync(out, { recursive: true });

const render = (size) => sharp(svg, { density: 384 }).resize(size, size).png();

// Full-bleed "any" icons (logo keeps its own rounded corners / transparency).
await render(192).toFile(join(out, 'icon-192.png'));
await render(512).toFile(join(out, 'icon-512.png'));

// Maskable + apple-touch need a solid background (no transparency) and safe-zone
// padding so the OS mask doesn't clip the mark.
const onWhite = async (canvas, logo, file) => {
  const mark = await sharp(svg, { density: 384 }).resize(logo, logo).png().toBuffer();
  await sharp({ create: { width: canvas, height: canvas, channels: 4, background: '#ffffff' } })
    .composite([{ input: mark, gravity: 'center' }])
    .png()
    .toFile(join(out, file));
};
await onWhite(512, 352, 'maskable-512.png'); // ~69% -> within the 80% safe zone
await onWhite(180, 148, 'apple-touch-icon.png');

console.log('PWA icons written to public/icons/');
