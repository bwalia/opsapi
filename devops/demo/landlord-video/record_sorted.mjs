// Records a 100-property landlord filing their 2025-26 return with "File with AI" on int.
// usage: SP=<scratchpad> node record_landlord.mjs   (run from the landlord/ folder)
// Writes out/raw.webm + out/segments.json; long waits are sped up afterwards by edit.py.
import { chromium } from 'playwright';
import fs from 'fs';
import { lastAssistant, waitIdle, quickReplies } from './chat.mjs';

const SP = process.env.SP;
const BASE = 'https://int-opsapi-ui.workstation.co.uk';
const API = 'https://int-opsapi.workstation.co.uk';
const EMAIL = fs.readFileSync(SP + '/landlord_email', 'utf8').trim();
const PW = fs.readFileSync(SP + '/int_pw', 'utf8').trim();
const PDF_DIR = SP + '/landlord/pdf';
const FILES = fs.readdirSync(PDF_DIR).filter((f) => f.endsWith('.pdf')).sort().map((f) => PDF_DIR + '/' + f);
const OUT = 'out_sorted';
const HU = JSON.parse(fs.readFileSync(SP + '/' + (process.env.HMRC_USER_FILE || 'hmrc_user.json'), 'utf8')).data;
const HMRC_USER = HU.userId, HMRC_PW = HU.password, NINO = HU.nino;
const TAX_YEAR = '2025-26';

fs.mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  recordVideo: { dir: OUT, size: { width: 1920, height: 1080 } },
});
const t0 = Date.now();
const now = () => (Date.now() - t0) / 1000;
const segments = [];
const log = (...a) => console.log(`[${now().toFixed(1)}s]`, ...a);

await ctx.addInitScript(() => {
  const install = () => {
    if (document.getElementById('__rec_cap')) return;
    const cap = document.createElement('div');
    cap.id = '__rec_cap';
    cap.style.cssText = 'position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:2147483647;'
      + 'background:rgba(15,23,42,.88);color:#fff;font:600 18px/1.35 system-ui,sans-serif;padding:10px 18px;'
      + 'border-radius:10px;max-width:80%;text-align:center;pointer-events:none;box-shadow:0 4px 16px rgba(0,0,0,.3)';
    cap.textContent = sessionStorage.getItem('__rec_cap') || '';
    cap.style.display = cap.textContent ? 'block' : 'none';
    const cur = document.createElement('div');
    cur.id = '__rec_cur';
    cur.style.cssText = 'position:fixed;width:18px;height:18px;border-radius:50%;background:rgba(239,68,68,.55);'
      + 'border:2px solid #fff;z-index:2147483647;pointer-events:none;transform:translate(-50%,-50%);left:-50px;top:-50px;'
      + 'transition:left .08s,top .08s';
    document.documentElement.append(cap, cur);
    addEventListener('mousemove', (e) => { cur.style.left = e.clientX + 'px'; cur.style.top = e.clientY + 'px'; }, true);
  };
  window.__setCap = (t) => {
    sessionStorage.setItem('__rec_cap', t);
    install();
    const c = document.getElementById('__rec_cap');
    c.textContent = t; c.style.display = t ? 'block' : 'none';
  };
  if (document.readyState === 'loading') addEventListener('DOMContentLoaded', install); else install();
});

const p = await ctx.newPage();
const cap = async (text) => { log('CAPTION', text); await p.evaluate((t) => window.__setCap?.(t), text).catch(() => {}); };
const pause = (ms = 1500) => p.waitForTimeout(ms);
const slow = async (label, fn) => {
  const s = now();
  try { return await fn(); } finally { segments.push({ start: s, end: now(), label }); log('slow', label, (now() - s).toFixed(1) + 's'); }
};
const type = async (loc, text) => { await loc.click(); await loc.pressSequentially(text, { delay: 35 }); };
const say = async (text) => {
  if (process.env.STOP_BEFORE_UPLOAD && /Upload/.test(text)) return;
  await type(p.getByPlaceholder('Type your answer…'), text);
  await pause(500);
  await p.getByRole('button', { name: /^send$/i }).click();
  await slow('thinking', () => waitIdle(p));
  log('ASSISTANT', (await lastAssistant(p)).slice(0, 400).replace(/\n/g, ' '));
};

// The dashboard's token lasts an hour and it never refreshes it, so during the long
// wait we sign in again in the background and hand the page the fresh token.
async function freshToken() {
  const r = await fetch(API + '/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ username: EMAIL, password: PW }),
  });
  const d = await r.json();
  if (!d.token) throw new Error('re-login failed');
  await p.evaluate((tok) => {
    localStorage.setItem('auth_token', tok);
    try {
      const z = JSON.parse(localStorage.getItem('auth-storage') || '{}');
      if (z.state) { z.state.token = tok; localStorage.setItem('auth-storage', JSON.stringify(z)); }
    } catch { /* keep going */ }
  }, d.token);
  log('token refreshed');
}

try {
  await p.goto(BASE + '/login', { waitUntil: 'domcontentloaded' });
  await type(p.getByLabel(/username or email/i), EMAIL);
  await type(p.getByLabel(/^password/i), PW);
  await p.getByRole('button', { name: /^sign in$/i }).click();
  await p.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 60000 });
  await p.goto(`${BASE}/dashboard/tax/file`, { waitUntil: 'domcontentloaded' });
  const ys = p.locator('select').filter({ has: p.locator(`option[value="${TAX_YEAR}"]`) }).first();
  await ys.waitFor({ timeout: 60000 });
  if ((await ys.inputValue()) !== TAX_YEAR) await ys.selectOption(TAX_YEAR);
  const closeAi = p.getByRole('button', { name: /^close$/i }).last();
  if (await closeAi.isVisible().catch(() => false)) await closeAi.click().catch(() => {});
  const show = p.getByRole('button', { name: /show transactions/i });
  const search = p.getByPlaceholder('Search descriptions…');
  await show.or(search).first().waitFor({ timeout: 60000 });
  if (await show.count()) await show.first().click();
  await search.waitFor({ timeout: 30000 });
  await p.getByRole('tab', { name: /^All \(\d+\)$/ }).click();
  await search.scrollIntoViewIfNeeded();
  await p.evaluate(() => window.scrollBy(0, 160));
  segments.push({ start: 0, end: now(), label: 'cut' });
  await cap('How the AI sorted the bank transactions, line by line');
  await pause(3500);
  await cap('Each line: the category, its tax treatment, who sorted it (rule or AI + how sure), and the AI\'s reason');
  await pause(6000);
  const EX = [
    ['RENT REMITTANCE', 'Rent paid over by a letting agent → rental income for the UK property business'],
    ['NEW KITCHEN', 'A new kitchen is an improvement, not a repair: the AI treats it as capital, not a running cost'],
    ['APPLIANCE REPAIRS', 'Fixing an appliance in a let → an allowable repair'],
    ['CTAX VOID', 'Council tax while a property stands empty → a cost of the letting business'],
    ['HMRC SELF ASSESSMENT', 'Paying HMRC is the landlord\'s own tax → not an expense, left off the return'],
    ['TESCO', 'No AI needed here: a known-merchant rule marks groceries as personal'],
  ];
  for (const [q, text] of EX) {
    await search.fill('');
    await type(search, q);
    await pause(1500);
    await cap(text);
    await pause(6500);
  }
  // The accountant challenges the AI: two calls an accountant would change.
  const recat = async (fromLabel, toLabel) => {
    const btn = p.locator('button[title="Change category"]', { hasText: fromLabel }).first();
    await btn.click();
    const box = p.getByPlaceholder('Search categories…');
    await type(box, toLabel);
    await pause(700);
    await p.getByRole('option', { name: new RegExp('^' + toLabel) }).first().click();
    await p.locator('button[title="Change category"]', { hasText: toLabel }).first().waitFor({ timeout: 15000 });
    await pause(1500);
  };
  const showOnly = async (q) => {
    const sh = p.getByRole('button', { name: /show transactions/i });
    if (await sh.count()) { await sh.first().click(); await pause(800); }
    await search.fill(''); await type(search, q); await pause(1800); };
  await cap('Now the accountant checks the AI\'s work, and challenges it');
  await pause(3500);
  await showOnly('CTAX');
  await cap('Council tax on empty lets: 6 lines went to rent, rates & insurance, 1 went to office costs');
  await pause(6500);
  await cap('Accountant: same charge, same box → move the stray one to rates');
  const GA = 'General Administrative Expenses';
  await recat(GA, 'Business Rates');
  await pause(3000);
  await showOnly('SERVICE CHARGE');
  await cap('Block service charges were put under office costs: the AI\'s reason is shown on each line');
  await pause(6500);
  await cap('Accountant: a service charge is a property running cost → rent, rates & insurance');
  while (await p.locator('button[title="Change category"]', { hasText: GA }).count()) {
    await recat(GA, 'Business Rent');
  }
  await cap('Every change is the accountant\'s: marked "You" and counted as checked');
  await pause(5000);
  await showOnly('NEW KITCHEN');
  await cap('New kitchen: the AI put it under capital allowances (box 28). For a residential let, the accountant would query that too');
  await pause(6500);
  await cap('');
  await pause(500);
} catch (e) {
  log('ERROR', e.message.split('\n')[0]);
  await p.screenshot({ path: OUT + '/error.png' });
  process.exitCode = 1;
} finally {
  fs.writeFileSync(OUT + '/segments.json', JSON.stringify(segments, null, 1));
  const v = p.video();
  await ctx.close();
  if (v) fs.renameSync(await v.path(), OUT + '/raw.webm');
  await browser.close();
  log('done');
}
