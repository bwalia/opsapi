'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  Plus,
  Trash2,
  Edit,
  Eye,
  Building2,
  Users,
  DollarSign,
  CalendarCheck,
  Phone,
  Mail,
  Globe,
  Briefcase,
  ChevronDown,
  RefreshCw,
  X,
} from 'lucide-react';
import { Input, Table, Badge, Pagination, Card, Modal, Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  crmService,
  type CrmAccount,
  type CrmContact,
  type CrmDeal,
  type CrmActivity,
  type CrmDashboardStats,
  type CrmListParams,
} from '@/services/crm.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

// ============================================================
// Tab type
// ============================================================

type CrmTab = 'accounts' | 'contacts' | 'deals' | 'activities';

// ============================================================
// Stats Card
// ============================================================

interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'info';
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color }) => {
  const colorClasses = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
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

// ============================================================
// Status options
// ============================================================

const ACCOUNT_STATUS_OPTIONS = [
  { value: 'all', label: 'All Status' },
  { value: 'active', label: 'Active' },
  { value: 'inactive', label: 'Inactive' },
];

const DEAL_STAGE_OPTIONS = [
  { value: 'all', label: 'All Stages' },
  { value: 'prospecting', label: 'Prospecting' },
  { value: 'qualification', label: 'Qualification' },
  { value: 'proposal', label: 'Proposal' },
  { value: 'negotiation', label: 'Negotiation' },
  { value: 'closed_won', label: 'Closed Won' },
  { value: 'closed_lost', label: 'Closed Lost' },
];

const ACTIVITY_TYPE_OPTIONS = [
  { value: 'all', label: 'All Types' },
  { value: 'call', label: 'Call' },
  { value: 'email', label: 'Email' },
  { value: 'meeting', label: 'Meeting' },
  { value: 'note', label: 'Note' },
  { value: 'task', label: 'Task' },
];

// ============================================================
// Create Account Modal
// ============================================================

interface CreateAccountModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

const CreateAccountModal: React.FC<CreateAccountModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({
    name: '',
    industry: '',
    website: '',
    email: '',
    phone: '',
    address_line1: '',
    address_line2: '',
    city: '',
    state: '',
    postal_code: '',
    country: '',
  });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.name.trim()) {
      toast.error('Account name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await crmService.createAccount(formData);
      toast.success('Account created successfully');
      setFormData({ name: '', industry: '', website: '', email: '', phone: '', address_line1: '', address_line2: '', city: '', state: '', postal_code: '', country: '' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to create account:', error);
      toast.error('Failed to create account');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Account">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Name *</label>
            <input name="name" value={formData.name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Account name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Industry</label>
            <input name="industry" value={formData.industry} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="e.g. Technology" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Website</label>
            <input name="website" value={formData.website} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="https://example.com" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Email</label>
            <input name="email" type="email" value={formData.email} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="contact@example.com" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Phone</label>
            <input name="phone" value={formData.phone} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="+1 (555) 000-0000" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Address Line 1</label>
            <input name="address_line1" value={formData.address_line1} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Street address" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Address Line 2</label>
            <input name="address_line2" value={formData.address_line2} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Suite, unit, etc." />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">City</label>
            <input name="city" value={formData.city} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="City" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">State</label>
            <input name="state" value={formData.state} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="State/Province" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Postal Code</label>
            <input name="postal_code" value={formData.postal_code} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Postal code" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Country</label>
            <input name="country" value={formData.country} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Country" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Creating...' : 'Create Account'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Create Contact Modal
// ============================================================

interface CreateContactModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

const CreateContactModal: React.FC<CreateContactModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({
    first_name: '',
    last_name: '',
    email: '',
    phone: '',
    job_title: '',
    account_uuid: '',
  });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.first_name.trim()) {
      toast.error('First name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await crmService.createContact(formData);
      toast.success('Contact created successfully');
      setFormData({ first_name: '', last_name: '', email: '', phone: '', job_title: '', account_uuid: '' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to create contact:', error);
      toast.error('Failed to create contact');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Contact">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">First Name *</label>
            <input name="first_name" value={formData.first_name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="First name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Last Name</label>
            <input name="last_name" value={formData.last_name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Last name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Email</label>
            <input name="email" type="email" value={formData.email} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="email@example.com" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Phone</label>
            <input name="phone" value={formData.phone} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="+1 (555) 000-0000" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Job Title</label>
            <input name="job_title" value={formData.job_title} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="e.g. CEO" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Account UUID</label>
            <input name="account_uuid" value={formData.account_uuid} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Link to account" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Creating...' : 'Create Contact'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Create Deal Modal
// ============================================================

interface CreateDealModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

const CreateDealModal: React.FC<CreateDealModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({
    name: '',
    account_uuid: '',
    stage: 'prospecting',
    value: '',
    probability: '',
    expected_close_date: '',
  });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.name.trim()) {
      toast.error('Deal name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      const payload: Record<string, unknown> = { ...formData };
      if (formData.value) payload.value = parseFloat(formData.value);
      if (formData.probability) payload.probability = parseInt(formData.probability, 10);
      await crmService.createDeal(payload);
      toast.success('Deal created successfully');
      setFormData({ name: '', account_uuid: '', stage: 'prospecting', value: '', probability: '', expected_close_date: '' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to create deal:', error);
      toast.error('Failed to create deal');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Deal">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Deal Name *</label>
            <input name="name" value={formData.name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Deal name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Account UUID</label>
            <input name="account_uuid" value={formData.account_uuid} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Link to account" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Stage</label>
            <div className="relative">
              <select name="stage" value={formData.stage} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                {DEAL_STAGE_OPTIONS.filter((o) => o.value !== 'all').map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Value</label>
            <input name="value" type="number" step="0.01" value={formData.value} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="0.00" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Probability (%)</label>
            <input name="probability" type="number" min="0" max="100" value={formData.probability} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="50" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Expected Close Date</label>
            <input name="expected_close_date" type="date" value={formData.expected_close_date} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Creating...' : 'Create Deal'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Create Activity Modal
// ============================================================

interface CreateActivityModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

const CreateActivityModal: React.FC<CreateActivityModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({
    subject: '',
    type: 'call' as CrmActivity['type'],
    description: '',
    related_type: '',
    related_uuid: '',
    due_date: '',
  });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.subject.trim()) {
      toast.error('Subject is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await crmService.createActivity(formData);
      toast.success('Activity created successfully');
      setFormData({ subject: '', type: 'call', description: '', related_type: '', related_uuid: '', due_date: '' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to create activity:', error);
      toast.error('Failed to create activity');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Activity">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Subject *</label>
            <input name="subject" value={formData.subject} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Activity subject" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Type</label>
            <div className="relative">
              <select name="type" value={formData.type} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                {ACTIVITY_TYPE_OPTIONS.filter((o) => o.value !== 'all').map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Due Date</label>
            <input name="due_date" type="date" value={formData.due_date} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Related To</label>
            <div className="relative">
              <select name="related_type" value={formData.related_type} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                <option value="">None</option>
                <option value="account">Account</option>
                <option value="contact">Contact</option>
                <option value="deal">Deal</option>
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Related UUID</label>
            <input name="related_uuid" value={formData.related_uuid} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="UUID of related record" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <textarea name="description" value={formData.description} onChange={handleChange} rows={3} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none" placeholder="Activity details..." />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Creating...' : 'Create Activity'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Main CRM Page Content
// ============================================================

function CrmPageContent() {
  // Active tab
  const [activeTab, setActiveTab] = useState<CrmTab>('accounts');

  // Stats
  const [stats, setStats] = useState<CrmDashboardStats | null>(null);

  // Common list state
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [stageFilter, setStageFilter] = useState('all');
  const [typeFilter, setTypeFilter] = useState('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const perPage = 10;

  // Data
  const [accounts, setAccounts] = useState<CrmAccount[]>([]);
  const [contacts, setContacts] = useState<CrmContact[]>([]);
  const [deals, setDeals] = useState<CrmDeal[]>([]);
  const [activities, setActivities] = useState<CrmActivity[]>([]);

  // Modals
  const [isCreateAccountOpen, setIsCreateAccountOpen] = useState(false);
  const [isCreateContactOpen, setIsCreateContactOpen] = useState(false);
  const [isCreateDealOpen, setIsCreateDealOpen] = useState(false);
  const [isCreateActivityOpen, setIsCreateActivityOpen] = useState(false);

  // Delete
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<{ uuid: string; name: string; type: CrmTab } | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  // Refs
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Load stats on mount
  useEffect(() => {
    const loadStats = async () => {
      try {
        const data = await crmService.getDashboardStats();
        setStats(data);
      } catch (error) {
        console.error('Failed to load CRM stats:', error);
      }
    };
    loadStats();
  }, []);

  // Reset pagination and filters on tab change
  useEffect(() => {
    setCurrentPage(1);
    setSearchQuery('');
    setStatusFilter('all');
    setStageFilter('all');
    setTypeFilter('all');
    setSortColumn('created_at');
    setSortDirection('desc');
  }, [activeTab]);

  // Build params
  const buildParams = useCallback((): CrmListParams => {
    const params: CrmListParams = {
      page: currentPage,
      perPage,
      orderBy: sortColumn,
      orderDir: sortDirection,
    };
    if (searchQuery.trim()) params.search = searchQuery.trim();
    if (statusFilter !== 'all') params.status = statusFilter;
    if (stageFilter !== 'all') params.stage = stageFilter;
    if (typeFilter !== 'all') params.type = typeFilter;
    return params;
  }, [currentPage, sortColumn, sortDirection, searchQuery, statusFilter, stageFilter, typeFilter]);

  // Fetch data for active tab
  const fetchData = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const params = buildParams();

      if (activeTab === 'accounts') {
        const response = await crmService.getAccounts(params);
        if (fetchId === fetchIdRef.current) {
          setAccounts(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      } else if (activeTab === 'contacts') {
        const response = await crmService.getContacts(params);
        if (fetchId === fetchIdRef.current) {
          setContacts(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      } else if (activeTab === 'deals') {
        const response = await crmService.getDeals(params);
        if (fetchId === fetchIdRef.current) {
          setDeals(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      } else if (activeTab === 'activities') {
        const response = await crmService.getActivities(params);
        if (fetchId === fetchIdRef.current) {
          setActivities(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error(`Failed to fetch ${activeTab}:`, error);
        toast.error(`Failed to load ${activeTab}`);
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [activeTab, buildParams]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Debounced search
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

  // Delete handler
  const handleDeleteClick = useCallback((uuid: string, name: string, type: CrmTab) => {
    setDeleteTarget({ uuid, name, type });
    setDeleteDialogOpen(true);
  }, []);

  const handleDeleteConfirm = async () => {
    if (!deleteTarget) return;
    setIsDeleting(true);
    try {
      if (deleteTarget.type === 'accounts') await crmService.deleteAccount(deleteTarget.uuid);
      else if (deleteTarget.type === 'contacts') await crmService.deleteContact(deleteTarget.uuid);
      else if (deleteTarget.type === 'deals') await crmService.deleteDeal(deleteTarget.uuid);
      else if (deleteTarget.type === 'activities') await crmService.deleteActivity(deleteTarget.uuid);
      toast.success(`${deleteTarget.type.slice(0, -1)} deleted successfully`);
      fetchData();
    } catch (error) {
      toast.error(`Failed to delete ${deleteTarget.type.slice(0, -1)}`);
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setDeleteTarget(null);
    }
  };

  // Complete activity
  const handleCompleteActivity = useCallback(async (uuid: string) => {
    try {
      await crmService.completeActivity(uuid);
      toast.success('Activity marked as complete');
      fetchData();
    } catch (error) {
      toast.error('Failed to complete activity');
    }
  }, [fetchData]);

  // ---- Table columns ----

  const accountColumns: TableColumn<CrmAccount>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (account) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-100 rounded-lg flex items-center justify-center">
            <Building2 className="w-5 h-5 text-primary-600" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{account.name}</p>
            {account.industry && <p className="text-xs text-secondary-500">{account.industry}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'email',
      header: 'Email',
      render: (account) => account.email ? (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Mail className="w-3.5 h-3.5 text-secondary-400" />
          <span>{account.email}</span>
        </div>
      ) : <span className="text-sm text-secondary-400">--</span>,
    },
    {
      key: 'phone',
      header: 'Phone',
      render: (account) => account.phone ? (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Phone className="w-3.5 h-3.5 text-secondary-400" />
          <span>{account.phone}</span>
        </div>
      ) : <span className="text-sm text-secondary-400">--</span>,
    },
    {
      key: 'owner_name',
      header: 'Owner',
      render: (account) => (
        <span className="text-sm text-secondary-700">{account.owner_name || '--'}</span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (account) => (
        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
          account.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-secondary-100 text-secondary-600'
        }`}>
          {account.status}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (account) => (
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => { e.stopPropagation(); window.location.href = `/dashboard/crm/${account.uuid}`; }}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
            title="View Account"
          >
            <Eye className="w-4 h-4" />
          </button>
          <button
            onClick={(e) => { e.stopPropagation(); handleDeleteClick(account.uuid, account.name, 'accounts'); }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            title="Delete Account"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleDeleteClick]);

  const contactColumns: TableColumn<CrmContact>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (contact) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-blue-100 rounded-lg flex items-center justify-center">
            <Users className="w-5 h-5 text-blue-600" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{contact.first_name} {contact.last_name}</p>
            {contact.job_title && <p className="text-xs text-secondary-500">{contact.job_title}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'email',
      header: 'Email',
      render: (contact) => contact.email ? (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Mail className="w-3.5 h-3.5 text-secondary-400" />
          <span>{contact.email}</span>
        </div>
      ) : <span className="text-sm text-secondary-400">--</span>,
    },
    {
      key: 'phone',
      header: 'Phone',
      render: (contact) => contact.phone ? (
        <div className="flex items-center gap-2 text-sm text-secondary-600">
          <Phone className="w-3.5 h-3.5 text-secondary-400" />
          <span>{contact.phone}</span>
        </div>
      ) : <span className="text-sm text-secondary-400">--</span>,
    },
    {
      key: 'account_name',
      header: 'Account',
      render: (contact) => (
        <span className="text-sm text-secondary-700">{contact.account_name || '--'}</span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (contact) => (
        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
          contact.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-secondary-100 text-secondary-600'
        }`}>
          {contact.status}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (contact) => (
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => { e.stopPropagation(); handleDeleteClick(contact.uuid, `${contact.first_name} ${contact.last_name}`, 'contacts'); }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            title="Delete Contact"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleDeleteClick]);

  const dealColumns: TableColumn<CrmDeal>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (deal) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-green-100 rounded-lg flex items-center justify-center">
            <DollarSign className="w-5 h-5 text-green-600" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{deal.name}</p>
            {deal.account_name && <p className="text-xs text-secondary-500">{deal.account_name}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'stage',
      header: 'Stage',
      render: (deal) => (
        <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
          {deal.stage || '--'}
        </span>
      ),
    },
    {
      key: 'value',
      header: 'Value',
      sortable: true,
      render: (deal) => (
        <span className="font-semibold text-secondary-900">{deal.value ? formatCurrency(deal.value) : '--'}</span>
      ),
    },
    {
      key: 'probability',
      header: 'Probability',
      render: (deal) => (
        <span className="text-sm text-secondary-700">{deal.probability !== undefined ? `${deal.probability}%` : '--'}</span>
      ),
    },
    {
      key: 'expected_close_date',
      header: 'Expected Close',
      render: (deal) => (
        <span className="text-sm text-secondary-600">{deal.expected_close_date ? formatDate(deal.expected_close_date) : '--'}</span>
      ),
    },
    {
      key: 'owner_name',
      header: 'Owner',
      render: (deal) => (
        <span className="text-sm text-secondary-700">{deal.owner_name || '--'}</span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (deal) => (
        <div className="flex items-center gap-2">
          <button
            onClick={(e) => { e.stopPropagation(); handleDeleteClick(deal.uuid, deal.name, 'deals'); }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            title="Delete Deal"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleDeleteClick]);

  const activityColumns: TableColumn<CrmActivity>[] = useMemo(() => [
    {
      key: 'subject',
      header: 'Subject',
      sortable: true,
      render: (activity) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-amber-100 rounded-lg flex items-center justify-center">
            <CalendarCheck className="w-5 h-5 text-amber-600" />
          </div>
          <div>
            <p className="font-medium text-secondary-900">{activity.subject}</p>
            {activity.description && <p className="text-xs text-secondary-500 truncate max-w-[200px]">{activity.description}</p>}
          </div>
        </div>
      ),
    },
    {
      key: 'type',
      header: 'Type',
      render: (activity) => (
        <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-secondary-100 text-secondary-700 capitalize">
          {activity.type}
        </span>
      ),
    },
    {
      key: 'related_name',
      header: 'Related To',
      render: (activity) => (
        <span className="text-sm text-secondary-700">{activity.related_name || '--'}</span>
      ),
    },
    {
      key: 'due_date',
      header: 'Date',
      sortable: true,
      render: (activity) => (
        <span className="text-sm text-secondary-600">{activity.due_date ? formatDate(activity.due_date) : '--'}</span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (activity) => (
        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
          activity.status === 'completed' ? 'bg-green-100 text-green-800' :
          activity.status === 'cancelled' ? 'bg-red-100 text-red-800' :
          'bg-amber-100 text-amber-800'
        }`}>
          {activity.status}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-24',
      render: (activity) => (
        <div className="flex items-center gap-2">
          {activity.status === 'pending' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleCompleteActivity(activity.uuid); }}
              className="p-1.5 text-secondary-500 hover:text-green-500 hover:bg-green-50 rounded-lg transition-colors"
              title="Complete"
            >
              <CalendarCheck className="w-4 h-4" />
            </button>
          )}
          <button
            onClick={(e) => { e.stopPropagation(); handleDeleteClick(activity.uuid, activity.subject, 'activities'); }}
            className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            title="Delete Activity"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ], [handleDeleteClick, handleCompleteActivity]);

  // Tab config
  const tabs: { key: CrmTab; label: string; icon: React.ReactNode }[] = [
    { key: 'accounts', label: 'Accounts', icon: <Building2 className="w-4 h-4" /> },
    { key: 'contacts', label: 'Contacts', icon: <Users className="w-4 h-4" /> },
    { key: 'deals', label: 'Deals', icon: <DollarSign className="w-4 h-4" /> },
    { key: 'activities', label: 'Activities', icon: <CalendarCheck className="w-4 h-4" /> },
  ];

  // Create button handler
  const handleCreate = () => {
    if (activeTab === 'accounts') setIsCreateAccountOpen(true);
    else if (activeTab === 'contacts') setIsCreateContactOpen(true);
    else if (activeTab === 'deals') setIsCreateDealOpen(true);
    else if (activeTab === 'activities') setIsCreateActivityOpen(true);
  };

  const createLabel = useMemo(() => {
    const labels: Record<CrmTab, string> = {
      accounts: 'Add Account',
      contacts: 'Add Contact',
      deals: 'Add Deal',
      activities: 'Add Activity',
    };
    return labels[activeTab];
  }, [activeTab]);

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">CRM</h1>
          <p className="text-secondary-500 mt-1">Manage accounts, contacts, deals, and activities</p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => fetchData()}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
          <Button leftIcon={<Plus className="w-4 h-4" />} onClick={handleCreate}>
            {createLabel}
          </Button>
        </div>
      </div>

      {/* Stats Cards */}
      {stats && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <StatCard
            title="Total Accounts"
            value={stats.total_accounts}
            icon={<Building2 className="w-6 h-6" />}
            color="primary"
          />
          <StatCard
            title="Active Deals"
            value={stats.active_deals}
            icon={<Briefcase className="w-6 h-6" />}
            color="info"
          />
          <StatCard
            title="Deal Value"
            value={formatCurrency(stats.total_deal_value)}
            icon={<DollarSign className="w-6 h-6" />}
            color="success"
          />
          <StatCard
            title="Activities Today"
            value={stats.activities_today}
            icon={<CalendarCheck className="w-6 h-6" />}
            color="warning"
          />
        </div>
      )}

      {/* Tabs */}
      <div className="border-b border-secondary-200">
        <nav className="flex gap-0 -mb-px">
          {tabs.map((tab) => (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`flex items-center gap-2 px-5 py-3 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab.key
                  ? 'border-primary-500 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:text-secondary-700 hover:border-secondary-300'
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder={`Search ${activeTab}...`}
              value={searchQuery}
              onChange={(e) => handleSearchChange(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>

          {/* Status filter for accounts and contacts */}
          {(activeTab === 'accounts' || activeTab === 'contacts') && (
            <div className="relative">
              <select
                value={statusFilter}
                onChange={(e) => { setStatusFilter(e.target.value); setCurrentPage(1); }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {ACCOUNT_STATUS_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          )}

          {/* Stage filter for deals */}
          {activeTab === 'deals' && (
            <div className="relative">
              <select
                value={stageFilter}
                onChange={(e) => { setStageFilter(e.target.value); setCurrentPage(1); }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {DEAL_STAGE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          )}

          {/* Type filter for activities */}
          {activeTab === 'activities' && (
            <div className="relative">
              <select
                value={typeFilter}
                onChange={(e) => { setTypeFilter(e.target.value); setCurrentPage(1); }}
                className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
              >
                {ACTIVITY_TYPE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          )}
        </div>
      </Card>

      {/* Table */}
      <div>
        {activeTab === 'accounts' && (
          <Table
            columns={accountColumns}
            data={accounts}
            keyExtractor={(a) => a.uuid}
            onRowClick={(a) => { window.location.href = `/dashboard/crm/${a.uuid}`; }}
            sortColumn={sortColumn}
            sortDirection={sortDirection}
            onSort={handleSort}
            isLoading={isLoading}
            emptyMessage="No accounts found"
          />
        )}

        {activeTab === 'contacts' && (
          <Table
            columns={contactColumns}
            data={contacts}
            keyExtractor={(c) => c.uuid}
            sortColumn={sortColumn}
            sortDirection={sortDirection}
            onSort={handleSort}
            isLoading={isLoading}
            emptyMessage="No contacts found"
          />
        )}

        {activeTab === 'deals' && (
          <Table
            columns={dealColumns}
            data={deals}
            keyExtractor={(d) => d.uuid}
            sortColumn={sortColumn}
            sortDirection={sortDirection}
            onSort={handleSort}
            isLoading={isLoading}
            emptyMessage="No deals found"
          />
        )}

        {activeTab === 'activities' && (
          <Table
            columns={activityColumns}
            data={activities}
            keyExtractor={(a) => a.uuid}
            sortColumn={sortColumn}
            sortDirection={sortDirection}
            onSort={handleSort}
            isLoading={isLoading}
            emptyMessage="No activities found"
          />
        )}

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Create Modals */}
      <CreateAccountModal isOpen={isCreateAccountOpen} onClose={() => setIsCreateAccountOpen(false)} onSuccess={fetchData} />
      <CreateContactModal isOpen={isCreateContactOpen} onClose={() => setIsCreateContactOpen(false)} onSuccess={fetchData} />
      <CreateDealModal isOpen={isCreateDealOpen} onClose={() => setIsCreateDealOpen(false)} onSuccess={fetchData} />
      <CreateActivityModal isOpen={isCreateActivityOpen} onClose={() => setIsCreateActivityOpen(false)} onSuccess={fetchData} />

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title={`Delete ${deleteTarget?.type.slice(0, -1) || 'record'}`}
        message={`Are you sure you want to delete "${deleteTarget?.name}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}

export default function CrmPage() {
  return (
    <ProtectedPage module="crm" title="CRM">
      <CrmPageContent />
    </ProtectedPage>
  );
}
