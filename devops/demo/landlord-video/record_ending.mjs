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
const OUT = 'out_end';
const HU = JSON.parse(fs.readFileSync(SP + '/' + (process.env.HMRC_USER_FILE || 'hmrc_user.json'), 'utf8')).data;
const HMRC_USER = HU.userId, HMRC_PW = HU.password, NINO = HU.nino;
const TAX_YEAR = '2025-26';

fs.mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: OUT, size: { width: 1440, height: 900 } },
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
  // 7. File My Tax: NINO, check the flagged transactions, connect HMRC, calculate, file
  await p.goto(`${BASE}/dashboard/tax/file`, { waitUntil: 'domcontentloaded' });
  segments.push({ start: 0, end: now(), label: 'cut' });
  const ys = p.locator('select').filter({ has: p.locator(`option[value="${TAX_YEAR}"]`) }).first();
  await ys.waitFor({ timeout: 60000 });
  if ((await ys.inputValue()) !== TAX_YEAR) await ys.selectOption(TAX_YEAR);
  // The assistant panel is not needed for filing: close it if it is open.
  const closeAi = p.getByRole('button', { name: /^close$/i }).last();
  if (await closeAi.isVisible().catch(() => false)) await closeAi.click().catch(() => {});
  await cap('9 · Now file it. Add the National Insurance number (HMRC sandbox test user)');
  await pause(2500);
  await type(p.getByPlaceholder(/QQ 12 34 56 C/i), NINO);
  await p.getByRole('checkbox', { name: /I consent/i }).check();
  await pause(600);
  await p.getByRole('button', { name: /^save$/i }).first().click();
  await p.getByText(/Add my National Insurance number/).waitFor({ state: 'detached', timeout: 20000 });
  if (await p.getByText(/already registered on another account/i).count()) throw new Error('NINO already registered on another account');
  await pause(2500);

  await cap('10 · Check the transactions the AI was unsure about');
  const show = p.getByRole('button', { name: /show transactions/i });
  if (await show.count()) await show.first().click();
  await pause(2500);
  const chip = p.getByText(/^Please check \(\d+\)$/).first();
  if (await chip.count()) { await chip.click(); await pause(2000); }
  // Where each flagged line belongs, and why (shown as the caption).
  const FIXES = [
    [/TRANSFER TO PERSONAL/i, 'Transfer Between Accounts', 'Money moved to your own account is not an expense → Transfer Between Accounts'],
    [/MORTGAGE/i, 'Loan Repayments', 'A mortgage payment is capital + interest; the interest was given separately → Loan Repayments'],
    [/INSURANCE/i, 'Premises Insurance', 'Landlord insurance for the lets is a property running cost → Premises Insurance'],
    [/SOFTWARE|SUBSCRIPTION/i, 'Software & Subscriptions', 'Property management software is an allowable cost → Software & Subscriptions'],
    [/CTAX|COUNCIL/i, 'Business Rates', 'Council tax on an empty (void) property is a running cost → Rates'],
  ];
  for (let n = 0; n < 40; n++) {
    const act = p.getByRole('button', { name: /^(looks right|choose a category)$/i });
    const row = p.locator('tbody tr').filter({ has: act }).first();
    if (!(await row.count())) break;
    const text = await row.innerText();
    await row.scrollIntoViewIfNeeded();
    const fix = FIXES.find(([re]) => re.test(text));
    if (fix) {
      await cap(fix[2]);
      await pause(2600);
      const choose = row.getByRole('button', { name: /choose a category/i });
      if (await choose.count()) await choose.click();
      else await row.locator('td').nth(1).getByRole('button').first().click();
      await pause(700);
      const search = p.getByPlaceholder('Search categories…');
      if (!(await search.isVisible().catch(() => false))) await row.getByText(/Choose a category…|Expense$/).first().click();
      await search.fill(fix[1]);
      await pause(900);
      await p.getByRole('listbox').getByRole('option').filter({ hasText: fix[1] }).first().getByRole('button').click();
      await pause(1200);
      // Picking a category confirms the row; if it still asks, confirm it.
      const lr = row.getByRole('button', { name: /looks right/i });
      if (await lr.count().catch(() => 0)) await lr.click().catch(() => {});
    } else {
      await cap(/KITCHEN/i.test(text)
        ? 'A new kitchen is an improvement (capital), so it is not claimed as a property expense → Looks right'
        : /TESCO|GROCER/i.test(text)
        ? 'Groceries paid from the property account are personal, not a property cost → Looks right'
        : 'Checked: the AI got this one right → Looks right');
      await pause(2000);
      await row.getByRole('button', { name: /looks right/i }).click();
    }
    await pause(1500);
  }
  const rest = p.getByRole('button', { name: /confirm the rest/i });
  if (await rest.count()) {
    await cap('Confirm the rest after checking them');
    await rest.first().click();
    await p.getByText(/I.ve checked these transactions/).click();
    await pause(800);
    await p.getByRole('button', { name: /^confirm \d+$/i }).click();
    await pause(3000);
  }

  await cap('11 · File directly with HMRC: connect via HMRC sign-in (sandbox)');
  await p.getByRole('button', { name: /file directly with hmrc/i }).click();
  await pause(1500);
  await p.getByRole('button', { name: /go to hmrc to connect|connect to hmrc again/i }).click();
  await p.waitForURL(/tax\.service\.gov\.uk/, { timeout: 60000 });
  await cap('HMRC: allow this software to connect');
  await pause(2500);
  for (let n = 0; n < 4 && !(await p.getByLabel(/user id/i).count()); n++) {
    const rej = p.getByRole('button', { name: /reject additional cookies/i });
    if (await rej.count()) await rej.first().click().catch(() => {});
    await p.getByRole('button', { name: /continue|start|sign in to the hmrc/i }).or(
      p.getByRole('link', { name: /sign in to the hmrc|continue|start/i })).first().click();
    await p.waitForLoadState('domcontentloaded');
    await pause(1500);
  }
  await cap('HMRC: sign in as the sandbox test user');
  await type(p.getByLabel(/user id/i), HMRC_USER);
  await type(p.getByLabel(/password/i), HMRC_PW);
  await p.getByRole('button', { name: /sign in/i }).click();
  await p.waitForLoadState('domcontentloaded');
  await cap('HMRC: grant read and write access to Self Assessment');
  await pause(3000);
  await p.getByRole('button', { name: /grant|give permission|allow|continue/i }).first().click();
  await p.waitForURL(/int-opsapi-ui\.workstation\.co\.uk/, { timeout: 90000 });
  await cap(`Back in OpsAPI: connected to HMRC, tax year ${TAX_YEAR}`);
  await pause(3000);

  await cap('12 · OpsAPI finds the UK property business at HMRC and builds the property figures');
  await slow('auto-steps', () => p.getByRole('button', { name: /ask hmrc to work out my tax/i })
    .waitFor({ timeout: 180000 }));
  await p.getByText('Check your figures').scrollIntoViewIfNeeded();
  await pause(2500);
  await p.getByText('Exactly what we').scrollIntoViewIfNeeded().catch(() => {});
  await cap('Rents, property expenses by HMRC box, and residential mortgage interest as the 20% credit');
  await pause(7000);
  await cap('13 · Send the figures to HMRC and let HMRC work out the tax (not filed yet)');
  await p.getByRole('button', { name: /ask hmrc to work out my tax/i }).click();
  await slow('calculation', () => p.getByRole('button', { name: /ask hmrc again/i }).waitFor({ timeout: 300000 }));
  await p.getByText('See your tax bill from HMRC').scrollIntoViewIfNeeded();
  await pause(5000);

  await cap('14 · Confirm the declaration and file the return with HMRC (sandbox)');
  await p.getByText('File your tax return').last().scrollIntoViewIfNeeded();
  await pause(1500);
  await p.locator('input[type=checkbox]').last().check();
  await pause(1200);
  await p.getByRole('button', { name: /file my tax return now/i }).click();
  await slow('filing', () => p.getByText(/test using HMRC.s test service|filed/i).first().waitFor({ timeout: 300000 }));
  await cap('Filed with HMRC (sandbox): the landlord\'s 2025-26 return is accepted');
  await pause(7000);
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
