// Shared recording helpers for Daybook demo videos.
// Generalised from devops/demo/landlord-video/record_*.mjs: caption overlay, visible
// cursor, "slow" segments that edit.py speeds up, "cut" segments it drops, sign-in and
// token refresh. run.mjs drives these from a scene file; a one-off recorder can import
// them directly.
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

// Daybook brand (docs/plans/DAYBOOK_DEMO_SPEC.md): navy band, gold rule, Poppins.
const OVERLAY = {
  band: '#14213D', ink: '#EEF1F6', gold: '#D4B26A', cursor: 'rgba(212,178,106,.6)',
  font: "600 19px/1.35 Poppins, 'Segoe UI', system-ui, sans-serif",
};

export function loadAccounts() {
  // Recording accounts live OUTSIDE the repo: $REC_SECRETS/accounts.json
  // { "staff:ade": { "email": "...", "password": "..." }, "client:C3": { ... } }
  const dir = process.env.REC_SECRETS;
  if (!dir) throw new Error('set REC_SECRETS to the private folder holding accounts.json');
  return JSON.parse(fs.readFileSync(path.join(dir, 'accounts.json'), 'utf8'));
}

export async function startRecorder({ outDir, viewport = { width: 1920, height: 1080 }, mobile = false }) {
  fs.mkdirSync(outDir, { recursive: true });
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport,
    deviceScaleFactor: mobile ? 3 : 1,
    isMobile: mobile,
    hasTouch: mobile,
    locale: 'en-GB',
    timezoneId: 'Europe/London',
    recordVideo: { dir: outDir, size: viewport },
  });
  await ctx.addInitScript(installOverlay, OVERLAY);
  const page = await ctx.newPage();
  const t0 = Date.now();
  const rec = {
    browser, ctx, page, outDir,
    now: () => (Date.now() - t0) / 1000,
    segments: [], // { start, end, label }  label "cut" = drop, else speed up when long
    captions: [], // { t, text }
    log: (...a) => console.log(`[${rec.now().toFixed(1)}s]`, ...a),
  };
  return rec;
}

function installOverlay(o) {
  const install = () => {
    if (document.getElementById('__rec_cap')) return;
    const cap = document.createElement('div');
    cap.id = '__rec_cap';
    cap.style.cssText = 'position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:2147483647;'
      + `background:${o.band};color:${o.ink};font:${o.font};padding:12px 22px 12px 22px;`
      + `border-top:3px solid ${o.gold};border-radius:6px;max-width:78%;text-align:center;pointer-events:none;`
      + 'box-shadow:0 6px 20px rgba(0,0,0,.28);letter-spacing:.1px';
    cap.textContent = sessionStorage.getItem('__rec_cap') || '';
    cap.style.display = cap.textContent ? 'block' : 'none';
    const cur = document.createElement('div');
    cur.id = '__rec_cur';
    cur.style.cssText = `position:fixed;width:20px;height:20px;border-radius:50%;background:${o.cursor};`
      + 'border:2px solid #fff;z-index:2147483647;pointer-events:none;transform:translate(-50%,-50%);'
      + 'left:-50px;top:-50px;transition:left .08s,top .08s';
    const hl = document.createElement('div');
    hl.id = '__rec_hl';
    hl.style.cssText = `position:fixed;border:3px solid ${o.gold};border-radius:8px;z-index:2147483646;`
      + 'pointer-events:none;display:none;box-shadow:0 0 0 9999px rgba(20,33,61,.18)';
    document.documentElement.append(cap, cur, hl);
    addEventListener('mousemove', (e) => { cur.style.left = e.clientX + 'px'; cur.style.top = e.clientY + 'px'; }, true);
  };
  window.__setCap = (t) => {
    sessionStorage.setItem('__rec_cap', t);
    install();
    const c = document.getElementById('__rec_cap');
    c.textContent = t; c.style.display = t ? 'block' : 'none';
  };
  window.__highlight = (r) => {
    install();
    const h = document.getElementById('__rec_hl');
    if (!r) { h.style.display = 'none'; return; }
    Object.assign(h.style, { left: (r.x - 6) + 'px', top: (r.y - 6) + 'px', width: (r.width + 12) + 'px',
      height: (r.height + 12) + 'px', display: 'block' });
  };
  if (document.readyState === 'loading') addEventListener('DOMContentLoaded', install); else install();
}

export async function caption(rec, text) {
  rec.captions.push({ t: rec.now(), text: text || '' });
  rec.log('CAPTION', text);
  await rec.page.evaluate((t) => window.__setCap?.(t), text || '').catch(() => {});
}

// Time spent in fn is a "slow" segment: edit.py plays it back in a few seconds.
export async function slow(rec, label, fn) {
  const s = rec.now();
  try { return await fn(); } finally {
    rec.segments.push({ start: s, end: rec.now(), label });
    rec.log('slow', label, (rec.now() - s).toFixed(1) + 's');
  }
}

let cutStart = null;
export function cutBegin(rec) { cutStart = rec.now(); }
export function cutEnd(rec) {
  if (cutStart != null) rec.segments.push({ start: cutStart, end: rec.now(), label: 'cut' });
  cutStart = null;
}

export async function typeSlowly(loc, text, delay = 35) {
  await loc.click();
  await loc.pressSequentially(String(text), { delay });
}

export async function signIn(rec, base, account) {
  const p = rec.page;
  await p.goto(base + '/login', { waitUntil: 'domcontentloaded' });
  await typeSlowly(p.getByLabel(/username or email/i), account.email, 20);
  await typeSlowly(p.getByLabel(/^password/i), account.password, 20);
  await p.getByRole('button', { name: /^sign in$/i }).click();
  await p.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 60000 });
}

// The dashboard's token lasts an hour and isn't refreshed by the page: during a long
// wait, sign in again in the background and hand the page the new token.
export async function refreshToken(rec, api, account) {
  const r = await fetch(api + '/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ username: account.email, password: account.password }),
  });
  const d = await r.json();
  if (!d.token) throw new Error('re-login failed');
  await rec.page.evaluate((tok) => {
    localStorage.setItem('auth_token', tok);
    try {
      const z = JSON.parse(localStorage.getItem('auth-storage') || '{}');
      if (z.state) { z.state.token = tok; localStorage.setItem('auth-storage', JSON.stringify(z)); }
    } catch { /* keep going */ }
  }, d.token);
  rec.log('token refreshed');
}

// Resolve a target object from a scene file to a Playwright locator.
//   { role, name } | { text } | { label } | { placeholder } | { testid } | { css }
//   name/text/label may be "/regex/flags"; add "nth": n (or "last": true), "within": css
export function locate(page, t) {
  if (!t) throw new Error('missing target');
  const rx = (v) => {
    if (typeof v !== 'string') return v;
    const m = v.match(/^\/(.*)\/([a-z]*)$/s);
    return m ? new RegExp(m[1], m[2]) : v;
  };
  const scope = t.within ? page.locator(t.within).first() : page;
  let loc;
  if (t.role) loc = scope.getByRole(t.role, t.name ? { name: rx(t.name), exact: t.exact } : {});
  else if (t.text) loc = scope.getByText(rx(t.text), { exact: t.exact });
  else if (t.label) loc = scope.getByLabel(rx(t.label), { exact: t.exact });
  else if (t.placeholder) loc = scope.getByPlaceholder(rx(t.placeholder));
  else if (t.testid) loc = scope.getByTestId(t.testid);
  else if (t.css) loc = scope.locator(t.css);
  else throw new Error('unknown target ' + JSON.stringify(t));
  if (t.last) return loc.last();
  return loc.nth(t.nth ?? 0);
}

export async function highlight(rec, loc, ms = 1800) {
  const box = await loc.boundingBox().catch(() => null);
  if (!box) return;
  await rec.page.evaluate((r) => window.__highlight?.(r), box);
  await rec.page.waitForTimeout(ms);
  await rec.page.evaluate(() => window.__highlight?.(null));
}

// Move the visible cursor to an element before clicking, so viewers can follow it.
export async function glide(rec, loc) {
  const box = await loc.boundingBox().catch(() => null);
  if (!box) return;
  await rec.page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 18 });
  await rec.page.waitForTimeout(250);
}

export async function finish(rec, extra = {}) {
  const video = rec.page.video();
  await rec.ctx.close();
  await rec.browser.close();
  const raw = path.join(rec.outDir, 'raw.webm');
  if (video) fs.renameSync(await video.path(), raw);
  fs.writeFileSync(path.join(rec.outDir, 'segments.json'), JSON.stringify(rec.segments, null, 1));
  fs.writeFileSync(path.join(rec.outDir, 'captions.json'), JSON.stringify(rec.captions, null, 1));
  for (const [k, v] of Object.entries(extra)) {
    fs.writeFileSync(path.join(rec.outDir, k), JSON.stringify(v, null, 1));
  }
  rec.log('wrote', raw);
}
