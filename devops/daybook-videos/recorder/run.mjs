// Record one Daybook video from a scene file.
//
//   REC_SECRETS=/private/folder node run.mjs ../scenes/V10.json [--dry] [--from s3] [--only s3]
//
// Env:
//   REC_SECRETS   folder with accounts.json (recording logins) and statements/<client>/*
//   BASE          dashboard URL  (default https://demo.daybook.co.uk)
//   API           API URL        (default https://demo-api.daybook.co.uk)
//   OUT           output root    (default ./out)
//
// Writes out/<id>/raw.webm, segments.json, captions.json, timeline.json. Then:
//   python3 -I edit.py out/<id>             → <id>.mp4 + <id>.vtt (+ voice if rendered)
//
// --dry validates the scene file and prints the plan without opening a browser.
import fs from 'fs';
import path from 'path';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const flag = (n) => args.includes(n);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };
if (!file) { console.error('usage: node run.mjs <scene.json> [--dry] [--from <sceneId>] [--only <sceneId>]'); process.exit(2); }

const scene = JSON.parse(fs.readFileSync(file, 'utf8'));
const BASE = process.env.BASE || scene.base || 'https://demo.daybook.co.uk';
const API = process.env.API || scene.api || 'https://demo-api.daybook.co.uk';
const OUT = path.join(process.env.OUT || 'out', scene.id);

const ACTIONS = new Set(['goto', 'nav', 'click', 'fill', 'type', 'select', 'check', 'press', 'hover', 'scroll',
  'wait', 'waitFor', 'upload', 'slow', 'cutStart', 'cutEnd', 'highlight', 'caption', 'workspace', 'signIn',
  'reload', 'viewport']);

function validate(s) {
  const errs = [];
  if (!s.id || !/^V\d{2,3}[a-z]?$/.test(s.id)) errs.push('id must look like V10');
  if (!s.login) errs.push('login (account key in accounts.json) is required');
  if (s.login === 'demo') errs.push('never record with the published read-only demo login');
  if (!Array.isArray(s.scenes) || !s.scenes.length) errs.push('scenes[] is empty');
  const ids = new Set();
  for (const [i, sc] of (s.scenes || []).entries()) {
    if (!sc.id) errs.push(`scene ${i}: id missing`);
    if (ids.has(sc.id)) errs.push(`scene ${sc.id}: duplicate id`);
    ids.add(sc.id);
    if (typeof sc.duration !== 'number') errs.push(`scene ${sc.id}: duration (s) missing`);
    if (typeof sc.caption !== 'string') errs.push(`scene ${sc.id}: caption missing`);
    if (typeof sc.voice !== 'string') errs.push(`scene ${sc.id}: voice missing`);
    for (const a of sc.actions || []) if (!ACTIONS.has(a.do)) errs.push(`scene ${sc.id}: unknown action ${a.do}`);
  }
  return errs;
}

const errs = validate(scene);
if (errs.length) { console.error(errs.map((e) => '✗ ' + e).join('\n')); process.exit(1); }
if (flag('--dry')) {
  let t = 0;
  for (const sc of scene.scenes) {
    console.log(`${String(t).padStart(4)}s  ${sc.id.padEnd(4)} ${String(sc.duration).padStart(3)}s  ${sc.caption}`);
    t += sc.duration;
  }
  console.log(`total ≈ ${t}s (target ${scene.targetLength || '?'}), ${scene.scenes.length} scenes, login ${scene.login}`);
  process.exit(0);
}

// Loaded only now, so --dry works without Playwright installed.
const {
  loadAccounts, startRecorder, caption, slow, cutBegin, cutEnd, typeSlowly, signIn,
  refreshToken, locate, highlight, glide, finish,
} = await import('./lib.mjs');
const accounts = loadAccounts();
const account = accounts[scene.login];
if (!account) throw new Error(`accounts.json has no "${scene.login}"`);
const statementsDir = path.join(process.env.REC_SECRETS, 'statements');

const rec = await startRecorder({ outDir: OUT, viewport: scene.viewport, mobile: !!scene.mobile });
const p = rec.page;
let lastRefresh = Date.now();

async function act(a) {
  const loc = () => locate(p, a.target);
  switch (a.do) {
    case 'goto': await p.goto(BASE + a.path, { waitUntil: 'domcontentloaded' }); break;
    case 'reload': await p.reload({ waitUntil: 'domcontentloaded' }); break;
    case 'nav': {
      // Sidebar item by its menu name, opening its group first if it is collapsed.
      const link = p.getByRole('link', { name: new RegExp('^' + a.menu + '$', 'i') }).first();
      if (!(await link.isVisible().catch(() => false)) && a.group) {
        await p.locator('aside, nav').getByText(new RegExp('^' + a.group + '$')).first().click();
        await p.waitForTimeout(800);
      }
      await glide(rec, link); await link.click();
      break;
    }
    case 'click': { const l = loc(); await l.waitFor({ timeout: a.timeout || 30000 }); await glide(rec, l); await l.click(); break; }
    case 'hover': { const l = loc(); await glide(rec, l); await l.hover(); break; }
    case 'fill': await loc().fill(String(a.value)); break;
    case 'type': await typeSlowly(loc(), a.value, a.delay); break;
    case 'select': await loc().selectOption(a.value); break;
    case 'check': { const l = loc(); await glide(rec, l); await l.check(); break; }
    case 'press': await p.keyboard.press(a.key); break;
    case 'scroll':
      if (a.target) await loc().scrollIntoViewIfNeeded();
      else await p.mouse.wheel(0, a.y || 600);
      break;
    case 'wait': await p.waitForTimeout(a.ms || 1000); break;
    case 'waitFor': await loc().waitFor({ state: a.state || 'visible', timeout: a.timeout || 60000 }); break;
    case 'highlight': await highlight(rec, loc(), a.ms); break;
    case 'caption': await caption(rec, a.text); break;
    case 'cutStart': cutBegin(rec); break;
    case 'cutEnd': cutEnd(rec); break;
    case 'viewport': await p.setViewportSize({ width: a.width, height: a.height }); break;
    case 'signIn': await signIn(rec, BASE, accounts[a.account] || account); break;
    case 'workspace': {
      // Switch workspace through the dashboard's switcher. Best effort: the switcher's
      // wording can change, so give its trigger in a.target if the default misses.
      const trigger = a.target ? loc() : p.getByRole('button', { name: /workspace|namespace/i }).first();
      await trigger.click();
      await p.getByText(a.name, { exact: false }).first().click();
      await p.waitForLoadState('domcontentloaded');
      break;
    }
    case 'upload': {
      const dir = path.join(statementsDir, a.dir);
      const files = fs.readdirSync(dir).filter((f) => !a.match || new RegExp(a.match).test(f)).sort()
        .map((f) => path.join(dir, f));
      if (!files.length) throw new Error(`no statement files in ${dir}`);
      const [chooser] = await Promise.all([p.waitForEvent('filechooser'), loc().click()]);
      await chooser.setFiles(files);
      break;
    }
    case 'slow':
      // Wait for a long server-side step; edit.py squeezes it to a few seconds.
      await slow(rec, a.label || 'wait', async () => {
        const deadline = Date.now() + (a.timeout || 3600) * 1000;
        while (Date.now() < deadline) {
          await p.waitForTimeout(a.poll || 5000);
          if (Date.now() - lastRefresh > 30 * 60000) { await refreshToken(rec, API, account); lastRefresh = Date.now(); }
          if (a.until?.gone && !(await locate(p, a.until.gone).isVisible().catch(() => false))) return;
          if (a.until?.visible && (await locate(p, a.until.visible).isVisible().catch(() => false))) return;
          if (!a.until) return;
        }
        throw new Error(`slow "${a.label}" did not finish`);
      });
      break;
    default: throw new Error('unknown action ' + a.do);
  }
}

const timeline = [];
const from = opt('--from'), only = opt('--only');
let started = !from;
try {
  await signIn(rec, BASE, account);
  if (scene.startPath) await p.goto(BASE + scene.startPath, { waitUntil: 'domcontentloaded' });
  for (const sc of scene.scenes) {
    if (!started && sc.id === from) started = true;
    if (!started || (only && sc.id !== only)) continue;
    const s = rec.now();
    await caption(rec, sc.caption);
    for (const a of sc.actions || []) {
      try { await act(a); } catch (e) {
        if (!a.optional) throw e;
        rec.log('optional action skipped:', a.do, e.message.split('\n')[0]);
      }
      if (a.pause !== 0) await p.waitForTimeout(a.pause ?? 600);
    }
    // Hold the scene at least as long as its voice-over needs.
    const used = rec.now() - s;
    if (used < sc.duration) await p.waitForTimeout((sc.duration - used) * 1000);
    timeline.push({ id: sc.id, start: s, end: rec.now(), caption: sc.caption, voice: sc.voice });
  }
  await caption(rec, '');
  await p.waitForTimeout(1500);
} catch (e) {
  rec.log('FAILED', e.message);
  await p.screenshot({ path: path.join(OUT, 'failure.png') }).catch(() => {});
  process.exitCode = 1;
} finally {
  await finish(rec, { 'timeline.json': timeline, 'scene.json': scene });
}
