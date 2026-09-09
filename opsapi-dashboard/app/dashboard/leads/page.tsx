'use client';

/**
 * Leads Inbox — /dashboard/leads
 *
 * A focused view of every lead captured for the CURRENT namespace, from any
 * source (public website form, API/webhook, manual entry, referral). Data is
 * namespace-scoped by the backend: crmService goes through the axios client
 * which injects the active namespace headers, and the /api/v2/crm/leads route
 * filters by the resolved tenant.
 *
 * The CRM workspace (/dashboard/crm) has a leads tab for triage alongside
 * accounts/contacts/deals; this page is the dedicated inbox for reviewing an
 * individual lead in full (the detail drawer), updating its status, and
 * converting it. Shared building blocks live in components/crm/leads-shared.
 */

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  Plus,
  Trash2,
  UserPlus,
  Mail,
  Phone,
  Briefcase,
  ArrowRightCircle,
  ChevronDown,
  RefreshCw,
  Star,
  Bell,
  CheckCircle2,
} from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import {
  crmService,
  type CrmLead,
  type CrmLeadStats,
  type CrmListParams,
} from '@/services/crm.service';
import {
  LEAD_STATUS_OPTIONS,
  LEAD_SOURCE_OPTIONS,
  LEAD_PRIORITY_OPTIONS,
  leadStatusColors,
  leadSourceLabels,
  leadPriorityColors,
  CreateLeadModal,
  ConvertLeadModal,
  LeadDetailModal,
  LeadNotificationsModal,
} from '@/components/crm/leads-shared';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const PER_PAGE = 10;

// ============================================================
// Stat card
// ============================================================

interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'info' | 'violet';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color }) => {
  const colorClasses: Record<StatCardProps['color'], string> = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    info: 'bg-blue-50 text-blue-600',
    violet: 'bg-violet-50 text-violet-600',
  };
  return (
    <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

// ============================================================
// Main content
// ============================================================

function LeadsPageContent() {
  const [leads, setLeads] = useState<CrmLead[]>([]);
  const [stats, setStats] = useState<CrmLeadStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [sourceFilter, setSourceFilter] = useState('all');
  const [priorityFilter, setPriorityFilter] = useState('all');

  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');

  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isNotifOpen, setIsNotifOpen] = useState(false);
  const [telegramActive, setTelegramActive] = useState(false); // green dot on the Notifications button
  const [isConvertOpen, setIsConvertOpen] = useState(false);
  const [convertTarget, setConvertTarget] = useState<CrmLead | null>(null);
  const [detailLead, setDetailLead] = useState<CrmLead | null>(null);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  const [deleteTarget, setDeleteTarget] = useState<CrmLead | null>(null);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  const fetchIdRef = useRef(0);

  // Debounce the search box so we issue one request after typing settles.
  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const loadStats = useCallback(async () => {
    const s = await crmService.getLeadStats().catch(() => null);
    if (s) setStats(s);
  }, []);

  // Whether Telegram alerts are live (drives the dot on the Notifications button).
  const loadNotifStatus = useCallback(async () => {
    const s = await crmService.getLeadNotificationSettings().catch(() => null);
    setTelegramActive(!!(s && s.telegram_enabled && s.has_telegram_token));
  }, []);

  useEffect(() => { loadStats(); loadNotifStatus(); }, [loadStats, loadNotifStatus]);

  const fetchLeads = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const params: CrmListParams = {
        page: currentPage,
        perPage: PER_PAGE,
        orderBy: sortColumn,
        orderDir: sortDirection,
      };
      if (debouncedSearch) params.search = debouncedSearch;
      if (statusFilter !== 'all') params.status = statusFilter;
      if (sourceFilter !== 'all') params.source = sourceFilter;
      if (priorityFilter !== 'all') params.priority = priorityFilter;

      const response = await crmService.getLeads(params);
      if (fetchId === fetchIdRef.current) {
        setLeads(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch leads:', error);
        toast.error('Failed to load leads');
      }
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, sortColumn, sortDirection, debouncedSearch, statusFilter, sourceFilter, priorityFilter]);

  useEffect(() => { fetchLeads(); }, [fetchLeads]);

  const refreshAll = useCallback(() => {
    fetchLeads();
    loadStats();
  }, [fetchLeads, loadStats]);

  const handleSort = useCallback((column: string) => {
    setSortColumn((prev) => {
      if (prev === column) {
        setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
        return prev;
      }
      setSortDirection('desc');
      return column;
    });
  }, []);

  const openDetail = useCallback((lead: CrmLead) => {
    setDetailLead(lead);
    setIsDetailOpen(true);
  }, []);

  // Quick triage: flip new ⇄ contacted from the row. Updates the header stats.
  const handleToggleContacted = useCallback(async (lead: CrmLead) => {
    const next = lead.status === 'contacted' ? 'new' : 'contacted';
    try {
      await crmService.updateLead(lead.uuid, { status: next });
      refreshAll();
    } catch {
      toast.error('Failed to update lead');
    }
  }, [refreshAll]);

  const handleConvert = useCallback((lead: CrmLead) => {
    setIsDetailOpen(false);
    setConvertTarget(lead);
    setIsConvertOpen(true);
  }, []);

  const handleDeleteClick = useCallback((lead: CrmLead) => {
    setIsDetailOpen(false);
    setDeleteTarget(lead);
    setDeleteDialogOpen(true);
  }, []);

  const handleDeleteConfirm = useCallback(async () => {
    if (!deleteTarget) return;
    setIsDeleting(true);
    try {
      await crmService.deleteLead(deleteTarget.uuid);
      toast.success('Lead deleted');
      setDeleteDialogOpen(false);
      setDeleteTarget(null);
      refreshAll();
    } catch (error) {
      console.error('Failed to delete lead:', error);
      toast.error('Failed to delete lead');
    } finally {
      setIsDeleting(false);
    }
  }, [deleteTarget, refreshAll]);

  const columns: TableColumn<CrmLead>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (lead) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-violet-100 rounded-lg flex items-center justify-center">
            <UserPlus className="w-5 h-5 text-violet-600" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{lead.first_name} {lead.last_name || ''}</p>
            {lead.company_name && <p className="text-xs text-secondary-500">{lead.company_name}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'email',
      header: 'Email',
      render: (lead) => lead.email ? (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Mail className="w-3.5 h-3.5 text-secondary-400" />
          <span>{lead.email}</span>
        </div>
      ) : <span className="text-sm text-secondary-400">--</span>,
    },
    {
      key: 'source',
      header: 'Source',
      render: (lead) => (
        <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-secondary-100 text-secondary-700">
          {leadSourceLabels[lead.source] || lead.source}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (lead) => (
        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${leadStatusColors[lead.status] || 'bg-secondary-100 text-secondary-600'}`}>
          {lead.status}
        </span>
      ),
    },
    {
      key: 'priority',
      header: 'Priority',
      render: (lead) => (
        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${leadPriorityColors[lead.priority] || 'bg-secondary-100 text-secondary-600'}`}>
          {lead.priority}
        </span>
      ),
    },
    {
      key: 'score',
      header: 'Score',
      sortable: true,
      render: (lead) => <span className="text-sm font-medium text-secondary-700">{lead.score}</span>,
    },
    {
      key: 'created_at',
      header: 'Created',
      sortable: true,
      render: (lead) => <span className="text-sm text-secondary-600">{formatDate(lead.created_at)}</span>,
    },
    {
      key: 'actions',
      header: '',
      width: 'w-32',
      render: (lead) => (
        <div className="flex items-center gap-1">
          {(lead.status === 'new' || lead.status === 'contacted') && (
            <button
              onClick={(e) => { e.stopPropagation(); handleToggleContacted(lead); }}
              className={`p-1.5 rounded-lg transition-colors ${lead.status === 'contacted' ? 'text-green-600 bg-green-50 hover:bg-green-100' : 'text-secondary-400 hover:text-green-600 hover:bg-green-50'}`}
              title={lead.status === 'contacted' ? 'Contacted — click to mark New' : 'Mark contacted'}
            >
              <CheckCircle2 className="w-4 h-4" />
            </button>
          )}
          {lead.status !== 'converted' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleConvert(lead); }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Convert to Contact"
            >
              <ArrowRightCircle className="w-4 h-4" />
            </button>
          )}
          <button
            onClick={(e) => { e.stopPropagation(); handleDeleteClick(lead); }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            title="Delete Lead"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleConvert, handleDeleteClick, handleToggleContacted]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Leads"
        description="Every enquiry captured for this workspace — website forms, API, referrals and manual entries."
        actions={
          <>
            <Button variant="secondary" onClick={refreshAll} title="Refresh">
              <RefreshCw className="w-4 h-4" />
            </Button>
            <Button variant="secondary" onClick={() => setIsNotifOpen(true)} title={telegramActive ? 'Notifications — Telegram alerts on' : 'Notifications'}>
              <span className="relative mr-1.5 inline-flex">
                <Bell className="w-4 h-4" />
                {telegramActive && (
                  <span className="absolute -top-1 -right-1 w-2 h-2 rounded-full bg-green-500 ring-2 ring-surface" />
                )}
              </span>
              Notifications
              {telegramActive && <span className="ml-1.5 hidden sm:inline text-xs font-medium text-green-600">• Telegram on</span>}
            </Button>
            <Button onClick={() => setIsCreateOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> New Lead
            </Button>
          </>
        }
      />

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4">
        <StatCard title="Total" value={stats?.total_leads ?? 0} icon={<UserPlus className="w-6 h-6" />} color="violet" />
        <StatCard title="New" value={stats?.new_leads ?? 0} icon={<Star className="w-6 h-6" />} color="info" />
        <StatCard title="Contacted" value={stats?.contacted_leads ?? 0} icon={<Phone className="w-6 h-6" />} color="warning" />
        <StatCard title="Qualified" value={stats?.qualified_leads ?? 0} icon={<Briefcase className="w-6 h-6" />} color="success" />
        <StatCard title="Conversion" value={stats ? `${stats.conversion_rate}%` : '0%'} icon={<ArrowRightCircle className="w-6 h-6" />} color="primary" />
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search leads..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <div className="relative">
            <select value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value); setCurrentPage(1); }} className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
              {LEAD_STATUS_OPTIONS.map((opt) => <option key={opt.value} value={opt.value}>{opt.label}</option>)}
            </select>
            <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
          </div>
          <div className="relative">
            <select value={sourceFilter} onChange={(e) => { setSourceFilter(e.target.value); setCurrentPage(1); }} className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
              {LEAD_SOURCE_OPTIONS.map((opt) => <option key={opt.value} value={opt.value}>{opt.label}</option>)}
            </select>
            <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
          </div>
          <div className="relative">
            <select value={priorityFilter} onChange={(e) => { setPriorityFilter(e.target.value); setCurrentPage(1); }} className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
              <option value="all">All Priority</option>
              {LEAD_PRIORITY_OPTIONS.map((opt) => <option key={opt.value} value={opt.value}>{opt.label}</option>)}
            </select>
            <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
          </div>
        </div>
      </Card>

      {/* Table */}
      <div>
        <Table
          columns={columns}
          data={leads}
          keyExtractor={(l) => l.uuid}
          onRowClick={openDetail}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No leads yet — captured enquiries will appear here."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Modals */}
      <LeadDetailModal
        isOpen={isDetailOpen}
        lead={detailLead}
        onClose={() => setIsDetailOpen(false)}
        onSaved={refreshAll}
        onConvert={handleConvert}
        onDelete={handleDeleteClick}
      />
      <CreateLeadModal isOpen={isCreateOpen} onClose={() => setIsCreateOpen(false)} onSuccess={refreshAll} />
      <LeadNotificationsModal isOpen={isNotifOpen} onClose={() => { setIsNotifOpen(false); loadNotifStatus(); }} />
      <ConvertLeadModal
        isOpen={isConvertOpen}
        onClose={() => { setIsConvertOpen(false); setConvertTarget(null); }}
        onSuccess={refreshAll}
        lead={convertTarget}
      />
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete lead"
        message={`Are you sure you want to delete "${deleteTarget?.first_name || ''} ${deleteTarget?.last_name || ''}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}

export default function LeadsPage() {
  return (
    <ProtectedPage module="crm" title="Leads">
      <LeadsPageContent />
    </ProtectedPage>
  );
}
