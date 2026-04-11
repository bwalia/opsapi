'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import {
  Search,
  FileText,
  Filter,
  TrendingUp,
  Clock,
  CheckCircle,
  AlertTriangle,
  RefreshCw,
  X,
  ChevronDown,
  Plus,
  DollarSign,
} from 'lucide-react';
import { Input, Table, Pagination, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  invoicesService,
  type InvoiceFilters,
  type InvoiceDashboardStats,
  type Invoice,
  type InvoiceStatus,
  type InvoicePayload,
} from '@/services/invoices.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

// Stats card component
interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'danger' | 'info';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    danger: 'bg-red-50 text-red-600',
    info: 'bg-blue-50 text-blue-600',
  };

  return (
    <div className="bg-white rounded-xl border border-secondary-200 p-5 shadow-sm">
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

// Invoice status options
const INVOICE_STATUS_OPTIONS: { value: InvoiceStatus | 'all'; label: string }[] = [
  { value: 'all', label: 'All Status' },
  { value: 'draft', label: 'Draft' },
  { value: 'sent', label: 'Sent' },
  { value: 'paid', label: 'Paid' },
  { value: 'partially_paid', label: 'Partially Paid' },
  { value: 'overdue', label: 'Overdue' },
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'void', label: 'Void' },
];

// Status badge component
const InvoiceStatusBadge: React.FC<{ status: InvoiceStatus }> = ({ status }) => {
  const config: Record<InvoiceStatus, { label: string; classes: string }> = {
    draft: { label: 'Draft', classes: 'bg-gray-100 text-gray-700' },
    sent: { label: 'Sent', classes: 'bg-blue-100 text-blue-700' },
    paid: { label: 'Paid', classes: 'bg-green-100 text-green-700' },
    partially_paid: { label: 'Partially Paid', classes: 'bg-yellow-100 text-yellow-700' },
    overdue: { label: 'Overdue', classes: 'bg-red-100 text-red-700' },
    cancelled: { label: 'Cancelled', classes: 'bg-gray-100 text-gray-700' },
    void: { label: 'Void', classes: 'bg-gray-100 text-gray-500' },
  };

  const { label, classes } = config[status] || { label: status, classes: 'bg-gray-100 text-gray-700' };

  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${classes}`}>
      {label}
    </span>
  );
};

// Create Invoice Modal
interface CreateInvoiceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

const CreateInvoiceModal: React.FC<CreateInvoiceModalProps> = ({ isOpen, onClose, onCreated }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState<InvoicePayload>({
    customer_name: '',
    customer_email: '',
    issue_date: new Date().toISOString().split('T')[0],
    due_date: '',
    currency: 'USD',
    notes: '',
    payment_terms_days: 30,
  });

  // Set default due date based on payment terms
  useEffect(() => {
    if (formData.payment_terms_days && formData.issue_date) {
      const issueDate = new Date(formData.issue_date);
      issueDate.setDate(issueDate.getDate() + formData.payment_terms_days);
      setFormData((prev) => ({ ...prev, due_date: issueDate.toISOString().split('T')[0] }));
    }
  }, [formData.payment_terms_days, formData.issue_date]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.customer_name.trim()) {
      toast.error('Customer name is required');
      return;
    }

    if (!formData.due_date) {
      toast.error('Due date is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await invoicesService.createInvoice(formData);
      toast.success('Invoice created successfully');
      onCreated();
      onClose();
      // Reset form
      setFormData({
        customer_name: '',
        customer_email: '',
        issue_date: new Date().toISOString().split('T')[0],
        due_date: '',
        currency: 'USD',
        notes: '',
        payment_terms_days: 30,
      });
    } catch (error) {
      console.error('Failed to create invoice:', error);
      toast.error('Failed to create invoice');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Invoice">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Customer Name */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Customer Name *</label>
          <input
            type="text"
            value={formData.customer_name}
            onChange={(e) => setFormData((prev) => ({ ...prev, customer_name: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="Enter customer name"
            required
          />
        </div>

        {/* Customer Email */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Customer Email</label>
          <input
            type="email"
            value={formData.customer_email}
            onChange={(e) => setFormData((prev) => ({ ...prev, customer_email: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="Enter customer email"
          />
        </div>

        {/* Date Fields */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Issue Date *</label>
            <input
              type="date"
              value={formData.issue_date}
              onChange={(e) => setFormData((prev) => ({ ...prev, issue_date: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              required
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Due Date *</label>
            <input
              type="date"
              value={formData.due_date}
              onChange={(e) => setFormData((prev) => ({ ...prev, due_date: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              required
            />
          </div>
        </div>

        {/* Currency & Payment Terms */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
            <select
              value={formData.currency}
              onChange={(e) => setFormData((prev) => ({ ...prev, currency: e.target.value }))}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
            >
              <option value="USD">USD</option>
              <option value="EUR">EUR</option>
              <option value="GBP">GBP</option>
              <option value="CAD">CAD</option>
              <option value="AUD">AUD</option>
              <option value="INR">INR</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Payment Terms (days)</label>
            <input
              type="number"
              value={formData.payment_terms_days || ''}
              onChange={(e) =>
                setFormData((prev) => ({ ...prev, payment_terms_days: parseInt(e.target.value) || undefined }))
              }
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              placeholder="30"
              min="0"
            />
          </div>
        </div>

        {/* Notes */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Notes</label>
          <textarea
            value={formData.notes}
            onChange={(e) => setFormData((prev) => ({ ...prev, notes: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            rows={3}
            placeholder="Additional notes..."
          />
        </div>

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Creating...' : 'Create Invoice'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

function InvoicesPageContent() {
  const router = useRouter();

  // State
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [stats, setStats] = useState<InvoiceDashboardStats | null>(null);
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);

  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<InvoiceStatus | 'all'>('all');
  const [showFilters, setShowFilters] = useState(false);
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');

  // Pagination & Sorting
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState<string>('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const perPage = 10;

  // Refs
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Fetch invoices with debounced search
  const fetchInvoices = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const filters: InvoiceFilters = {
        page: currentPage,
        perPage,
        orderBy: sortColumn as InvoiceFilters['orderBy'],
        orderDir: sortDirection,
      };

      if (searchQuery.trim()) filters.search = searchQuery.trim();
      if (statusFilter !== 'all') filters.status = statusFilter;
      if (dateFrom) filters.dateFrom = dateFrom;
      if (dateTo) filters.dateTo = dateTo;

      const response = await invoicesService.getInvoices(filters);

      if (fetchId === fetchIdRef.current) {
        setInvoices(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch invoices:', error);
        toast.error('Failed to load invoices');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, searchQuery, statusFilter, dateFrom, dateTo]);

  // Fetch stats on mount
  useEffect(() => {
    const loadStats = async () => {
      try {
        const statsData = await invoicesService.getDashboardStats();
        setStats(statsData);
      } catch (error) {
        console.error('Failed to load invoice stats:', error);
      }
    };
    loadStats();
  }, []);

  // Fetch invoices when filters change
  useEffect(() => {
    fetchInvoices();
  }, [fetchInvoices]);

  // Debounced search handler
  const handleSearchChange = useCallback((value: string) => {
    setSearchQuery(value);
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }
    searchTimeoutRef.current = setTimeout(() => {
      setCurrentPage(1);
    }, 300);
  }, []);

  // Sort handler
  const handleSort = useCallback((column: string) => {
    setSortColumn((prev) => {
      if (prev === column) {
        setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
        return column;
      }
      setSortDirection('asc');
      return column;
    });
    setCurrentPage(1);
  }, []);

  // Navigate to invoice detail
  const handleViewInvoice = useCallback(
    (invoice: Invoice) => {
      router.push(`/dashboard/invoices/${invoice.uuid}`);
    },
    [router]
  );

  // Clear all filters
  const clearFilters = useCallback(() => {
    setSearchQuery('');
    setStatusFilter('all');
    setDateFrom('');
    setDateTo('');
    setCurrentPage(1);
  }, []);

  // Check if any filters are active
  const hasActiveFilters = useMemo(() => {
    return (
      searchQuery.trim() !== '' ||
      statusFilter !== 'all' ||
      dateFrom !== '' ||
      dateTo !== ''
    );
  }, [searchQuery, statusFilter, dateFrom, dateTo]);

  // Handle invoice created
  const handleInvoiceCreated = useCallback(() => {
    fetchInvoices();
    // Refresh stats
    invoicesService.getDashboardStats().then(setStats).catch(console.error);
  }, [fetchInvoices]);

  // Table columns
  const columns: TableColumn<Invoice>[] = useMemo(
    () => [
      {
        key: 'invoice_number',
        header: 'Invoice #',
        sortable: true,
        render: (invoice) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
              <FileText className="w-5 h-5 text-secondary-500" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">
                {invoice.invoice_number || invoice.uuid.slice(0, 8)}
              </p>
            </div>
          </div>
        ),
      },
      {
        key: 'customer_name',
        header: 'Customer',
        render: (invoice) => (
          <div>
            <p className="text-sm font-medium text-secondary-900">{invoice.customer_name || 'N/A'}</p>
            {invoice.customer_email && (
              <p className="text-xs text-secondary-500">{invoice.customer_email}</p>
            )}
          </div>
        ),
      },
      {
        key: 'status',
        header: 'Status',
        render: (invoice) => <InvoiceStatusBadge status={invoice.status} />,
      },
      {
        key: 'issue_date',
        header: 'Issue Date',
        sortable: true,
        render: (invoice) => (
          <span className="text-sm text-secondary-700">{formatDate(invoice.issue_date)}</span>
        ),
      },
      {
        key: 'due_date',
        header: 'Due Date',
        sortable: true,
        render: (invoice) => (
          <span className="text-sm text-secondary-700">{formatDate(invoice.due_date)}</span>
        ),
      },
      {
        key: 'total',
        header: 'Total',
        sortable: true,
        render: (invoice) => (
          <span className="font-semibold text-secondary-900">
            {formatCurrency(invoice.total, invoice.currency)}
          </span>
        ),
      },
      {
        key: 'balance_due',
        header: 'Balance Due',
        render: (invoice) => (
          <span
            className={`font-semibold ${
              invoice.balance_due > 0 ? 'text-red-600' : 'text-green-600'
            }`}
          >
            {formatCurrency(invoice.balance_due, invoice.currency)}
          </span>
        ),
      },
    ],
    []
  );

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Invoices</h1>
          <p className="text-secondary-500 mt-1">Manage and track your invoices</p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => fetchInvoices()}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
          <button
            onClick={() => setIsCreateModalOpen(true)}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
          >
            <Plus className="w-4 h-4" />
            Create Invoice
          </button>
        </div>
      </div>

      {/* Stats Cards */}
      {stats && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            title="Total Invoiced"
            value={formatCurrency(stats.total_invoiced)}
            icon={<DollarSign className="w-6 h-6" />}
            color="primary"
          />
          <StatCard
            title="Paid"
            value={formatCurrency(stats.total_paid)}
            icon={<CheckCircle className="w-6 h-6" />}
            color="success"
          />
          <StatCard
            title="Outstanding"
            value={formatCurrency(stats.total_outstanding)}
            icon={<Clock className="w-6 h-6" />}
            color="warning"
          />
          <StatCard
            title="Overdue"
            value={formatCurrency(stats.total_overdue)}
            icon={<AlertTriangle className="w-6 h-6" />}
            color="danger"
          />
        </div>
      )}

      {/* Filters */}
      <Card padding="md">
        <div className="space-y-4">
          {/* Primary Filter Row */}
          <div className="flex flex-wrap items-center gap-4">
            {/* Search */}
            <div className="flex-1 min-w-[250px] max-w-md">
              <Input
                placeholder="Search by invoice #, customer name, email..."
                value={searchQuery}
                onChange={(e) => handleSearchChange(e.target.value)}
                leftIcon={<Search className="w-4 h-4" />}
              />
            </div>

            {/* Status Filter */}
            <div className="relative">
              <select
                value={statusFilter}
                onChange={(e) => {
                  setStatusFilter(e.target.value as InvoiceStatus | 'all');
                  setCurrentPage(1);
                }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {INVOICE_STATUS_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>

            {/* Toggle Advanced Filters */}
            <button
              onClick={() => setShowFilters(!showFilters)}
              className={`flex items-center gap-2 px-4 py-2.5 text-sm font-medium rounded-lg transition-colors ${
                showFilters || hasActiveFilters
                  ? 'bg-primary-50 text-primary-600 border border-primary-200'
                  : 'text-secondary-700 bg-white border border-secondary-300 hover:bg-secondary-50'
              }`}
            >
              <Filter className="w-4 h-4" />
              Filters
              {hasActiveFilters && (
                <span className="w-2 h-2 bg-primary-500 rounded-full" />
              )}
            </button>

            {/* Clear Filters */}
            {hasActiveFilters && (
              <button
                onClick={clearFilters}
                className="flex items-center gap-1 px-3 py-2.5 text-sm text-red-600 hover:bg-red-50 rounded-lg transition-colors"
              >
                <X className="w-4 h-4" />
                Clear
              </button>
            )}
          </div>

          {/* Advanced Filters Row */}
          {showFilters && (
            <div className="flex flex-wrap items-center gap-4 pt-4 border-t border-secondary-200">
              {/* Date Range */}
              <div className="flex items-center gap-2">
                <Clock className="w-4 h-4 text-secondary-400" />
                <input
                  type="date"
                  value={dateFrom}
                  onChange={(e) => {
                    setDateFrom(e.target.value);
                    setCurrentPage(1);
                  }}
                  className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                  placeholder="From"
                />
                <span className="text-secondary-400">to</span>
                <input
                  type="date"
                  value={dateTo}
                  onChange={(e) => {
                    setDateTo(e.target.value);
                    setCurrentPage(1);
                  }}
                  className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                  placeholder="To"
                />
              </div>
            </div>
          )}
        </div>
      </Card>

      {/* Invoices Table */}
      <div>
        <Table
          columns={columns}
          data={invoices}
          keyExtractor={(invoice) => invoice.uuid}
          onRowClick={handleViewInvoice}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage={
            hasActiveFilters
              ? 'No invoices match your filters. Try adjusting your search criteria.'
              : 'No invoices found. Create your first invoice to get started.'
          }
        />

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Create Invoice Modal */}
      <CreateInvoiceModal
        isOpen={isCreateModalOpen}
        onClose={() => setIsCreateModalOpen(false)}
        onCreated={handleInvoiceCreated}
      />
    </div>
  );
}

export default function InvoicesPage() {
  return (
    <ProtectedPage module="invoices" title="Invoices">
      <InvoicesPageContent />
    </ProtectedPage>
  );
}
