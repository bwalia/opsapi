import { createBilling, createLicensing, fingerprintHash, verifyLicenseFile } from '/sdk/billing.js';
import { readFileSync } from 'node:fs';
const B = 'http://e2e-api', OWNER = readFileSync('/e2e/owner.jwt', 'utf8').trim();
let fails = 0;
const check = (name, ok, d = '') => { console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(d).slice(0, 300))); if (!ok) fails++; };
const owner = async (method, path, body) => {
  const r = await fetch(B + path, { method, headers: { Authorization: `Bearer ${OWNER}`, 'X-Namespace-Slug': 'e2e', 'Content-Type': 'application/json' }, body: body && JSON.stringify(body) });
  return r.json();
};
const WEB = 'web-' + Date.now();
const app = (await owner('GET', '/api/v2/billing/apps')).data.find((a) => a.name === 'Notes Pro');
const sale = await owner('POST', '/api/v2/subscriptions/purchases', { app: app.uuid, customer_external_id: 'sdk-' + Date.now(), email: 'sdk' + Date.now() + '@buyer.test', plan: 'lifetime' });
const key = sale.data.key;
check('sale for the SDK test returns a key', !!key, sale);

// Desktop app, no back end: publishable key only.
const licensing = createLicensing({ baseUrl: B, publishableKey: app.publishable_key });
const info = await licensing.appInfo();
check('appInfo -> salt + offline settings', info.fingerprint_salt === app.settings.fingerprint_salt && info.grace_days === 30, info);
const fp = await fingerprintHash(info.fingerprint_salt, ' NODE-MACHINE-01 ');
const act = await licensing.activate({ licenseKey: key, fingerprintHash: fp, appVersion: '1.0.0', name: 'CI box', platform: 'linux' });
check('activate -> licence file', act.license_file.split('.').length === 3, act);
const v = await verifyLicenseFile(act.license_file, { baseUrl: B, fingerprintHash: fp, app: app.uuid, iss: 'https://billing.e2e.test' });
check('verifyLicenseFile (server JWKS): valid, allowed, cloud_sync excluded', v.state === 'valid' && v.allowed && v.claims.features.cloud_sync === false && v.claims.features.export_pdf === true, v);
try { await licensing.activate({ licenseKey: 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE', fingerprintHash: fp, appVersion: '1' }); check('bad key throws', false); }
catch (e) { check('bad key -> BillingError invalid_license', e.code === 'invalid_license' && e.status === 404, e); }
const val = await licensing.validate({ licenseKey: key, fingerprintHash: fp, appVersion: '1.0.1' });
check('validate -> fresh file', !!val.license_file);

// Web back end: secret key.
const k = await owner('POST', '/api/v2/api-keys', { name: 'sdk', scopes: { entitlements: ['read', 'create'] } });
const billing = createBilling({ baseUrl: B, apiKey: k.data.key, app: app.uuid });
const c = await billing.upsertCustomer(WEB, { email: WEB + '@buyer.test' });
check('upsertCustomer', c.external_id === WEB, c);
check('free plan: can(export_pdf) = false, limit(projects) = 3', (await billing.can(WEB, 'export_pdf')) === false && (await billing.limit(WEB, 'projects')) === 3);
const rec = await billing.recordPurchase({ customerExternalId: WEB, source: 'play_store', storeProductId: 'missing', externalTransactionId: 'gp-' + WEB }).catch((e) => e);
check('recordPurchase with an unknown product -> 404', rec.status === 404, rec);
const rec2 = await billing.recordPurchase({ customerExternalId: WEB, source: 'external', planKey: 'pass_30', externalTransactionId: 'ext-' + WEB });
check('recordPurchase (external) -> purchase', rec2.purchase?.source === 'external', rec2);
const ent = await billing.getEntitlements(WEB);
check('entitlements after the purchase (signed token verified): pass_30', ent.plan === 'pass_30' && ent.features.projects === 20 && ent.accessUntil > Date.now() / 1000, ent);
console.log('\nSDK FAILURES:', fails);
