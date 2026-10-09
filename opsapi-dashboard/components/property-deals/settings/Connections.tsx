'use client';

/**
 * Data connectors (EPC register, Price Paid, Companies House, postcodes, paid-feed stubs),
 * mailboxes the legal chaser reads (IMAP / Gmail / Microsoft 365), and my notification
 * preferences. Secrets: write-only ("set" + Replace).
 */
import React, { useState } from 'react';
import { Plus, Play, RefreshCw, Trash2, KeyRound } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Select, Switch } from '@/components/ui';
import { pdService, pdErrorText, type Connector, type MailConnector, type NotificationPreferences } from '@/services/property-deals.service';
import { ErrorNote, Spinner, dateText } from '../ui';
import { usePdData } from '../usePd';

const KINDS: { value: string; label: string; secret?: string; fields: { name: string; label: string }[]; hint?: string }[] = [
  { value: 'epc', label: 'EPC register (GOV.UK)', secret: 'API key', fields: [{ name: 'email', label: 'Account email' }, { name: 'base_url', label: 'API base URL (optional)' }] },
  { value: 'price_paid', label: 'HM Land Registry Price Paid', fields: [{ name: 'base_url', label: 'API base URL (optional)' }], hint: 'Open data — no key.' },
  { value: 'companies_house', label: 'Companies House', secret: 'API key', fields: [{ name: 'base_url', label: 'API base URL (optional)' }] },
  { value: 'postcodes', label: 'Postcode lookup (postcodes.io)', fields: [{ name: 'base_url', label: 'API base URL (optional)' }], hint: 'Free — places postcodes on the map.' },
  { value: 'csv', label: 'CSV import (auction catalogues, agent feeds)', fields: [] },
  { value: 'propertydata', label: 'PropertyData (stub)', secret: 'API key', fields: [], hint: 'No adapter yet: import their CSV export.' },
  { value: 'searchland', label: 'Searchland (stub)', secret: 'API key', fields: [], hint: 'No adapter yet: import their CSV export.' },
  { value: 'streetdata', label: 'Street Data (stub)', secret: 'API key', fields: [], hint: 'No adapter yet: import their CSV export.' },
  { value: 'homedata', label: 'Homedata (stub)', secret: 'API key', fields: [], hint: 'No adapter yet: import their CSV export.' },
];
const MAIL: Record<string, { label: string; secret: string; fields: { name: string; label: string; type?: string }[] }> = {
  imap: { label: 'IMAP', secret: 'Password', fields: [{ name: 'host', label: 'Server' }, { name: 'port', label: 'Port (993)', type: 'number' }, { name: 'username', label: 'Username' }, { name: 'mailbox', label: 'Folder (INBOX)' }] },
  gmail: { label: 'Gmail (Google Workspace)', secret: 'JSON: {"client_secret": "…", "refresh_token": "…"}', fields: [{ name: 'client_id', label: 'OAuth client id' }] },
  m365: { label: 'Microsoft 365', secret: 'Client secret', fields: [{ name: 'tenant_id', label: 'Tenant id' }, { name: 'client_id', label: 'App (client) id' }, { name: 'mailbox', label: 'Mailbox address' }] },
};

export function DataConnectors({ canEdit }: { canEdit: boolean }) {
  const list = usePdData(async () => (await pdService.connectors()).data, []);
  const [edit, setEdit] = useState<Partial<Connector> | null>(null);
  const [running, setRunning] = useState<string | null>(null);
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-semibold text-secondary-900">Data connectors</h3>
          <p className="text-sm text-secondary-500">Official data for the map, comparables, EPC look-ups and company buyer checks. No portal scraping.</p>
        </div>
        {canEdit && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEdit({ kind: 'epc' as Connector['kind'], enabled: true })}>Add connector</Button>}
      </div>
      <ErrorNote error={list.error} />
      {list.loading && !list.data ? <Spinner /> : (
        <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
          {(list.data || []).length === 0 && <li className="p-4 text-sm text-secondary-500">No connectors yet.</li>}
          {(list.data || []).map((c) => (
            <li key={c.uuid} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-secondary-900">{c.name}</span>
                  <Badge size="sm">{KINDS.find((k) => k.value === c.kind)?.label || c.kind}</Badge>
                  {c.stub && <Badge size="sm" variant="secondary">stub</Badge>}
                  {c.sync_enabled && <Badge size="sm" variant="info">daily sync</Badge>}
                  {!c.enabled && <Badge size="sm" variant="secondary">off</Badge>}
                </div>
                <div className="text-secondary-500">{c.records_count ?? 0} records · {c.has_secret ? 'key set' : 'no key'}{c.last_run_at ? ` · last run ${dateText(c.last_run_at, true)}` : ''}</div>
                {c.last_error && <div className="text-xs text-error-600">{c.last_error}</div>}
              </div>
              <div className="flex gap-1">
                {['epc', 'price_paid'].includes(c.kind) && (
                  <Button size="sm" variant="outline" leftIcon={<Play className="h-4 w-4" />} isLoading={running === c.uuid} onClick={async () => {
                    const pc = window.prompt('Postcode to fetch for', 'YO1 7AA');
                    if (!pc) return;
                    setRunning(c.uuid);
                    try { const r = (await pdService.runConnector(c.uuid, pc)).data; toast.success(`Fetched ${r.fetched}, ${r.stored} new`); } catch (e) { toast.error(pdErrorText(e)); } finally { setRunning(null); list.refresh(); }
                  }}>Run</Button>
                )}
                {canEdit && <Button size="sm" variant="ghost" onClick={() => setEdit(c)}>Edit</Button>}
                {canEdit && <Button size="sm" variant="ghost" aria-label={`Delete ${c.name}`} onClick={async () => { if (window.confirm(`Delete ${c.name}?`)) { try { await pdService.deleteConnector(c.uuid); list.refresh(); } catch (e) { toast.error(pdErrorText(e)); } } }}><Trash2 className="h-4 w-4" /></Button>}
              </div>
            </li>
          ))}
        </ul>
      )}
      {edit && <ConnectorModal c={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); list.refresh(); }} />}
    </Card>
  );
}

function ConnectorModal({ c, onClose, onSaved }: { c: Partial<Connector>; onClose: () => void; onSaved: () => void }) {
  const [kind, setKind] = useState(String(c.kind || 'epc'));
  const spec = KINDS.find((k) => k.value === kind)!;
  const [name, setName] = useState(c.name || spec.label);
  const [cfg, setCfg] = useState<Record<string, string>>((c.config as Record<string, string>) || {});
  const [secret, setSecret] = useState('');
  const [replacing, setReplacing] = useState(!c.has_secret);
  const [sync, setSync] = useState(Boolean(c.sync_enabled));
  const [enabled, setEnabled] = useState(c.enabled ?? true);
  return (
    <Modal isOpen onClose={onClose} title={c.uuid ? `Edit ${c.name}` : 'Add a data connector'} size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Source" value={kind} disabled={!!c.uuid} onChange={(e) => { setKind(e.target.value); setName(KINDS.find((k) => k.value === e.target.value)?.label || ''); }}>
          {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
        </Select>
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        {spec.fields.map((f) => <Input key={f.name} label={f.label} value={cfg[f.name] || ''} onChange={(e) => setCfg({ ...cfg, [f.name]: e.target.value })} />)}
        {spec.secret && (
          <div className="sm:col-span-2">
            {replacing ? <Input label={spec.secret} type="password" autoComplete="new-password" value={secret} onChange={(e) => setSecret(e.target.value)} helperText={c.has_secret ? 'Leave empty to keep the saved one.' : undefined} />
              : <div className="flex items-center justify-between rounded-lg border border-secondary-200 p-3 text-sm"><span className="inline-flex items-center gap-2"><KeyRound className="h-4 w-4 text-secondary-400" aria-hidden /> Key saved ••••</span><Button size="sm" variant="outline" onClick={() => setReplacing(true)}>Replace</Button></div>}
          </div>
        )}
        {spec.hint && <p className="text-sm text-secondary-500 sm:col-span-2">{spec.hint}</p>}
        {['epc', 'price_paid'].includes(kind) && <label className="flex items-center gap-2 text-sm sm:col-span-2"><Switch checked={sync} onChange={setSync} /> Fetch daily for active deals and saved searches</label>}
        <label className="flex items-center gap-2 text-sm"><Switch checked={enabled} onChange={setEnabled} /> Enabled</label>
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={async () => {
          const config: Record<string, string> = {};
          for (const [k, v] of Object.entries(cfg)) if (v) config[k] = v;
          const body: Record<string, unknown> = { name, config, enabled, sync_enabled: sync };
          if (!c.uuid) body.kind = kind;
          if (secret) body.secret = secret;
          try { await pdService.saveConnector(body, c.uuid); toast.success('Saved'); onSaved(); } catch (e) { toast.error(pdErrorText(e)); }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

export function Mailboxes({ canEdit }: { canEdit: boolean }) {
  const list = usePdData(async () => (await pdService.mailConnectors()).data, []);
  const [edit, setEdit] = useState<Partial<MailConnector> | null>(null);
  const [syncing, setSyncing] = useState<string | null>(null);
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-semibold text-secondary-900">Mailboxes</h3>
          <p className="text-sm text-secondary-500">Replies from solicitors are matched to deals (by reference or sender), mark chases replied and wake the legal chaser. Read-only access.</p>
        </div>
        {canEdit && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEdit({ kind: 'imap' as MailConnector['kind'], enabled: true })}>Add mailbox</Button>}
      </div>
      <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
        {(list.data || []).length === 0 && <li className="p-4 text-sm text-secondary-500">No mailboxes yet.</li>}
        {(list.data || []).map((m) => (
          <li key={m.uuid} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
            <div>
              <div className="flex items-center gap-2"><span className="font-medium text-secondary-900">{m.name}</span><Badge size="sm">{MAIL[m.kind]?.label || m.kind}</Badge>{!m.enabled && <Badge size="sm" variant="secondary">off</Badge>}</div>
              <div className="text-secondary-500">{m.has_secret ? 'credentials set' : 'no credentials'}{m.last_synced_at ? ` · last sync ${dateText(m.last_synced_at, true)}` : ''}</div>
              {m.last_error && <div className="text-xs text-error-600">{m.last_error}</div>}
            </div>
            <div className="flex gap-1">
              <Button size="sm" variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} isLoading={syncing === m.uuid} onClick={async () => {
                setSyncing(m.uuid);
                try { const r = (await pdService.syncMailConnector(m.uuid)).data; toast.success(`Fetched ${r.fetched}, ${r.matched} matched to deals`); } catch (e) { toast.error(pdErrorText(e)); } finally { setSyncing(null); list.refresh(); }
              }}>Sync now</Button>
              {canEdit && <Button size="sm" variant="ghost" onClick={() => setEdit(m)}>Edit</Button>}
              {canEdit && <Button size="sm" variant="ghost" aria-label={`Delete ${m.name}`} onClick={async () => { if (window.confirm(`Delete ${m.name}?`)) { try { await pdService.deleteMailConnector(m.uuid); list.refresh(); } catch (e) { toast.error(pdErrorText(e)); } } }}><Trash2 className="h-4 w-4" /></Button>}
            </div>
          </li>
        ))}
      </ul>
      {edit && <MailModal m={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); list.refresh(); }} />}
    </Card>
  );
}

function MailModal({ m, onClose, onSaved }: { m: Partial<MailConnector>; onClose: () => void; onSaved: () => void }) {
  const [kind, setKind] = useState(String(m.kind || 'imap'));
  const spec = MAIL[kind];
  const [name, setName] = useState(m.name || 'Deals inbox');
  const [cfg, setCfg] = useState<Record<string, string>>(Object.fromEntries(Object.entries((m.config as Record<string, unknown>) || {}).map(([k, v]) => [k, String(v)])));
  const [secret, setSecret] = useState('');
  return (
    <Modal isOpen onClose={onClose} title={m.uuid ? `Edit ${m.name}` : 'Add a mailbox'} size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Kind" value={kind} disabled={!!m.uuid} onChange={(e) => setKind(e.target.value)}>
          {Object.entries(MAIL).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
        </Select>
        <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} />
        {spec.fields.map((f) => <Input key={f.name} label={f.label} type={f.type || 'text'} value={cfg[f.name] || ''} onChange={(e) => setCfg({ ...cfg, [f.name]: e.target.value })} />)}
        <div className="sm:col-span-2"><Input label={spec.secret} type="password" autoComplete="new-password" value={secret} onChange={(e) => setSecret(e.target.value)} helperText={m.has_secret ? 'Saved ••••. Leave empty to keep it.' : undefined} /></div>
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={async () => {
          const config: Record<string, unknown> = {};
          for (const [k, v] of Object.entries(cfg)) if (v) config[k] = k === 'port' ? Number(v) : v;
          const body: Record<string, unknown> = { name, config };
          if (!m.uuid) body.kind = kind;
          if (secret) { try { body.secret = kind === 'gmail' ? JSON.parse(secret) : secret; } catch { toast.error('Gmail needs the JSON shown'); return; } }
          try { await pdService.saveMailConnector(body, m.uuid); toast.success('Saved'); onSaved(); } catch (e) { toast.error(pdErrorText(e)); }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

const CATS: { key: keyof NotificationPreferences; label: string }[] = [
  { key: 'sla_warning', label: 'Due soon (SLA warning)' },
  { key: 'overdue', label: 'Overdue' },
  { key: 'escalated', label: 'Escalated to me' },
  { key: 'approval_requested', label: 'Approval needed' },
  { key: 'digest', label: 'Daily digest' },
  { key: 'compliance_expiring', label: 'Compliance expiring' },
  { key: 'agent_update', label: "AI couldn't finish" },
  { key: 'deal_scout' as keyof NotificationPreferences, label: 'Deal scout alerts' },
];

export function MyNotifications() {
  const prefs = usePdData(async () => (await pdService.notificationPrefs()).data, []);
  const p = prefs.data as unknown as Record<string, { push: boolean; email: boolean } | { from: string; to: string } | undefined>;
  async function save(body: Record<string, unknown>) {
    try { const r = (await pdService.saveNotificationPrefs(body)).data; prefs.setData(r); toast.success('Saved'); } catch (e) { toast.error(pdErrorText(e)); }
  }
  if (prefs.loading && !prefs.data) return <Spinner />;
  const q = p?.quiet_hours as { from: string; to: string } | undefined;
  return (
    <Card>
      <h3 className="font-semibold text-secondary-900">My notifications</h3>
      <p className="text-sm text-secondary-500">In-app notifications always arrive. Choose push (phone) and email per kind.</p>
      <table className="mt-4 w-full text-sm">
        <thead className="text-left text-xs text-secondary-500"><tr><th className="py-1">Notification</th><th>Push</th><th>Email</th></tr></thead>
        <tbody>
          {CATS.map((c) => {
            const v = (p?.[c.key as string] as { push: boolean; email: boolean } | undefined) || { push: true, email: true };
            return (
              <tr key={c.key as string} className="border-t border-secondary-100">
                <td className="py-2">{c.label}</td>
                <td><Switch checked={v.push} onChange={(x) => save({ [c.key]: { push: x } })} aria-label={`${c.label} push`} /></td>
                <td><Switch checked={v.email} onChange={(x) => save({ [c.key]: { email: x } })} aria-label={`${c.label} email`} /></td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <div className="mt-4 flex flex-wrap items-end gap-3">
        <Input type="time" label="Quiet from" defaultValue={q?.from || ''} id="pd-quiet-from" />
        <Input type="time" label="Quiet until" defaultValue={q?.to || ''} id="pd-quiet-to" />
        <Button variant="outline" onClick={() => {
          const from = (document.getElementById('pd-quiet-from') as HTMLInputElement).value;
          const to = (document.getElementById('pd-quiet-to') as HTMLInputElement).value;
          save({ quiet_hours: from && to ? { from, to } : null });
        }}>Save quiet hours</Button>
        <span className="text-xs text-secondary-500">Holds back push (workspace time). The digest still comes.</span>
      </div>
    </Card>
  );
}
