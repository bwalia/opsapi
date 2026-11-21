// Render thumbnails from catalogue.json with thumbnail.html (1280×720 JPEG).
//
//   node make_thumbnail.mjs            → every video that has a "thumbnail" block
//   node make_thumbnail.mjs V10 V28    → just these
//
// The screenshot inside the thumbnail ("shot") is a PNG path relative to
// devops/daybook-videos/, e.g. "thumbs/shots/V10.png" — take it from the edited video:
//   ffmpeg -ss 00:00:42 -i out/V10/V10.mp4 -frames:v 1 ../thumbs/shots/V10.png
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const cat = JSON.parse(fs.readFileSync(path.join(root, 'catalogue.json'), 'utf8'));
const want = process.argv.slice(2);
const list = cat.videos.filter((v) => v.thumbnail && (!want.length || want.includes(v.id)));

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
fs.mkdirSync(path.join(root, 'thumbs'), { recursive: true });
for (const v of list) {
  const t = v.thumbnail;
  const q = new URLSearchParams({ id: v.id, title: t.title || v.title, eyebrow: t.eyebrow || '', hl: t.hl || '',
    sub: t.sub || '', chips: (t.chips || []).join('|'), badge: t.badge || '', badgeSmall: t.badgeSmall || '' });
  const shot = path.join(root, t.shot || `thumbs/shots/${v.id}.png`);
  if (fs.existsSync(shot)) q.set('shot', pathToFileURL(shot).href);
  await page.goto(pathToFileURL(path.join(here, 'thumbnail.html')).href + '?' + q.toString());
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.evaluate(() => document.fonts.ready);
  const out = path.join(root, 'thumbs', `${v.id}-${v.slug}.jpg`);
  await page.screenshot({ path: out, type: 'jpeg', quality: 88 });
  console.log('wrote', path.relative(root, out));
}
await browser.close();
