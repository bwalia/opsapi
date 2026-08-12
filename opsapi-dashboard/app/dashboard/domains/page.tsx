'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  Search, Plus, Trash2, Edit, RefreshCw, Globe, ShieldCheck, AlertTriangle,
  Clock, X, Cloud, GitBranch, Download, Play, KeyRound, Settings,
} from 'lucide-react';
import { Input, Table, Badge, Pagination, Card, Modal, Button, ConfirmDialog, Select } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  domainService,
  type Domain,
  type DomainStats,
  type DomainStatus,
  type CloudflareRecord,
  type DomainSyncConfig,
  type SyncToRepoResult,
  type PipelineRun,
  type GithubIntegrationLite,
} from '@/services/domain.service';
import { renderTemplatesService, type RenderTemplate } from '@/services/render-templates.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

// Days until a date (UTC-ish, day granularity). null if no date.
function daysUntil(dateStr?: string): number | null {
  if (!dateStr) return null;
  const t = new Date(dateStr.replace(' ', 'T') + 'Z').getTime();
  if (Number.isNaN(t)) return null;
  return Math.floor((t - Date.now()) / 86_400_000);
}

function ExpiryCell({ dateStr, threshold = 30 }: { dateStr?: string; threshold?: number }) {
  if (!dateStr) return <span className="text-secondary-400">—</span>;
  const d = daysUntil(dateStr);
  let variant: 'success' | 'warning' | 'error' | 'secondary' = 'success';
  if (d === null) variant = 'secondary';
  else if (d < 0) variant = 'error';
  else if (d <= threshold) variant = 'warning';
  return (
    <div className="flex flex-col">
      <span className="text-sm">{formatDate(dateStr)}</span>
      <Badge variant={variant}>
        {d === null ? 'unknown' : d < 0 ? `expired ${-d}d ago` : `in ${d}d`}
      </Badge>
    </div>
  );
}

function StatusBadge({ status }: { status: DomainStatus }) {
  const map: Record<DomainStatus, 'success' | 'warning' | 'error' | 'secondary' | 'info'> = {
    active: 'success',
    expiring_soon: 'warning',
    expired: 'error',
    error: 'error',
    pending: 'secondary',
  };
  return <Badge variant={map[status] ?? 'secondary'}>{status.replace('_', ' ')}</Badge>;
}

function StatCard({ icon, label, value, tone }: { icon: React.ReactNode; label: string; value: number; tone: string }) {
  return (
    <Card>
      <div className="flex items-center gap-3 p-4">
        <div className={`rounded-lg p-2 ${tone}`}>{icon}</div>
        <div>
          <div className="text-2xl font-semibold">{value}</div>
          <div className="text-xs text-secondary-500">{label}</div>
        </div>
      </div>
    </Card>
  );
}

// Mirror of the backend auto rule id (helper/wslproxy-server.lua): a domain with
// no explicit rule id gets rule "opsapi-<sanitized-domain>" — so the user never
// has to know or type a "rule id".
function ruleSlug(domainName: string): string {
  const slug = (domainName || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  return 'opsapi-' + (slug || 'domain');
}

const EMPTY_FORM = {
  domain_name: '',
  registrar: '',
  dns_provider: 'cloudflare',
  cloudflare_zone_id: '',
  alert_threshold_days: 30,
  notes: '',
  // WSL Proxy routing fields (the rule id is auto-generated: opsapi-<domain>)
  environment: 'prod',
  ssl_email: '',
  proxy_target: '',
  rule_path: '/',
};

function DomainsPageContent() {
  const [domains, setDomains] = useState<Domain[]>([]);
  const [stats, setStats] = useState<DomainStats | null>(null);
  const [loading, setLoading] = useState(false);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [refreshingAll, setRefreshingAll] = useState(false);

  // Modals
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<Domain | null>(null);
  const [form, setForm] = useState({ ...EMPTY_FORM });
  const [deleteTarget, setDeleteTarget] = useState<Domain | null>(null);
  const [credOpen, setCredOpen] = useState(false);
  const [dnsTarget, setDnsTarget] = useState<Domain | null>(null);
  const [syncOpen, setSyncOpen] = useState(false);
  const [repoSyncOpen, setRepoSyncOpen] = useState(false);
  const [pipelineOpen, setPipelineOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await domainService.getDomains({
        page,
        perPage: 20,
        search: search || undefined,
        status: statusFilter,
      });
      setDomains(res.data);
      setTotalPages(res.total_pages || 1);
      setTotal(res.total || 0);
    } catch {
      toast.error('Failed to load domains');
    } finally {
      setLoading(false);
    }
  }, [page, search, statusFilter]);

  const loadStats = useCallback(async () => {
    try {
      setStats(await domainService.getStats());
    } catch {
      /* non-fatal */
    }
  }, []);

  useEffect(() => { load(); }, [load]);
  useEffect(() => { loadStats(); }, [loadStats]);

  const openCreate = () => { setEditing(null); setForm({ ...EMPTY_FORM }); setFormOpen(true); };
  const openEdit = (d: Domain) => {
    setEditing(d);
    setForm({
      domain_name: d.domain_name,
      registrar: d.registrar || '',
      dns_provider: d.dns_provider || 'cloudflare',
      cloudflare_zone_id: d.cloudflare_zone_id || '',
      alert_threshold_days: d.alert_threshold_days || 30,
      notes: d.notes || '',
      environment: d.environment || 'prod',
      ssl_email: d.ssl_email || '',
      proxy_target: d.proxy_target || '',
      rule_path: d.rule_path || '/',
    });
    setFormOpen(true);
  };

  const submitForm = async () => {
    if (!form.domain_name.trim()) { toast.error('Domain name is required'); return; }
    try {
      if (editing) {
        await domainService.updateDomain(editing.uuid, { ...form });
        toast.success('Domain updated');
      } else {
        await domainService.createDomain({ ...form });
        toast.success('Domain added');
      }
      setFormOpen(false);
      load(); loadStats();
    } catch (err) {
      // Surface the backend message (e.g. the 409 "A domain with this name
      // already exists in this namespace") instead of a generic failure.
      const serverMsg = (err as { response?: { data?: { error?: string } } })
        ?.response?.data?.error;
      toast.error(serverMsg || (err instanceof Error ? err.message : 'Save failed'));
    }
  };

  const refreshOne = async (d: Domain) => {
    const tid = toast.loading(`Checking ${d.domain_name}…`);
    try {
      await domainService.refreshExpiry(d.uuid);
      toast.success(`Checked ${d.domain_name}`, { id: tid });
      load(); loadStats();
    } catch {
      toast.error('Check failed', { id: tid });
    }
  };

  const refreshAll = async () => {
    setRefreshingAll(true);
    const tid = toast.loading('Checking all domains…');
    try {
      const s = await domainService.refreshAll();
      toast.success(`Checked ${s.checked ?? 0} — ${s.expiring_soon ?? 0} expiring, ${s.expired ?? 0} expired`, { id: tid });
      load(); loadStats();
    } catch {
      toast.error('Bulk check failed', { id: tid });
    } finally {
      setRefreshingAll(false);
    }
  };

  const confirmDelete = async () => {
    if (!deleteTarget) return;
    try {
      await domainService.deleteDomain(deleteTarget.uuid);
      toast.success('Domain deleted');
      setDeleteTarget(null);
      load(); loadStats();
    } catch {
      toast.error('Delete failed');
    }
  };

  const columns: TableColumn<Domain>[] = [
    {
      key: 'domain_name',
      header: 'Domain',
      render: (d) => (
        <div className="flex items-center gap-2">
          <Globe className="h-4 w-4 text-secondary-400" />
          <div>
            <div className="font-medium">{d.domain_name}</div>
            <div className="text-xs text-secondary-500">{d.dns_provider || '—'}</div>
          </div>
        </div>
      ),
    },
    { key: 'status', header: 'Status', render: (d) => <StatusBadge status={d.status} /> },
    {
      key: 'registration_expires_at',
      header: 'Registration',
      render: (d) => <ExpiryCell dateStr={d.registration_expires_at} threshold={d.alert_threshold_days} />,
    },
    {
      key: 'ssl_expires_at',
      header: 'SSL',
      render: (d) => <ExpiryCell dateStr={d.ssl_expires_at} threshold={d.alert_threshold_days} />,
    },
    { key: 'registrar', header: 'Registrar', render: (d) => <span className="text-sm">{d.registrar || '—'}</span> },
    {
      key: 'actions',
      header: '',
      render: (d) => (
        <div className="flex items-center justify-end gap-1">
          <button title="Check now" className="rounded p-1.5 hover:bg-secondary-100" onClick={() => refreshOne(d)}>
            <RefreshCw className="h-4 w-4" />
          </button>
          <button title="Cloudflare DNS" className="rounded p-1.5 hover:bg-secondary-100" onClick={() => setDnsTarget(d)}>
            <Cloud className="h-4 w-4" />
          </button>
          <button title="Edit" className="rounded p-1.5 hover:bg-secondary-100" onClick={() => openEdit(d)}>
            <Edit className="h-4 w-4" />
          </button>
          <button title="Delete" className="rounded p-1.5 text-error-600 hover:bg-error-50" onClick={() => setDeleteTarget(d)}>
            <Trash2 className="h-4 w-4" />
          </button>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6 p-6">
      {/* Header */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold flex items-center gap-2">
            <Globe className="h-6 w-6" /> Domains
          </h1>
          <p className="text-sm text-secondary-500">
            Registration &amp; SSL expiry monitoring, Cloudflare DNS, and k3s sync.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="secondary" onClick={() => setCredOpen(true)}>
            <KeyRound className="h-4 w-4 mr-1" /> Cloudflare Token
          </Button>
          <Button variant="secondary" onClick={() => setSettingsOpen(true)}>
            <Settings className="h-4 w-4 mr-1" /> Sync Settings
          </Button>
          <Button onClick={() => setPipelineOpen(true)}>
            <Play className="h-4 w-4 mr-1" /> Run Pipeline
          </Button>
          <Button variant="secondary" onClick={() => setRepoSyncOpen(true)}>
            <GitBranch className="h-4 w-4 mr-1" /> Sync to Repo
          </Button>
          <Button variant="secondary" onClick={() => setSyncOpen(true)}>
            <Clock className="h-4 w-4 mr-1" /> Sync Jobs
          </Button>
          <Button variant="secondary" onClick={refreshAll} disabled={refreshingAll}>
            <RefreshCw className={`h-4 w-4 mr-1 ${refreshingAll ? 'animate-spin' : ''}`} /> Check All
          </Button>
          <Button onClick={openCreate}>
            <Plus className="h-4 w-4 mr-1" /> Add Domain
          </Button>
        </div>
      </div>

      {/* Stats */}
      {stats && (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <StatCard icon={<Globe className="h-5 w-5 text-primary-600" />} label="Total domains" value={stats.total_domains} tone="bg-primary-50" />
          <StatCard icon={<Clock className="h-5 w-5 text-warning-600" />} label="Expiring soon" value={stats.expiring_soon} tone="bg-warning-50" />
          <StatCard icon={<AlertTriangle className="h-5 w-5 text-error-600" />} label="Expired" value={stats.expired} tone="bg-error-50" />
          <StatCard icon={<ShieldCheck className="h-5 w-5 text-info-600" />} label="SSL ≤ 30d" value={stats.ssl_expiring_30d} tone="bg-info-50" />
        </div>
      )}

      {/* Toolbar */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[220px]">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" />
          <Input
            className="pl-9"
            placeholder="Search domain, registrar, notes…"
            value={search}
            onChange={(e) => { setPage(1); setSearch(e.target.value); }}
          />
        </div>
        <select
          className="rounded-md border border-secondary-200 px-3 py-2 text-sm"
          value={statusFilter}
          onChange={(e) => { setPage(1); setStatusFilter(e.target.value); }}
        >
          <option value="all">All statuses</option>
          <option value="active">Active</option>
          <option value="expiring_soon">Expiring soon</option>
          <option value="expired">Expired</option>
          <option value="error">Error</option>
        </select>
      </div>

      {/* Table */}
      <Card>
        <Table<Domain>
          columns={columns}
          data={domains}
          isLoading={loading}
          emptyMessage="No domains yet. Add one to start monitoring."
          keyExtractor={(d) => d.uuid}
        />
      </Card>
      {totalPages > 1 && (
        <Pagination currentPage={page} totalPages={totalPages} totalItems={total} perPage={20} onPageChange={setPage} />
      )}

      {/* Add / Edit modal */}
      <Modal isOpen={formOpen} onClose={() => setFormOpen(false)} title={editing ? 'Edit domain' : 'Add domain'}>
        <div className="space-y-3">
          <div>
            <label className="text-sm font-medium">Domain name *</label>
            <Input
              placeholder="example.com"
              value={form.domain_name}
              disabled={!!editing}
              onChange={(e) => setForm({ ...form, domain_name: e.target.value })}
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium">DNS provider</label>
              <Input value={form.dns_provider} onChange={(e) => setForm({ ...form, dns_provider: e.target.value })} />
            </div>
            <div>
              <label className="text-sm font-medium">Registrar</label>
              <Input value={form.registrar} onChange={(e) => setForm({ ...form, registrar: e.target.value })} />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium">Cloudflare zone ID</label>
              <Input placeholder="(auto-resolved if blank)" value={form.cloudflare_zone_id} onChange={(e) => setForm({ ...form, cloudflare_zone_id: e.target.value })} />
            </div>
            <div>
              <label className="text-sm font-medium">Alert threshold (days)</label>
              <Input
                type="number"
                value={String(form.alert_threshold_days)}
                onChange={(e) => setForm({ ...form, alert_threshold_days: Number(e.target.value) || 30 })}
              />
            </div>
          </div>
          <div className="rounded border border-secondary-200 p-3 space-y-3">
            <div className="text-xs font-semibold uppercase text-secondary-500">WSL Proxy routing (repo sync)</div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium">Environment</label>
                <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.environment} onChange={(e) => setForm({ ...form, environment: e.target.value })}>
                  {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
              </div>
              <div>
                <label className="text-sm font-medium">Backend</label>
                <Input placeholder="193.237.176.232:8888" value={form.proxy_target} onChange={(e) => setForm({ ...form, proxy_target: e.target.value })} />
                <p className="mt-1 text-xs text-secondary-500">Where this domain routes — the rule&apos;s backend. Blank = the Sync Settings default backend.</p>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium">Path</label>
                <Input placeholder="/" value={form.rule_path} onChange={(e) => setForm({ ...form, rule_path: e.target.value })} />
              </div>
              <div>
                <label className="text-sm font-medium">SSL email</label>
                <Input placeholder="admin@example.com" value={form.ssl_email} onChange={(e) => setForm({ ...form, ssl_email: e.target.value })} />
              </div>
            </div>
            {/* Live preview of the rule that will be auto-created on sync — the
                user never types a "rule id". */}
            <div className="rounded bg-secondary-50 border border-secondary-200 p-2 text-xs text-secondary-600">
              Auto-created rule: <span className="font-mono text-secondary-800">{ruleSlug(form.domain_name)}</span>
              {' '}— path <span className="font-mono text-secondary-800">{form.rule_path || '/'}</span>
              {' '}→ <span className="font-mono text-secondary-800">{form.proxy_target || '(Sync Settings default backend)'}</span>
            </div>
          </div>
          <div>
            <label className="text-sm font-medium">Notes</label>
            <Input value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="secondary" onClick={() => setFormOpen(false)}>Cancel</Button>
            <Button onClick={submitForm}>{editing ? 'Save' : 'Add domain'}</Button>
          </div>
        </div>
      </Modal>

      {/* Delete confirm */}
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={confirmDelete}
        title="Delete domain"
        message={`Remove ${deleteTarget?.domain_name}? This is a soft delete.`}
        confirmText="Delete"
        variant="danger"
      />

      {credOpen && <CredentialModal onClose={() => setCredOpen(false)} />}
      {dnsTarget && <DnsModal domain={dnsTarget} onClose={() => setDnsTarget(null)} />}
      {syncOpen && <SyncModal onClose={() => setSyncOpen(false)} />}
      {repoSyncOpen && <RepoSyncModal onClose={() => setRepoSyncOpen(false)} />}
      {pipelineOpen && <PipelineModal onClose={() => setPipelineOpen(false)} />}
      {settingsOpen && <SyncSettingsModal onClose={() => setSettingsOpen(false)} />}
    </div>
  );
}

// ============================================================
// Repo URL → owner/repo/branch. Users paste a single link instead of typing
// owner + repo separately (fewer fields, no misconfiguration). Mirrors the
// backend DomainSyncSettingsQueries.parse_repo_url. Accepts https / ssh /
// github.com/owner/repo / owner/repo, with an optional /tree/<branch>.
// ============================================================
function parseRepoUrl(url: string): { owner: string; repo: string; branch?: string } | null {
  let s = (url || '').trim();
  if (!s) return null;
  s = s
    .replace(/[?#].*$/, '')
    .replace(/^git@github\.com:/i, '')
    .replace(/^ssh:\/\/git@github\.com\//i, '')
    .replace(/^\w+:\/\//, '')
    .replace(/^www\./i, '')
    .replace(/^github\.com\//i, '')
    .replace(/^\/+/, '');
  const m = s.match(/^([^/]+)\/([^/]+)/);
  if (!m) return null;
  const owner = m[1];
  const repo = m[2].replace(/\.git$/, '');
  if (!owner || !repo) return null;
  const bm = s.match(/^[^/]+\/[^/]+\/tree\/([^/]+)/);
  return { owner, repo, branch: bm?.[1] };
}

// Single "paste the repo URL" input with a live parse preview. Reused by every
// modal that used to ask for owner + repo separately.
function RepoUrlField({ value, onChange, className }: { value: string; onChange: (v: string) => void; className?: string }) {
  const parsed = parseRepoUrl(value);
  const touched = (value || '').trim() !== '';
  return (
    <div className={className}>
      <Input placeholder="Paste repo URL — https://github.com/owner/repo" value={value} onChange={(e) => onChange(e.target.value)} />
      {touched && (parsed
        ? <p className="mt-1 text-xs text-emerald-600">✓ {parsed.owner}/{parsed.repo}{parsed.branch ? ` · branch ${parsed.branch}` : ''}</p>
        : <p className="mt-1 text-xs text-red-600">Enter a full GitHub repo URL, e.g. github.com/owner/repo</p>)}
    </div>
  );
}

// ============================================================
// Sync Settings modal — configure the repo target + GitHub auth ONCE.
// ============================================================
function SyncSettingsModal({ onClose }: { onClose: () => void }) {
  const [form, setForm] = useState({ repo_url: '', branch: 'main', default_environment: 'prod', github_integration_id: '', default_backend: '', sync_rules: true });
  const [integrations, setIntegrations] = useState<GithubIntegrationLite[]>([]);
  const [integrationName, setIntegrationName] = useState<string | undefined>();
  const [authMode, setAuthMode] = useState<'existing' | 'new'>('existing');
  const [newToken, setNewToken] = useState('');
  const [newTokenName, setNewTokenName] = useState('Domain Sync');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const [s, list] = await Promise.all([
          domainService.getSyncSettings(),
          domainService.listGithubIntegrations().catch(() => []),
        ]);
        setIntegrations(list);
        setIntegrationName(s.integration_name);
        if (s.settings) {
          setForm({
            repo_url: (s.settings.owner && s.settings.repo) ? `https://github.com/${s.settings.owner}/${s.settings.repo}` : '',
            branch: s.settings.branch || 'main',
            default_environment: s.settings.default_environment || 'prod',
            github_integration_id: s.settings.github_integration_id || '',
            default_backend: s.settings.default_backend || '',
            sync_rules: s.settings.sync_rules !== false,
          });
        }
        if ((list?.length ?? 0) === 0) setAuthMode('new');
      } catch { /* first-time; leave blanks */ }
    })();
  }, []);

  const save = async () => {
    const parsed = parseRepoUrl(form.repo_url);
    if (!parsed) { toast.error('Enter a valid GitHub repository URL (e.g. https://github.com/owner/repo)'); return; }
    setSaving(true);
    try {
      // GitHub auth is OPTIONAL here — the sync target saves on its own. Only
      // send a token when the user actually typed a new one (never a blank or
      // the masked placeholder, which would otherwise trip token validation and
      // block the save); only send an integration id when one is picked.
      // We send the pasted repo_url AND the client-parsed owner/repo so the
      // save works regardless of which the backend prefers.
      const payload: Record<string, unknown> = {
        repo_url: form.repo_url.trim(), owner: parsed.owner, repo: parsed.repo,
        branch: parsed.branch || form.branch, default_environment: form.default_environment,
        default_backend: form.default_backend.trim(), sync_rules: form.sync_rules,
      };
      const token = newToken.trim();
      if (authMode === 'new' && token && token !== '********') {
        payload.github_token = token;
        payload.integration_name = (newTokenName || '').trim() || 'Domain Sync';
      } else if (authMode === 'existing' && form.github_integration_id) {
        payload.github_integration_id = form.github_integration_id;
      }
      await domainService.saveSyncSettings(payload);
      toast.success('Sync settings saved');
      onClose();
    } catch (e: unknown) {
      // Surface the real API reason (e.g. "Token validation failed: Bad
      // credentials") instead of a generic message.
      const apiMsg = (e as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(apiMsg || 'Save failed — check the token has repo Contents + Actions write');
    } finally { setSaving(false); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Domain sync settings">
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          Configure the target repo and GitHub authentication <span className="font-medium">once</span>.
          After this, “Sync to Repo” and “Run Pipeline” just work — no re-entering.
        </p>

        {/* Repo target — paste the repo URL, we work out owner/repo/branch */}
        <div className="space-y-2">
          <RepoUrlField value={form.repo_url} onChange={(v) => setForm({ ...form, repo_url: v })} />
          <div className="grid grid-cols-2 gap-2">
            <Input placeholder="branch (default main)" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
            <select className="rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.default_environment} onChange={(e) => setForm({ ...form, default_environment: e.target.value })}>
              {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
            </select>
          </div>
        </div>

        {/* Rules — a synced domain needs a backend to route to. Without a
            per-domain Proxy target, this default backend is used to generate
            the rule; leave blank + no Proxy target = server synced, no rule. */}
        <div className="rounded border border-secondary-200 p-3 space-y-2">
          <label className="flex items-center gap-2 text-sm font-medium">
            <input type="checkbox" checked={form.sync_rules} onChange={(e) => setForm({ ...form, sync_rules: e.target.checked })} />
            Generate WSL Proxy rule files
          </label>
          {form.sync_rules && (
            <>
              <Input placeholder="Default backend — e.g. 193.237.176.232:8888" value={form.default_backend} onChange={(e) => setForm({ ...form, default_backend: e.target.value })} />
              <p className="text-xs text-secondary-500">
                Used for any domain that has no <span className="font-medium">Proxy target</span> of its own. A rule needs a backend to point at — without one the rule is skipped (the server still syncs).
              </p>
            </>
          )}
        </div>

        {/* GitHub auth */}
        <div className="rounded border border-secondary-200 p-3 space-y-2">
          <div className="flex items-center gap-3 text-sm">
            <span className="font-medium">GitHub authentication</span>
            <label className="flex items-center gap-1"><input type="radio" checked={authMode === 'existing'} onChange={() => setAuthMode('existing')} /> Use existing</label>
            <label className="flex items-center gap-1"><input type="radio" checked={authMode === 'new'} onChange={() => setAuthMode('new')} /> Add token</label>
          </div>
          {authMode === 'existing' ? (
            <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })}>
              <option value="">
                {integrations.length ? (integrationName ? `Current: ${integrationName}` : 'Select an integration…') : 'No integrations — add a token'}
              </option>
              {integrations.map((i) => <option key={i.uuid} value={i.uuid}>{i.name || i.github_username || i.uuid.slice(0, 8)}</option>)}
            </select>
          ) : (
            <div className="grid grid-cols-2 gap-2">
              <Input className="col-span-2" type="password" placeholder="GitHub PAT (Contents + Actions: write)" value={newToken} onChange={(e) => setNewToken(e.target.value)} />
              <Input className="col-span-2" placeholder="label (e.g. Domain Sync)" value={newTokenName} onChange={(e) => setNewTokenName(e.target.value)} />
              <p className="col-span-2 text-xs text-secondary-500">Stored encrypted; validated against GitHub before saving.</p>
            </div>
          )}
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose}>Cancel</Button>
          <Button onClick={save} disabled={saving}>Save settings</Button>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Pipeline modal (opsapi drives: sync → dns-reconcile → wslproxy-register → auto-tag)
// ============================================================
const EMPTY_PIPELINE = { environment: 'prod', repo_url: '', branch: 'main', github_integration_id: '' };

function stepBadge(status: string) {
  const map: Record<string, 'success' | 'warning' | 'error' | 'secondary'> = {
    success: 'success', running: 'warning', failed: 'error', pending: 'secondary',
  };
  return <Badge variant={map[status] ?? 'secondary'}>{status}</Badge>;
}

function PipelineModal({ onClose }: { onClose: () => void }) {
  const [form, setForm] = useState({ ...EMPTY_PIPELINE });
  const [run, setRun] = useState<PipelineRun | null>(null);
  const [starting, setStarting] = useState(false);

  // Prefill from saved Sync Settings so the pipeline runs with one click.
  useEffect(() => {
    domainService.getSyncSettings().then((s) => {
      if (!s.settings) return;
      setForm((f) => ({
        ...f,
        environment: s.settings?.default_environment || f.environment,
        repo_url: (s.settings?.owner && s.settings?.repo) ? `https://github.com/${s.settings.owner}/${s.settings.repo}` : '',
        branch: s.settings?.branch || 'main',
        github_integration_id: s.settings?.github_integration_id || '',
      }));
    }).catch(() => {});
  }, []);

  // Poll while a run is active.
  useEffect(() => {
    if (!run || (run.status !== 'pending' && run.status !== 'running')) return;
    const t = setInterval(async () => {
      try {
        const latest = await domainService.getPipelineRun(run.uuid);
        setRun(latest);
      } catch { /* keep last */ }
    }, 4000);
    return () => clearInterval(t);
  }, [run]);

  const start = async () => {
    const parsed = parseRepoUrl(form.repo_url);
    if (!parsed) { toast.error('Enter a valid GitHub repository URL'); return; }
    if (!form.github_integration_id) { toast.error('GitHub integration id required'); return; }
    setStarting(true);
    try {
      const r = await domainService.runPipeline({
        ...form, owner: parsed.owner, repo: parsed.repo, branch: parsed.branch || form.branch,
      });
      setRun(r);
      toast.success('Pipeline started');
    } catch { toast.error('Could not start pipeline'); } finally { setStarting(false); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Run domain pipeline">
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          opsapi commits the WSL Proxy vhosts, then runs — in order, waiting for each —
          <span className="font-medium"> Cloudflare DNS reconcile → WSL Proxy register → Auto-tag (build &amp; push)</span>.
        </p>

        {!run && (
          <div className="grid grid-cols-2 gap-2">
            <select className="rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.environment} onChange={(e) => setForm({ ...form, environment: e.target.value })}>
              {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
            </select>
            <Input placeholder="branch (default main)" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
            <RepoUrlField className="col-span-2" value={form.repo_url} onChange={(v) => setForm({ ...form, repo_url: v })} />
            <Input className="col-span-2" placeholder="GitHub integration id (uuid)" value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })} />
          </div>
        )}

        {run && (
          <div className="space-y-2">
            <div className="flex items-center gap-2 text-sm">
              <span className="font-medium">Run</span>
              <span className="text-secondary-500">{run.uuid.slice(0, 8)}</span>
              {stepBadge(run.status)}
              {run.commit_sha && <span className="text-xs text-secondary-500">commit {run.commit_sha.slice(0, 7)}</span>}
            </div>
            {run.error && <div className="rounded bg-error-50 p-2 text-xs text-error-700">{run.error}</div>}
            <ol className="space-y-1">
              {run.steps.map((s) => (
                <li key={s.name} className="flex items-center justify-between rounded border border-secondary-200 px-2 py-1 text-sm">
                  <span className="flex items-center gap-2">
                    {stepBadge(s.status)}
                    <span>{s.name}</span>
                    {s.conclusion && s.conclusion !== 'success' && <span className="text-xs text-error-600">({s.conclusion})</span>}
                  </span>
                  {s.run_url && (
                    <a href={s.run_url} target="_blank" rel="noopener noreferrer" className="text-xs text-primary-600 hover:underline">view run ↗</a>
                  )}
                </li>
              ))}
            </ol>
            {s_error(run) && <div className="text-xs text-error-600">{s_error(run)}</div>}
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose}>Close</Button>
          {!run && <Button onClick={start} disabled={starting}><Play className="h-4 w-4 mr-1" /> Start</Button>}
          {run && (run.status === 'success' || run.status === 'failed') && (
            <Button onClick={() => setRun(null)}>New run</Button>
          )}
        </div>
      </div>
    </Modal>
  );
}

// Surface the failing step's error, if any.
function s_error(run: PipelineRun): string | null {
  const failed = run.steps.find((s) => s.status === 'failed' && s.error);
  return failed?.error ? `${failed.name}: ${failed.error}` : null;
}

// ============================================================
// Sync-to-repo modal (render wslproxy vhost files → commit to GitHub)
// ============================================================
const EMPTY_REPO = { environment: 'prod', repo_url: '', branch: 'main', github_integration_id: '', template_uuid: '' };

function RepoSyncModal({ onClose }: { onClose: () => void }) {
  const [form, setForm] = useState({ ...EMPTY_REPO });
  const [preview, setPreview] = useState<SyncToRepoResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [templates, setTemplates] = useState<RenderTemplate[]>([]);

  // Prefill from saved Sync Settings so no re-entry is needed.
  useEffect(() => {
    domainService.getSyncSettings().then((s) => {
      if (!s.settings) return;
      setForm((f) => ({
        ...f,
        environment: s.settings?.default_environment || f.environment,
        repo_url: (s.settings?.owner && s.settings?.repo) ? `https://github.com/${s.settings.owner}/${s.settings.repo}` : '',
        branch: s.settings?.branch || 'main',
        github_integration_id: s.settings?.github_integration_id || '',
      }));
    }).catch(() => {});
    // Domain JSON-format templates for the picker (falls back to the built-in
    // default when none is chosen).
    renderTemplatesService.list('domain_wslproxy').then(setTemplates).catch(() => setTemplates([]));
  }, []);

  const dryRun = async () => {
    const parsed = parseRepoUrl(form.repo_url);
    if (!parsed) { toast.error('Enter a valid GitHub repository URL'); return; }
    setBusy(true);
    try {
      setPreview(await domainService.syncToRepo({ ...form, owner: parsed.owner, repo: parsed.repo, branch: parsed.branch || form.branch, dry_run: true }));
    } catch { toast.error('Preview failed'); } finally { setBusy(false); }
  };

  const commit = async () => {
    const parsed = parseRepoUrl(form.repo_url);
    if (!parsed) { toast.error('Enter a valid GitHub repository URL'); return; }
    if (!form.github_integration_id) { toast.error('Select a GitHub integration id'); return; }
    setBusy(true);
    const tid = toast.loading('Opening pull request…');
    try {
      const r = await domainService.syncToRepo({ ...form, owner: parsed.owner, repo: parsed.repo, branch: parsed.branch || form.branch });
      toast.success(
        r.pr_number ? `PR #${r.pr_number} opened — ${r.count} file(s)` : `Synced ${r.count} file(s)`,
        { id: tid },
      );
      setPreview(r);
    } catch { toast.error('Sync failed — check integration & permissions', { id: tid }); } finally { setBusy(false); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Sync domains → repo (WSL Proxy vhosts)">
      <div className="space-y-3">
        <p className="text-sm text-secondary-500">
          Renders each domain in the selected environment as a WSL Proxy server file, commits them to a
          new branch off the target branch, and opens a pull request (add/update only — existing files
          are never touched, and nothing lands on the target branch without review). The GitHub token
          comes from a services GitHub integration.
        </p>
        <div className="grid grid-cols-2 gap-2">
          <select className="rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.environment} onChange={(e) => setForm({ ...form, environment: e.target.value })}>
            {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
          </select>
          <Input placeholder="target branch (PR base, default main)" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
          <RepoUrlField className="col-span-2" value={form.repo_url} onChange={(v) => setForm({ ...form, repo_url: v })} />
          <Input className="col-span-2" placeholder="GitHub integration id (uuid)" value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })} />
          <div className="col-span-2">
            <Select
              label="JSON format template"
              value={form.template_uuid}
              onChange={(e) => setForm({ ...form, template_uuid: e.target.value })}
              helperText="Pick a saved domain template, or leave as the built-in default format."
            >
              <option value="">Default (built-in WSL Proxy format)</option>
              {templates.map((t) => (
                <option key={t.uuid} value={t.uuid}>
                  {t.name}{t.is_default ? ' (default)' : ''}
                </option>
              ))}
            </Select>
          </div>
        </div>

        {preview && (
          <div className="rounded border border-secondary-200 p-2 text-sm">
            <div className="mb-1 font-medium">
              {preview.dry_run
                ? 'Preview'
                : (preview.pr_number ? `PR #${preview.pr_number} opened` : 'Synced')} — {preview.count} file(s)
              {typeof preview.rules === 'number' && <span className="ml-1 font-normal text-secondary-500">({preview.rules} rule{preview.rules === 1 ? '' : 's'})</span>}
            </div>
            {!preview.dry_run && preview.pr_url && (
              <div className="mb-2 rounded bg-emerald-50 border border-emerald-200 p-2 text-xs">
                <a href={preview.pr_url} target="_blank" rel="noopener noreferrer" className="font-medium text-emerald-700 underline">
                  Review &amp; merge pull request #{preview.pr_number} →
                </a>
                <div className="mt-0.5 text-emerald-700/80">
                  branch <code>{preview.branch}</code> → <code>{preview.base_branch}</code>
                  {preview.commit && <> · commit {preview.commit.slice(0, 7)}</>}
                </div>
              </div>
            )}
            <ul className="max-h-40 overflow-auto text-xs text-secondary-600">
              {preview.files.map((f) => <li key={f.path}>{f.path}</li>)}
            </ul>
            {preview.warnings && preview.warnings.length > 0 && (
              <div className="mt-2 rounded bg-amber-50 border border-amber-200 p-2 text-xs text-amber-800">
                <div className="font-medium">⚠ {preview.warnings.length} warning{preview.warnings.length === 1 ? '' : 's'}</div>
                <ul className="mt-1 list-disc pl-4">
                  {preview.warnings.map((w, i) => <li key={i}>{w}</li>)}
                </ul>
              </div>
            )}
          </div>
        )}

        <div className="flex justify-between pt-2">
          <Button variant="secondary" onClick={dryRun} disabled={busy}><Download className="h-4 w-4 mr-1" /> Preview</Button>
          <div className="flex gap-2">
            <Button variant="secondary" onClick={onClose}>Close</Button>
            <Button onClick={commit} disabled={busy}><GitBranch className="h-4 w-4 mr-1" /> Sync &amp; open PR</Button>
          </div>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Cloudflare credential modal
// ============================================================
function CredentialModal({ onClose }: { onClose: () => void }) {
  const [token, setToken] = useState('');
  const [hasSecret, setHasSecret] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    domainService.listCredentials()
      .then((c) => setHasSecret(c.some((x) => x.provider === 'cloudflare' && x.has_secret)))
      .catch(() => {});
  }, []);

  const save = async () => {
    if (!token.trim()) { toast.error('Enter a token'); return; }
    setSaving(true);
    try {
      await domainService.saveCredential({ provider: 'cloudflare', secret: token });
      toast.success('Cloudflare token saved (encrypted)');
      setToken(''); setHasSecret(true);
    } catch { toast.error('Save failed'); } finally { setSaving(false); }
  };

  const verify = async () => {
    try {
      const r = await domainService.verifyCloudflare();
      toast.success(r.valid ? `Token valid (${r.status ?? 'active'})` : 'Token invalid');
    } catch { toast.error('Verification failed'); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Cloudflare API token">
      <div className="space-y-3">
        <p className="text-sm text-secondary-500">
          Stored encrypted at rest (AES). Used server-side for zone &amp; DNS management.
          {hasSecret && <span className="ml-1 text-success-600">A token is already configured.</span>}
        </p>
        <Input
          type="password"
          placeholder={hasSecret ? '•••••••• (replace)' : 'CF API token'}
          value={token}
          onChange={(e) => setToken(e.target.value)}
        />
        <div className="flex justify-between pt-2">
          <Button variant="secondary" onClick={verify} disabled={!hasSecret}>Verify</Button>
          <div className="flex gap-2">
            <Button variant="secondary" onClick={onClose}>Close</Button>
            <Button onClick={save} disabled={saving}>Save token</Button>
          </div>
        </div>
      </div>
    </Modal>
  );
}

// ============================================================
// Cloudflare DNS records modal
// ============================================================
function DnsModal({ domain, onClose }: { domain: Domain; onClose: () => void }) {
  const [records, setRecords] = useState<CloudflareRecord[]>([]);
  const [zoneId, setZoneId] = useState('');
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [newRec, setNewRec] = useState({ type: 'A', name: '', content: '', ttl: 1, proxied: false });

  const load = useCallback(async () => {
    setLoading(true); setErr(null);
    try {
      const r = await domainService.listRecords(domain.uuid);
      setRecords(r.records || []); setZoneId(r.zone_id);
    } catch {
      setErr('Could not load records. Configure a Cloudflare token and ensure the zone exists.');
    } finally { setLoading(false); }
  }, [domain.uuid]);

  useEffect(() => { load(); }, [load]);

  const addRecord = async () => {
    if (!newRec.name || !newRec.content) { toast.error('Name and content required'); return; }
    try {
      await domainService.createRecord(domain.uuid, newRec);
      toast.success('Record created');
      setNewRec({ type: 'A', name: '', content: '', ttl: 1, proxied: false });
      load();
    } catch { toast.error('Create failed'); }
  };

  const del = async (id: string) => {
    try { await domainService.deleteRecord(domain.uuid, id); toast.success('Record deleted'); load(); }
    catch { toast.error('Delete failed'); }
  };

  return (
    <Modal isOpen onClose={onClose} title={`Cloudflare DNS — ${domain.domain_name}`}>
      <div className="space-y-4">
        {err && <div className="rounded bg-error-50 p-3 text-sm text-error-700">{err}</div>}
        {zoneId && <div className="text-xs text-secondary-500">Zone: {zoneId}</div>}

        {/* Add record */}
        <div className="grid grid-cols-12 gap-2 rounded border border-secondary-200 p-2">
          <select className="col-span-2 rounded border px-2 py-1 text-sm" value={newRec.type} onChange={(e) => setNewRec({ ...newRec, type: e.target.value })}>
            {['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'NS'].map((t) => <option key={t}>{t}</option>)}
          </select>
          <input className="col-span-3 rounded border px-2 py-1 text-sm" placeholder="name" value={newRec.name} onChange={(e) => setNewRec({ ...newRec, name: e.target.value })} />
          <input className="col-span-5 rounded border px-2 py-1 text-sm" placeholder="content" value={newRec.content} onChange={(e) => setNewRec({ ...newRec, content: e.target.value })} />
          <Button className="col-span-2" onClick={addRecord}><Plus className="h-4 w-4" /></Button>
        </div>

        {/* Records list */}
        <div className="max-h-72 overflow-auto">
          {loading ? (
            <div className="p-4 text-center text-sm text-secondary-500">Loading…</div>
          ) : records.length === 0 ? (
            <div className="p-4 text-center text-sm text-secondary-500">No records.</div>
          ) : (
            <table className="w-full text-sm">
              <thead><tr className="text-left text-secondary-500"><th className="p-1">Type</th><th className="p-1">Name</th><th className="p-1">Content</th><th /></tr></thead>
              <tbody>
                {records.map((r) => (
                  <tr key={r.id} className="border-t border-secondary-100">
                    <td className="p-1"><Badge variant="secondary">{r.type}</Badge></td>
                    <td className="p-1">{r.name}{r.proxied && <span className="ml-1 text-warning-600" title="Proxied">☁</span>}</td>
                    <td className="p-1 truncate max-w-[200px]" title={r.content}>{r.content}</td>
                    <td className="p-1 text-right">
                      <button className="rounded p-1 text-error-600 hover:bg-error-50" onClick={() => del(r.id)}><Trash2 className="h-4 w-4" /></button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <div className="flex justify-end"><Button variant="secondary" onClick={onClose}>Close</Button></div>
      </div>
    </Modal>
  );
}

// ============================================================
// Sync configs modal (k3s job)
// ============================================================
const EMPTY_SYNC = {
  name: '', github_repo: '', github_branch: 'main', file_path: 'domains.json',
  schedule: '0 3 * * *', github_token_secret_ref: '', opsapi_base_url: '',
};

function SyncModal({ onClose }: { onClose: () => void }) {
  const [configs, setConfigs] = useState<DomainSyncConfig[]>([]);
  const [form, setForm] = useState({ ...EMPTY_SYNC });
  const [manifest, setManifest] = useState<string | null>(null);

  const load = useCallback(async () => {
    try { setConfigs(await domainService.listSyncConfigs()); } catch { /* */ }
  }, []);
  useEffect(() => {
    let active = true;
    domainService.listSyncConfigs().then((c) => { if (active) setConfigs(c); }).catch(() => {});
    return () => { active = false; };
  }, []);

  const create = async () => {
    if (!form.name || !form.github_repo) { toast.error('Name and repo required'); return; }
    try {
      await domainService.createSyncConfig({ ...form });
      toast.success('Sync job created');
      setForm({ ...EMPTY_SYNC }); load();
    } catch { toast.error('Create failed'); }
  };

  const showManifest = async (c: DomainSyncConfig) => {
    try { setManifest((await domainService.getManifest(c.uuid)).manifest); }
    catch { toast.error('Set opsapi_base_url + github_token_secret_ref first'); }
  };

  const runNow = async (c: DomainSyncConfig) => {
    try { const r = await domainService.runNow(c.uuid); setManifest(r.manifest); toast.success('Run-once Job manifest ready — apply it to run now'); }
    catch { toast.error('Could not generate run manifest'); }
  };

  const download = () => {
    if (!manifest) return;
    const blob = new Blob([manifest], { type: 'text/yaml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = 'domain-sync.yaml'; a.click();
    URL.revokeObjectURL(url);
  };

  const del = async (c: DomainSyncConfig) => {
    try { await domainService.deleteSyncConfig(c.uuid); toast.success('Deleted'); load(); }
    catch { toast.error('Delete failed'); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Domain sync jobs (k3s)">
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          Generate a Kubernetes CronJob that pushes your domain list as JSON to a GitHub repo on a
          schedule. Secrets (GitHub PAT + opsapi token) come from a k8s Secret populated by the vault/ESO —
          never stored here.
        </p>

        {/* Existing configs */}
        {configs.length > 0 && (
          <div className="space-y-2">
            {configs.map((c) => (
              <div key={c.uuid} className="flex items-center justify-between rounded border border-secondary-200 p-2 text-sm">
                <div>
                  <div className="font-medium">{c.name}</div>
                  <div className="text-xs text-secondary-500">{c.github_repo} · {c.schedule} · last: {c.last_status || 'never'}</div>
                </div>
                <div className="flex gap-1">
                  <button title="View CronJob manifest" className="rounded p-1.5 hover:bg-secondary-100" onClick={() => showManifest(c)}><Download className="h-4 w-4" /></button>
                  <button title="Run once now" className="rounded p-1.5 hover:bg-secondary-100" onClick={() => runNow(c)}><Play className="h-4 w-4" /></button>
                  <button title="Delete" className="rounded p-1.5 text-error-600 hover:bg-error-50" onClick={() => del(c)}><Trash2 className="h-4 w-4" /></button>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* New config */}
        <div className="grid grid-cols-2 gap-2 rounded border border-secondary-200 p-3">
          <Input placeholder="Name *" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          <Input placeholder="owner/repo *" value={form.github_repo} onChange={(e) => setForm({ ...form, github_repo: e.target.value })} />
          <Input placeholder="branch" value={form.github_branch} onChange={(e) => setForm({ ...form, github_branch: e.target.value })} />
          <Input placeholder="file path (domains.json)" value={form.file_path} onChange={(e) => setForm({ ...form, file_path: e.target.value })} />
          <Input placeholder="cron (0 3 * * *)" value={form.schedule} onChange={(e) => setForm({ ...form, schedule: e.target.value })} />
          <Input placeholder="k8s Secret name (ESO)" value={form.github_token_secret_ref} onChange={(e) => setForm({ ...form, github_token_secret_ref: e.target.value })} />
          <Input className="col-span-2" placeholder="opsapi base URL (in-cluster export endpoint)" value={form.opsapi_base_url} onChange={(e) => setForm({ ...form, opsapi_base_url: e.target.value })} />
          <div className="col-span-2 flex justify-end"><Button onClick={create}><Plus className="h-4 w-4 mr-1" /> Create sync job</Button></div>
        </div>

        {/* Manifest preview */}
        {manifest && (
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-sm font-medium">Manifest</span>
              <div className="flex gap-2">
                <Button variant="secondary" onClick={download}><Download className="h-4 w-4 mr-1" /> Download</Button>
                <button className="rounded p-1 hover:bg-secondary-100" onClick={() => setManifest(null)}><X className="h-4 w-4" /></button>
              </div>
            </div>
            <pre className="max-h-64 overflow-auto rounded bg-secondary-900 p-3 text-xs text-secondary-100">{manifest}</pre>
          </div>
        )}

        <div className="flex justify-end"><Button variant="secondary" onClick={onClose}>Close</Button></div>
      </div>
    </Modal>
  );
}

export default function DomainsPage() {
  return (
    <ProtectedPage module="domains" title="Domains">
      <DomainsPageContent />
    </ProtectedPage>
  );
}
