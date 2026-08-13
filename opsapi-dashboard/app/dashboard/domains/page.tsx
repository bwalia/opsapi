'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  Search, Plus, Trash2, Edit, RefreshCw, Globe, ShieldCheck, AlertTriangle,
  Clock, X, Cloud, GitBranch, Download, Play, KeyRound, Settings,
} from 'lucide-react';
import { Input, Table, Badge, Pagination, Card, Modal, Button, ConfirmDialog } from '@/components/ui';
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
  type WslproxyStatus,
  type WslproxyRule,
  type DomainSyncRepo,
} from '@/services/domain.service';
import { renderTemplatesService, type RenderTemplate } from '@/services/render-templates.service';
import { formatDate, cn } from '@/lib/utils';
import type { TableColumn } from '@/types';
import type { LucideIcon } from 'lucide-react';
import toast from 'react-hot-toast';

// ── Shared modal building blocks (consistent card + field styling) ──────────
const SELECT_CLS = 'w-full rounded-lg border border-secondary-300 bg-white px-3 py-2.5 text-sm text-secondary-900 hover:border-secondary-400 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20';

// A titled card section — icon chip + title + optional subtitle, then body.
function Section({ title, subtitle, icon: Icon, children, className }: {
  title?: string; subtitle?: string; icon?: LucideIcon; children: React.ReactNode; className?: string;
}) {
  return (
    <section className={cn('overflow-hidden rounded-xl border border-secondary-200', className)}>
      {title && (
        <div className="flex items-start gap-3 border-b border-secondary-100 bg-secondary-50/70 px-4 py-3">
          {Icon && (
            <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-white text-secondary-600 ring-1 ring-secondary-200">
              <Icon className="h-4 w-4" />
            </span>
          )}
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-secondary-900">{title}</h3>
            {subtitle && <p className="mt-0.5 text-xs leading-relaxed text-secondary-500">{subtitle}</p>}
          </div>
        </div>
      )}
      <div className="space-y-4 p-4">{children}</div>
    </section>
  );
}

// Label + control + helper text, evenly spaced.
function Field({ label, hint, required, children }: {
  label?: string; hint?: string; required?: boolean; children: React.ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      {label && (
        <label className="block text-sm font-medium text-secondary-700">
          {label}{required && <span className="text-error-500"> *</span>}
        </label>
      )}
      {children}
      {hint && <p className="text-xs leading-relaxed text-secondary-500">{hint}</p>}
    </div>
  );
}

// A right-aligned modal footer that sticks to the bottom of the scroll area.
function ModalFooter({ children }: { children: React.ReactNode }) {
  return (
    <div className="sticky bottom-0 -mx-6 -mb-6 mt-2 flex items-center justify-end gap-2 border-t border-secondary-200 bg-surface-elevated px-6 py-4">
      {children}
    </div>
  );
}

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
  // Attach an existing SHARED WSL Proxy rule (chosen from the live API). Blank =
  // generate a per-domain rule from the template.
  wslproxy_rule_id: '',
  // Per-domain template choice (blank = sync-level pick / built-in default)
  server_template_uuid: '',
  rule_template_uuid: '',
  // Which managed repo this domain syncs to (blank = namespace default repo)
  sync_repo_uuid: '',
};

// Attach an existing SHARED WSL Proxy rule to a domain (instead of minting one
// per domain). Self-contained: checks the namespace's WSL Proxy connection,
// offers an inline connect flow when absent, and a debounced searchable list of
// rules from the live API when present. Blank value = auto-generate a rule.
function WslproxyRulePicker({ value, onChange, environment }: { value: string; onChange: (v: string) => void; environment: string }) {
  const [status, setStatus] = useState<WslproxyStatus | null>(null);
  const [checking, setChecking] = useState(true);
  const [search, setSearch] = useState('');
  const [rules, setRules] = useState<WslproxyRule[]>([]);
  const [loadingRules, setLoadingRules] = useState(false);
  const [open, setOpen] = useState(false);
  const [connectOpen, setConnectOpen] = useState(false);
  const [conn, setConn] = useState({ api_url: '', email: '', password: '' });
  const [connecting, setConnecting] = useState(false);

  const refreshStatus = useCallback(async () => {
    setChecking(true);
    try { setStatus(await domainService.getWslproxyStatus()); }
    catch { setStatus({ connected: false }); }
    finally { setChecking(false); }
  }, []);
  useEffect(() => { refreshStatus(); }, [refreshStatus]);

  // Debounced rule search — scoped to the selected environment (fetches the
  // prod rules for prod, int rules for int, …). Re-runs when env changes.
  useEffect(() => {
    if (!status?.connected || !open) return;
    let active = true;
    setLoadingRules(true);
    const t = setTimeout(async () => {
      try { const r = await domainService.listWslproxyRules(search || undefined, environment || undefined); if (active) setRules(r); }
      catch { if (active) setRules([]); }
      finally { if (active) setLoadingRules(false); }
    }, 300);
    return () => { active = false; clearTimeout(t); };
  }, [search, status?.connected, open, environment]);

  const doConnect = async () => {
    if (!conn.api_url.trim() || !conn.password) { toast.error('API URL and password are required'); return; }
    setConnecting(true);
    try {
      await domainService.connectWslproxy(conn);
      toast.success('WSL Proxy connected');
      setConnectOpen(false);
      setConn({ api_url: '', email: '', password: '' });
      await refreshStatus();
    } catch (err) {
      const m = (err as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(m || 'Could not connect to WSL Proxy');
    } finally { setConnecting(false); }
  };

  return (
    <div>
      {checking ? (
        <p className="text-xs text-secondary-500">Checking WSL Proxy…</p>
      ) : !status?.connected ? (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-dashed border-secondary-300 bg-secondary-50 px-3 py-2.5">
          <p className="text-xs text-secondary-500">WSL Proxy isn&apos;t connected — connect it to reuse shared rules.</p>
          <Button type="button" variant="secondary" size="sm" onClick={() => setConnectOpen(true)}>Connect WSL Proxy</Button>
        </div>
      ) : value ? (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2.5">
          <div className="min-w-0">
            <div className="text-xs font-medium text-emerald-800">Attached shared rule</div>
            <div className="truncate font-mono text-sm text-emerald-900">{value}</div>
          </div>
          <Button type="button" variant="secondary" size="sm" onClick={() => onChange('')}>Change</Button>
        </div>
      ) : (
        <div className="relative">
          <Input
            placeholder={`Search ${environment} rules…`}
            value={search}
            onFocus={() => setOpen(true)}
            onChange={(e) => { setSearch(e.target.value); setOpen(true); }}
          />
          {open && (
            <div className="absolute z-20 mt-1 max-h-56 w-full overflow-auto rounded-lg border border-secondary-200 bg-white shadow-lg">
              {loadingRules ? (
                <div className="px-3 py-2 text-xs text-secondary-500">Loading…</div>
              ) : rules.length === 0 ? (
                <div className="px-3 py-2 text-xs text-secondary-500">No <span className="font-medium">{environment}</span> rules found</div>
              ) : rules.map((r) => (
                <button
                  type="button"
                  key={String(r.id)}
                  className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-secondary-50"
                  onClick={() => { onChange(String(r.id)); setOpen(false); }}
                >
                  <span className="truncate font-medium">{r.name || String(r.id)}</span>
                  <span className="shrink-0 font-mono text-xs text-secondary-400">{String(r.id).slice(0, 12)}…</span>
                </button>
              ))}
            </div>
          )}
          <p className="mt-1.5 text-xs text-secondary-500">Reuse one shared rule across servers (a single k3s ingress rule). Leave blank to auto-generate.</p>
        </div>
      )}

      <Modal isOpen={connectOpen} onClose={() => setConnectOpen(false)} title="Connect WSL Proxy" size="lg">
        <div className="space-y-5">
          <Section title="Connection" subtitle="Stored encrypted for this namespace, used only to list/fetch shared rules. The password is never shown again." icon={KeyRound}>
            <Field label="API URL" required>
              <Input placeholder="https://gateway.example.com" value={conn.api_url} onChange={(e) => setConn({ ...conn, api_url: e.target.value })} />
            </Field>
            <Field label="Email">
              <Input placeholder="admin@example.com" value={conn.email} onChange={(e) => setConn({ ...conn, email: e.target.value })} />
            </Field>
            <Field label="Password" required>
              <Input type="password" value={conn.password} onChange={(e) => setConn({ ...conn, password: e.target.value })} />
            </Field>
          </Section>
          <ModalFooter>
            <Button type="button" variant="secondary" onClick={() => setConnectOpen(false)}>Cancel</Button>
            <Button type="button" onClick={doConnect} disabled={connecting} isLoading={connecting}>Connect</Button>
          </ModalFooter>
        </div>
      </Modal>
    </div>
  );
}

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
  // Routing rule mode: attach an existing shared WSL Proxy rule, or create a new
  // one (generated from the template). Attach is the default for new domains.
  const [ruleMode, setRuleMode] = useState<'attach' | 'create'>('attach');
  const [deleteTarget, setDeleteTarget] = useState<Domain | null>(null);
  const [credOpen, setCredOpen] = useState(false);
  const [dnsTarget, setDnsTarget] = useState<Domain | null>(null);
  const [syncOpen, setSyncOpen] = useState(false);
  const [repoSyncOpen, setRepoSyncOpen] = useState(false);
  const [pipelineOpen, setPipelineOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  // Domain server/rule format templates for the per-domain pickers in the form.
  const [serverTemplates, setServerTemplates] = useState<RenderTemplate[]>([]);
  const [ruleTemplates, setRuleTemplates] = useState<RenderTemplate[]>([]);
  // Managed sync repos (for the per-domain repo picker; the default repo lives
  // in Sync Settings). Refreshed when the form opens.
  const [syncRepos, setSyncRepos] = useState<DomainSyncRepo[]>([]);

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
  useEffect(() => {
    renderTemplatesService.list('domain_wslproxy').then(setServerTemplates).catch(() => setServerTemplates([]));
    renderTemplatesService.list('domain_rule').then(setRuleTemplates).catch(() => setRuleTemplates([]));
  }, []);

  const loadSyncRepos = () => { domainService.listSyncRepos().then(setSyncRepos).catch(() => setSyncRepos([])); };
  const openCreate = () => { setEditing(null); setForm({ ...EMPTY_FORM }); setRuleMode('attach'); loadSyncRepos(); setFormOpen(true); };
  const openEdit = (d: Domain) => {
    setEditing(d);
    setRuleMode(d.wslproxy_rule_id ? 'attach' : 'create');
    loadSyncRepos();
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
      wslproxy_rule_id: d.wslproxy_rule_id || '',
      server_template_uuid: d.server_template_uuid || '',
      rule_template_uuid: d.rule_template_uuid || '',
      sync_repo_uuid: d.sync_repo_uuid || '',
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
      <Modal isOpen={formOpen} onClose={() => setFormOpen(false)} title={editing ? 'Edit domain' : 'Add domain'} size="2xl">
        <div className="space-y-4">
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
          <div className="rounded-xl border border-secondary-200 bg-secondary-50/40 p-4 space-y-4">
            <div className="flex items-center gap-2">
              <GitBranch className="h-4 w-4 text-secondary-400" />
              <div className="text-xs font-semibold uppercase tracking-wide text-secondary-500">WSL Proxy routing (repo sync)</div>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium">Environment</label>
                <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.environment} onChange={(e) => setForm({ ...form, environment: e.target.value })}>
                  {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
                <p className="mt-1 text-xs text-secondary-500">Rules are fetched and files synced for this environment.</p>
              </div>
              <div>
                <label className="text-sm font-medium">SSL email</label>
                <Input placeholder="admin@example.com" value={form.ssl_email} onChange={(e) => setForm({ ...form, ssl_email: e.target.value })} />
              </div>
            </div>

            {/* Routing rule: attach an existing shared rule OR create a new one. */}
            <div className="rounded-lg border border-secondary-200 bg-white p-3 space-y-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <label className="text-sm font-medium">Routing rule</label>
                <div className="inline-flex rounded-lg border border-secondary-200 bg-secondary-50 p-0.5 text-xs font-medium">
                  <button
                    type="button"
                    onClick={() => setRuleMode('attach')}
                    className={`rounded-md px-3 py-1 transition ${ruleMode === 'attach' ? 'bg-white text-secondary-900 shadow-sm' : 'text-secondary-500 hover:text-secondary-700'}`}
                  >Attach shared rule</button>
                  <button
                    type="button"
                    onClick={() => { setRuleMode('create'); setForm((f) => ({ ...f, wslproxy_rule_id: '' })); }}
                    className={`rounded-md px-3 py-1 transition ${ruleMode === 'create' ? 'bg-white text-secondary-900 shadow-sm' : 'text-secondary-500 hover:text-secondary-700'}`}
                  >Create new rule</button>
                </div>
              </div>

              {ruleMode === 'attach' ? (
                <WslproxyRulePicker
                  value={form.wslproxy_rule_id}
                  environment={form.environment}
                  onChange={(v) => setForm({ ...form, wslproxy_rule_id: v })}
                />
              ) : (
                <div className="space-y-3">
                  <p className="text-xs text-secondary-500">
                    Not on WSL Proxy yet? Define it here — it&apos;s generated from the template and pushed on sync.
                  </p>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="text-sm font-medium">Backend</label>
                      <Input placeholder="193.237.176.232:8888" value={form.proxy_target} onChange={(e) => setForm({ ...form, proxy_target: e.target.value })} />
                      <p className="mt-1 text-xs text-secondary-500">Where this domain routes — the rule&apos;s backend. Blank skips the rule (the server still syncs).</p>
                    </div>
                    <div>
                      <label className="text-sm font-medium">Path</label>
                      <Input placeholder="/" value={form.rule_path} onChange={(e) => setForm({ ...form, rule_path: e.target.value })} />
                    </div>
                  </div>
                  <div>
                    <label className="text-sm font-medium">Rule format template</label>
                    <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.rule_template_uuid} onChange={(e) => setForm({ ...form, rule_template_uuid: e.target.value })}>
                      <option value="">Default (built-in format)</option>
                      {ruleTemplates.map((t) => (
                        <option key={t.uuid} value={t.uuid}>{t.name}{t.is_default ? ' (default)' : ''}</option>
                      ))}
                    </select>
                  </div>
                  <div className="rounded bg-secondary-50 border border-secondary-200 p-2 text-xs text-secondary-600">
                    New rule: <span className="font-mono text-secondary-800">{ruleSlug(form.domain_name)}</span>
                    {' '}— path <span className="font-mono text-secondary-800">{form.rule_path || '/'}</span>
                    {' '}→ <span className="font-mono text-secondary-800">{form.proxy_target || '(default backend)'}</span>
                  </div>
                </div>
              )}
            </div>

            {/* Server (vhost) file format — always applies. */}
            <div>
              <label className="text-sm font-medium">Server template</label>
              <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.server_template_uuid} onChange={(e) => setForm({ ...form, server_template_uuid: e.target.value })}>
                <option value="">Default (built-in format)</option>
                {serverTemplates.map((t) => (
                  <option key={t.uuid} value={t.uuid}>{t.name}{t.is_default ? ' (default)' : ''}</option>
                ))}
              </select>
              <p className="mt-1 text-xs text-secondary-500">JSON format for this domain&apos;s server (vhost) file. Blank = built-in default.</p>
            </div>

            {/* Which repo this domain syncs to — the default repo, or one of the
                managed repos (add them in Sync Settings). You can also reassign at
                sync time in the Sync modal. */}
            <div>
              <label className="text-sm font-medium">Sync to repo</label>
              <select className="w-full rounded-md border border-secondary-200 px-3 py-2 text-sm" value={form.sync_repo_uuid} onChange={(e) => setForm({ ...form, sync_repo_uuid: e.target.value })}>
                <option value="">Default repo (Sync Settings)</option>
                {syncRepos.map((r) => (
                  <option key={r.uuid} value={r.uuid}>{r.name || `${r.owner}/${r.repo}`} ({r.owner}/{r.repo})</option>
                ))}
              </select>
            </div>
          </div>
          <div>
            <label className="text-sm font-medium">Notes</label>
            <Input value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </div>
          <ModalFooter>
            <Button variant="secondary" onClick={() => setFormOpen(false)}>Cancel</Button>
            <Button onClick={submitForm}>{editing ? 'Save changes' : 'Add domain'}</Button>
          </ModalFooter>
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
// Manage the ADDITIONAL repos a namespace syncs to (the settings row above is
// the default repo). Each repo can carry its own GitHub token.
function ReposManager({ integrations }: { integrations: GithubIntegrationLite[] }) {
  const [repos, setRepos] = useState<DomainSyncRepo[]>([]);
  const [form, setForm] = useState({ name: '', repo_url: '', branch: 'main', github_integration_id: '' });
  const [adding, setAdding] = useState(false);

  const load = () => domainService.listSyncRepos().then(setRepos).catch(() => setRepos([]));
  useEffect(() => { load(); }, []);

  const integrationName = (id?: string) => {
    const i = integrations.find((x) => x.uuid === id);
    return i ? (i.name || i.github_username || i.uuid.slice(0, 8)) : undefined;
  };

  const add = async () => {
    if (!form.repo_url.trim()) { toast.error('Paste a repository URL'); return; }
    setAdding(true);
    try {
      await domainService.createSyncRepo({
        name: form.name.trim() || undefined,
        repo_url: form.repo_url.trim(),
        branch: form.branch.trim() || 'main',
        github_integration_id: form.github_integration_id || undefined,
      });
      toast.success('Repository added');
      setForm({ name: '', repo_url: '', branch: 'main', github_integration_id: '' });
      load();
    } catch (e) {
      const m = (e as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(m || 'Could not add repository');
    } finally { setAdding(false); }
  };

  const remove = async (uuid: string) => {
    try { await domainService.deleteSyncRepo(uuid); load(); } catch { toast.error('Delete failed'); }
  };

  return (
    <Section title="Additional repositories" subtitle="Sync domains to more than one repo. Each domain picks its repo; each repo uses its own GitHub token." icon={GitBranch}>
      {repos.length > 0 && (
        <ul className="divide-y divide-secondary-100 overflow-hidden rounded-lg border border-secondary-200">
          {repos.map((r) => (
            <li key={r.uuid} className="flex items-center justify-between gap-2 px-3 py-2.5 text-sm">
              <div className="min-w-0">
                <div className="truncate font-medium text-secondary-900">{r.name || `${r.owner}/${r.repo}`}</div>
                <div className="truncate text-xs text-secondary-500">
                  {r.owner}/{r.repo} · {r.branch}
                  {r.github_integration_id ? ` · ${integrationName(r.github_integration_id) || 'token set'}` : ' · no token'}
                </div>
              </div>
              <Button variant="ghost" size="sm" onClick={() => remove(r.uuid)} aria-label="Remove repository"><Trash2 className="h-4 w-4 text-error-500" /></Button>
            </li>
          ))}
        </ul>
      )}
      <div className="space-y-3 rounded-lg border border-dashed border-secondary-300 bg-secondary-50/50 p-3">
        <Field label="Add a repository">
          <Input placeholder="Paste repo URL — https://github.com/owner/repo" value={form.repo_url} onChange={(e) => setForm({ ...form, repo_url: e.target.value })} />
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Input placeholder="name (optional)" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          <Input placeholder="branch (default main)" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
        </div>
        <select className={SELECT_CLS} value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })}>
          <option value="">GitHub token for this repo (optional)</option>
          {integrations.map((i) => <option key={i.uuid} value={i.uuid}>{i.name || i.github_username || i.uuid.slice(0, 8)}</option>)}
        </select>
        <div className="flex justify-end">
          <Button variant="secondary" size="sm" onClick={add} disabled={adding} isLoading={adding}><Plus className="mr-1 h-4 w-4" /> Add repository</Button>
        </div>
      </div>
    </Section>
  );
}

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
    <Modal isOpen onClose={onClose} title="Domain sync settings" size="xl">
      <div className="space-y-5">
        <p className="text-sm leading-relaxed text-secondary-500">
          This is your <span className="font-medium text-secondary-700">default repo</span> and GitHub auth. Add more repos below,
          then assign each domain to a repo (on its form or in the Sync modal). Rules are set per-domain — nothing to re-enter here.
        </p>

        <Section title="Default repository" subtitle="Where domains sync unless assigned to another repo." icon={GitBranch}>
          <Field label="Repository">
            <RepoUrlField value={form.repo_url} onChange={(v) => setForm({ ...form, repo_url: v })} />
          </Field>
          <div className="grid grid-cols-2 gap-4">
            <Field label="Branch">
              <Input placeholder="main" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
            </Field>
            <Field label="Default environment">
              <select className={SELECT_CLS} value={form.default_environment} onChange={(e) => setForm({ ...form, default_environment: e.target.value })}>
                {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
              </select>
            </Field>
          </div>
        </Section>

        <Section title="GitHub authentication" subtitle="Used to open the sync pull request. Stored encrypted." icon={KeyRound}>
          <div className="inline-flex rounded-lg border border-secondary-200 bg-secondary-50 p-0.5 text-xs font-medium">
            <button type="button" onClick={() => setAuthMode('existing')} className={`rounded-md px-3 py-1.5 transition ${authMode === 'existing' ? 'bg-white text-secondary-900 shadow-sm' : 'text-secondary-500 hover:text-secondary-700'}`}>Use existing</button>
            <button type="button" onClick={() => setAuthMode('new')} className={`rounded-md px-3 py-1.5 transition ${authMode === 'new' ? 'bg-white text-secondary-900 shadow-sm' : 'text-secondary-500 hover:text-secondary-700'}`}>Add token</button>
          </div>
          {authMode === 'existing' ? (
            <Field label="Integration">
              <select className={SELECT_CLS} value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })}>
                <option value="">
                  {integrations.length ? (integrationName ? `Current: ${integrationName}` : 'Select an integration…') : 'No integrations — add a token'}
                </option>
                {integrations.map((i) => <option key={i.uuid} value={i.uuid}>{i.name || i.github_username || i.uuid.slice(0, 8)}</option>)}
              </select>
            </Field>
          ) : (
            <>
              <Field label="Personal access token" hint="Needs repo Contents + Actions: write. Validated against GitHub before saving.">
                <Input type="password" placeholder="ghp_…" value={newToken} onChange={(e) => setNewToken(e.target.value)} />
              </Field>
              <Field label="Label">
                <Input placeholder="e.g. Domain Sync" value={newTokenName} onChange={(e) => setNewTokenName(e.target.value)} />
              </Field>
            </>
          )}
        </Section>

        {/* Additional repos — the multi-repo list. The default above + these are
            what a domain can be assigned to. */}
        <ReposManager integrations={integrations} />

        <ModalFooter>
          <Button variant="secondary" onClick={onClose}>Cancel</Button>
          <Button onClick={save} disabled={saving} isLoading={saving}>Save settings</Button>
        </ModalFooter>
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
    <Modal isOpen onClose={onClose} title="Run domain pipeline" size="xl">
      <div className="space-y-5">
        <p className="text-sm leading-relaxed text-secondary-500">
          opsapi commits the WSL Proxy vhosts, then runs — in order, waiting for each —
          <span className="font-medium text-secondary-700"> Cloudflare DNS reconcile → WSL Proxy register → Auto-tag (build &amp; push)</span>.
        </p>

        {!run && (
          <Section title="Target" subtitle="Defaults come from Sync Settings — override here if needed." icon={GitBranch}>
            <div className="grid grid-cols-2 gap-4">
              <Field label="Environment">
                <select className={SELECT_CLS} value={form.environment} onChange={(e) => setForm({ ...form, environment: e.target.value })}>
                  {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
              </Field>
              <Field label="Branch">
                <Input placeholder="main" value={form.branch} onChange={(e) => setForm({ ...form, branch: e.target.value })} />
              </Field>
            </div>
            <Field label="Repository">
              <RepoUrlField value={form.repo_url} onChange={(v) => setForm({ ...form, repo_url: v })} />
            </Field>
            <Field label="GitHub integration id" hint="Leave blank to use the Sync Settings integration.">
              <Input placeholder="uuid" value={form.github_integration_id} onChange={(e) => setForm({ ...form, github_integration_id: e.target.value })} />
            </Field>
          </Section>
        )}

        {run && (
          <Section title="Pipeline run" icon={Play}>
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-medium text-secondary-900">{run.uuid.slice(0, 8)}</span>
              {stepBadge(run.status)}
              {run.commit_sha && <span className="text-xs text-secondary-500">commit {run.commit_sha.slice(0, 7)}</span>}
            </div>
            {run.error && <div className="rounded-lg bg-error-50 p-2.5 text-xs text-error-700">{run.error}</div>}
            <ol className="space-y-2">
              {run.steps.map((s) => (
                <li key={s.name} className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2 text-sm">
                  <span className="flex items-center gap-2">
                    {stepBadge(s.status)}
                    <span className="font-medium text-secondary-800">{s.name}</span>
                    {s.conclusion && s.conclusion !== 'success' && <span className="text-xs text-error-600">({s.conclusion})</span>}
                  </span>
                  {s.run_url && (
                    <a href={s.run_url} target="_blank" rel="noopener noreferrer" className="text-xs font-medium text-primary-600 hover:underline">view run ↗</a>
                  )}
                </li>
              ))}
            </ol>
            {s_error(run) && <div className="text-xs text-error-600">{s_error(run)}</div>}
          </Section>
        )}

        <ModalFooter>
          <Button variant="secondary" onClick={onClose}>Close</Button>
          {!run && <Button onClick={start} disabled={starting} isLoading={starting}><Play className="mr-1 h-4 w-4" /> Start pipeline</Button>}
          {run && (run.status === 'success' || run.status === 'failed') && (
            <Button onClick={() => setRun(null)}>New run</Button>
          )}
        </ModalFooter>
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
type SyncDomain = Pick<Domain, 'uuid' | 'domain_name' | 'environment' | 'sync_repo_uuid'>;

function RepoSyncModal({ onClose }: { onClose: () => void }) {
  const [environment, setEnvironment] = useState('prod');
  const [domains, setDomains] = useState<SyncDomain[]>([]);
  const [repos, setRepos] = useState<DomainSyncRepo[]>([]);
  const [defaultRepo, setDefaultRepo] = useState<{ owner?: string; repo?: string } | null>(null);
  const [assignments, setAssignments] = useState<Record<string, string>>({});
  const [selected, setSelected] = useState<Record<string, boolean>>({});
  const [preview, setPreview] = useState<SyncToRepoResult | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);

  // Load the default repo (Sync Settings), the managed repos, and every domain
  // (assignment + selection seeded from each domain's stored repo).
  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        const [s, r, list] = await Promise.all([
          domainService.getSyncSettings(),
          domainService.listSyncRepos().catch(() => []),
          domainService.listAllDomains(),
        ]);
        setRepos(r);
        if (s.settings) {
          setEnvironment(s.settings.default_environment || 'prod');
          setDefaultRepo({ owner: s.settings.owner, repo: s.settings.repo });
        }
        setDomains(list);
        const a: Record<string, string> = {};
        const sel: Record<string, boolean> = {};
        list.forEach((d) => { a[d.uuid] = d.sync_repo_uuid || ''; sel[d.uuid] = true; });
        setAssignments(a);
        setSelected(sel);
      } catch { toast.error('Failed to load domains'); } finally { setLoading(false); }
    })();
  }, []);

  const envDomains = domains.filter((d) => (d.environment || 'prod') === environment);
  const selectedUuids = envDomains.filter((d) => selected[d.uuid]).map((d) => d.uuid);
  const allChecked = envDomains.length > 0 && envDomains.every((d) => selected[d.uuid]);
  const defaultLabel = defaultRepo?.owner && defaultRepo?.repo
    ? `Default (${defaultRepo.owner}/${defaultRepo.repo})`
    : 'Default (set in Sync Settings)';

  const toggleAll = (v: boolean) =>
    setSelected((prev) => { const n = { ...prev }; envDomains.forEach((d) => { n[d.uuid] = v; }); return n; });

  const assignmentsFor = (uuids: string[]) => {
    const asg: Record<string, string> = {};
    uuids.forEach((u) => { asg[u] = assignments[u] || ''; });
    return asg;
  };

  // Live preview: a READ-ONLY dry-run that re-runs (debounced) whenever the
  // selection, per-domain repo, or environment changes — so the preview ALWAYS
  // matches exactly what "Sync" would push. Keyed on a stable signature so that
  // setPreview() (which changes `preview`) does not retrigger this effect.
  const previewSig = `${environment}|${selectedUuids.map((u) => `${u}:${assignments[u] || ''}`).sort().join(',')}`;
  useEffect(() => {
    if (loading) return;
    if (selectedUuids.length === 0) { setPreview(null); setPreviewing(false); return; }
    let active = true;
    setPreviewing(true);
    const uuids = selectedUuids;
    const t = setTimeout(async () => {
      try {
        const r = await domainService.syncToRepo({ environment, dry_run: true, domain_uuids: uuids, assignments: assignmentsFor(uuids) });
        if (active) setPreview(r);
      } catch { if (active) setPreview(null); }
      finally { if (active) setPreviewing(false); }
    }, 400);
    return () => { active = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewSig, loading]);

  const runSync = async () => {
    if (selectedUuids.length === 0) { toast.error('Select at least one domain to sync'); return; }
    setBusy(true);
    const tid = toast.loading('Opening pull requests…');
    try {
      const r = await domainService.syncToRepo({ environment, dry_run: false, domain_uuids: selectedUuids, assignments: assignmentsFor(selectedUuids) });
      setPreview(r);
      const okCount = r.repos.filter((g) => g.ok).length;
      const prs = r.repos.filter((g) => g.ok && g.pr_number).map((g) => `#${g.pr_number}`);
      toast[r.any_failed ? 'error' : 'success'](
        r.any_failed
          ? `Synced ${okCount}/${r.repos.length} repo(s) — some failed`
          : (prs.length ? `Opened PR ${prs.join(', ')} across ${okCount} repo(s)` : `Synced ${okCount} repo(s)`),
        { id: tid },
      );
    } catch {
      toast.error('Sync failed — check repo & token', { id: tid });
    } finally { setBusy(false); }
  };

  return (
    <Modal isOpen onClose={onClose} title="Sync domains → repos" size="2xl">
      <div className="space-y-4">
        <p className="text-sm text-secondary-500">
          Pick which domains to sync and the repo each goes to. Domains are grouped by repo and one pull
          request is opened per repo (add/update only — nothing lands without review). Add or edit repos in{' '}
          <span className="font-medium">Sync Settings</span>.
        </p>

        <div className="flex flex-wrap items-center gap-3">
          <label className="text-sm font-medium">Environment</label>
          <select className="rounded-md border border-secondary-200 px-3 py-2 text-sm" value={environment} onChange={(e) => setEnvironment(e.target.value)}>
            {['prod', 'acc', 'test', 'int', 'dev'].map((x) => <option key={x} value={x}>{x}</option>)}
          </select>
          <span className="text-xs text-secondary-500">{envDomains.length} domain{envDomains.length === 1 ? '' : 's'} · {selectedUuids.length} selected</span>
        </div>

        <div className="overflow-hidden rounded-lg border border-secondary-200">
          <div className="grid grid-cols-[auto_1fr_minmax(170px,240px)] items-center gap-2 border-b border-secondary-200 bg-secondary-50 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">
            <input type="checkbox" checked={allChecked} onChange={(e) => toggleAll(e.target.checked)} />
            <span>Domain</span>
            <span>Sync to repo</span>
          </div>
          <div className="max-h-72 divide-y divide-secondary-100 overflow-auto">
            {loading ? (
              <div className="px-3 py-6 text-center text-sm text-secondary-500">Loading…</div>
            ) : envDomains.length === 0 ? (
              <div className="px-3 py-6 text-center text-sm text-secondary-500">No domains in <span className="font-medium">{environment}</span>.</div>
            ) : envDomains.map((d) => (
              <div key={d.uuid} className="grid grid-cols-[auto_1fr_minmax(170px,240px)] items-center gap-2 px-3 py-2 text-sm">
                <input type="checkbox" checked={!!selected[d.uuid]} onChange={(e) => setSelected({ ...selected, [d.uuid]: e.target.checked })} />
                <span className="truncate font-medium">{d.domain_name}</span>
                <select className="rounded-md border border-secondary-200 px-2 py-1.5 text-sm" value={assignments[d.uuid] || ''} onChange={(e) => setAssignments({ ...assignments, [d.uuid]: e.target.value })}>
                  <option value="">{defaultLabel}</option>
                  {repos.map((r) => <option key={r.uuid} value={r.uuid}>{r.name || `${r.owner}/${r.repo}`}</option>)}
                </select>
              </div>
            ))}
          </div>
        </div>

        {!preview && (
          <div className="rounded-lg border border-dashed border-secondary-200 bg-secondary-50/50 px-3 py-4 text-center text-xs text-secondary-500">
            {selectedUuids.length === 0 ? 'Select at least one domain to preview the sync.' : (previewing ? 'Building preview…' : 'Preview will appear here.')}
          </div>
        )}

        {preview && (
          <div className="space-y-2">
            <div className="flex items-center gap-2 text-sm font-medium">
              {preview.dry_run ? 'Preview' : 'Sync result'} — {preview.repos.length} repo{preview.repos.length === 1 ? '' : 's'}
              {preview.any_failed && <span className="font-normal text-red-600">(some failed)</span>}
              {previewing && <span className="font-normal text-secondary-400">· updating…</span>}
            </div>
            {preview.repos.map((g, gi) => (
              <div key={`${g.repo}@${g.branch}-${gi}`} className="rounded border border-secondary-200 p-2 text-sm">
                <div className="mb-1 font-medium">
                  {g.repo_name && <span className="mr-1 text-secondary-700">{g.repo_name}:</span>}
                  <code>{g.repo}</code> → <code>{g.branch}</code>
                  {' '}— {g.count ?? 0} file(s)
                  {typeof g.rules === 'number' && <span className="ml-1 font-normal text-secondary-500">({g.rules} rule{g.rules === 1 ? '' : 's'})</span>}
                  {!preview.dry_run && (g.ok
                    ? <span className="ml-2 text-emerald-700">✓ {g.pr_number ? `PR #${g.pr_number}` : 'synced'}</span>
                    : <span className="ml-2 text-red-600">✗ failed</span>)}
                </div>
                {!preview.dry_run && g.ok && g.pr_url && (
                  <div className="mb-2 rounded bg-emerald-50 border border-emerald-200 p-2 text-xs">
                    <a href={g.pr_url} target="_blank" rel="noopener noreferrer" className="font-medium text-emerald-700 underline">
                      Review &amp; merge pull request #{g.pr_number} →
                    </a>
                    <div className="mt-0.5 text-emerald-700/80">
                      branch <code>{g.head_branch}</code> → <code>{g.base_branch}</code>
                      {g.commit && <> · commit {g.commit.slice(0, 7)}</>}
                    </div>
                  </div>
                )}
                {!g.ok && g.error && (
                  <div className="mb-2 rounded bg-red-50 border border-red-200 p-2 text-xs text-red-700">{g.error}</div>
                )}
                {g.files && g.files.length > 0 && (
                  <ul className="max-h-40 overflow-auto text-xs text-secondary-600">
                    {g.files.map((f) => <li key={f.path}>{f.path}</li>)}
                  </ul>
                )}
                {g.skipped && g.skipped.length > 0 && (
                  <div className="mt-2 rounded bg-secondary-50 border border-secondary-200 p-2 text-xs text-secondary-600">
                    <div className="font-medium">↩ {g.skipped.length} shared rule{g.skipped.length === 1 ? '' : 's'} already in repo (reused, not re-pushed)</div>
                    <ul className="mt-1 list-disc pl-4">
                      {g.skipped.map((s) => <li key={s.path}>{s.rule_id}</li>)}
                    </ul>
                  </div>
                )}
                {g.warnings && g.warnings.length > 0 && (
                  <div className="mt-2 rounded bg-amber-50 border border-amber-200 p-2 text-xs text-amber-800">
                    <div className="font-medium">⚠ {g.warnings.length} warning{g.warnings.length === 1 ? '' : 's'}</div>
                    <ul className="mt-1 list-disc pl-4">
                      {g.warnings.map((w, i) => <li key={i}>{w}</li>)}
                    </ul>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        <ModalFooter>
          <span className="mr-auto text-xs text-secondary-500">{selectedUuids.length} domain{selectedUuids.length === 1 ? '' : 's'} selected · preview updates live</span>
          <Button variant="secondary" onClick={onClose}>Close</Button>
          <Button onClick={runSync} disabled={busy || loading || selectedUuids.length === 0} isLoading={busy}><GitBranch className="mr-1 h-4 w-4" /> Sync selected &amp; open PRs</Button>
        </ModalFooter>
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
    <Modal isOpen onClose={onClose} title="Cloudflare API token" size="lg">
      <div className="space-y-5">
        <Section title="API token" subtitle="Stored encrypted at rest (AES). Used server-side for zone & DNS management." icon={Cloud}>
          {hasSecret && (
            <div className="flex items-center gap-2 rounded-lg border border-success-200 bg-success-50 px-3 py-2 text-xs text-success-700">
              <ShieldCheck className="h-4 w-4" /> A token is already configured.
            </div>
          )}
          <Field label="Token" hint="Zone: read · DNS: edit for the domains you manage.">
            <Input
              type="password"
              placeholder={hasSecret ? '•••••••• (replace)' : 'CF API token'}
              value={token}
              onChange={(e) => setToken(e.target.value)}
            />
          </Field>
        </Section>

        <ModalFooter>
          <Button variant="secondary" onClick={verify} disabled={!hasSecret} className="mr-auto">Verify</Button>
          <Button variant="secondary" onClick={onClose}>Close</Button>
          <Button onClick={save} disabled={saving} isLoading={saving}>Save token</Button>
        </ModalFooter>
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
    <Modal isOpen onClose={onClose} title={`Cloudflare DNS — ${domain.domain_name}`} size="2xl">
      <div className="space-y-5">
        {err && <div className="rounded-lg border border-error-200 bg-error-50 p-3 text-sm text-error-700">{err}</div>}

        <Section title="Add record" subtitle={zoneId ? `Zone ${zoneId}` : undefined} icon={Cloud}>
          <div className="grid grid-cols-12 gap-3">
            <select className={cn(SELECT_CLS, 'col-span-3')} value={newRec.type} onChange={(e) => setNewRec({ ...newRec, type: e.target.value })}>
              {['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'NS'].map((t) => <option key={t}>{t}</option>)}
            </select>
            <Input className="col-span-4" placeholder="name" value={newRec.name} onChange={(e) => setNewRec({ ...newRec, name: e.target.value })} />
            <Input className="col-span-5" placeholder="content" value={newRec.content} onChange={(e) => setNewRec({ ...newRec, content: e.target.value })} />
            <div className="col-span-12 flex justify-end">
              <Button size="sm" onClick={addRecord}><Plus className="mr-1 h-4 w-4" /> Add record</Button>
            </div>
          </div>
        </Section>

        {/* Records list */}
        <div className="overflow-hidden rounded-xl border border-secondary-200">
          <div className="max-h-72 overflow-auto">
            {loading ? (
              <div className="p-6 text-center text-sm text-secondary-500">Loading…</div>
            ) : records.length === 0 ? (
              <div className="p-6 text-center text-sm text-secondary-500">No DNS records yet.</div>
            ) : (
              <table className="w-full text-sm">
                <thead className="bg-secondary-50/70 text-left text-xs font-semibold uppercase tracking-wide text-secondary-500">
                  <tr><th className="px-3 py-2">Type</th><th className="px-3 py-2">Name</th><th className="px-3 py-2">Content</th><th className="px-3 py-2" /></tr>
                </thead>
                <tbody>
                  {records.map((r) => (
                    <tr key={r.id} className="border-t border-secondary-100">
                      <td className="px-3 py-2"><Badge variant="secondary">{r.type}</Badge></td>
                      <td className="px-3 py-2">{r.name}{r.proxied && <span className="ml-1 text-warning-600" title="Proxied">☁</span>}</td>
                      <td className="max-w-60 truncate px-3 py-2" title={r.content}>{r.content}</td>
                      <td className="px-3 py-2 text-right">
                        <button className="rounded-lg p-1.5 text-error-600 hover:bg-error-50" onClick={() => del(r.id)} aria-label="Delete record"><Trash2 className="h-4 w-4" /></button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>

        <ModalFooter>
          <Button variant="secondary" onClick={onClose}>Close</Button>
        </ModalFooter>
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
    <Modal isOpen onClose={onClose} title="Domain sync jobs (k3s)" size="2xl">
      <div className="space-y-5">
        <p className="text-sm leading-relaxed text-secondary-500">
          Generate a Kubernetes CronJob that pushes your domain list as JSON to a GitHub repo on a
          schedule. Secrets (GitHub PAT + opsapi token) come from a k8s Secret populated by the vault/ESO —
          never stored here.
        </p>

        {configs.length > 0 && (
          <Section title="Scheduled jobs" icon={Clock}>
            <ul className="divide-y divide-secondary-100 overflow-hidden rounded-lg border border-secondary-200">
              {configs.map((c) => (
                <li key={c.uuid} className="flex items-center justify-between gap-2 px-3 py-2.5 text-sm">
                  <div className="min-w-0">
                    <div className="truncate font-medium text-secondary-900">{c.name}</div>
                    <div className="truncate text-xs text-secondary-500">{c.github_repo} · {c.schedule} · last: {c.last_status || 'never'}</div>
                  </div>
                  <div className="flex gap-1">
                    <button title="View CronJob manifest" className="rounded-lg p-1.5 hover:bg-secondary-100" onClick={() => showManifest(c)}><Download className="h-4 w-4" /></button>
                    <button title="Run once now" className="rounded-lg p-1.5 hover:bg-secondary-100" onClick={() => runNow(c)}><Play className="h-4 w-4" /></button>
                    <button title="Delete" className="rounded-lg p-1.5 text-error-600 hover:bg-error-50" onClick={() => del(c)}><Trash2 className="h-4 w-4" /></button>
                  </div>
                </li>
              ))}
            </ul>
          </Section>
        )}

        <Section title="New sync job" icon={Plus}>
          <div className="grid grid-cols-2 gap-3">
            <Input placeholder="Name *" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <Input placeholder="owner/repo *" value={form.github_repo} onChange={(e) => setForm({ ...form, github_repo: e.target.value })} />
            <Input placeholder="branch" value={form.github_branch} onChange={(e) => setForm({ ...form, github_branch: e.target.value })} />
            <Input placeholder="file path (domains.json)" value={form.file_path} onChange={(e) => setForm({ ...form, file_path: e.target.value })} />
            <Input placeholder="cron (0 3 * * *)" value={form.schedule} onChange={(e) => setForm({ ...form, schedule: e.target.value })} />
            <Input placeholder="k8s Secret name (ESO)" value={form.github_token_secret_ref} onChange={(e) => setForm({ ...form, github_token_secret_ref: e.target.value })} />
            <Input className="col-span-2" placeholder="opsapi base URL (in-cluster export endpoint)" value={form.opsapi_base_url} onChange={(e) => setForm({ ...form, opsapi_base_url: e.target.value })} />
            <div className="col-span-2 flex justify-end"><Button size="sm" onClick={create}><Plus className="mr-1 h-4 w-4" /> Create sync job</Button></div>
          </div>
        </Section>

        {manifest && (
          <Section title="Manifest" icon={Download}>
            <div className="flex items-center justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={download}><Download className="mr-1 h-4 w-4" /> Download</Button>
              <button className="rounded-lg p-1.5 hover:bg-secondary-100" onClick={() => setManifest(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button>
            </div>
            <pre className="max-h-64 overflow-auto rounded-lg bg-secondary-900 p-3 text-xs text-secondary-100">{manifest}</pre>
          </Section>
        )}

        <ModalFooter>
          <Button variant="secondary" onClick={onClose}>Close</Button>
        </ModalFooter>
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
