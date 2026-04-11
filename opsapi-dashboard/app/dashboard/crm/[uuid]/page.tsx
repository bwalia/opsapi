'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Building2,
  Users,
  DollarSign,
  CalendarCheck,
  Edit,
  Trash2,
  Plus,
  Phone,
  Mail,
  Globe,
  MapPin,
  Briefcase,
  RefreshCw,
  X,
  ChevronDown,
} from 'lucide-react';
import { Button, Table, Pagination, Card, Modal, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  crmService,
  type CrmAccount,
  type CrmContact,
  type CrmDeal,
  type CrmActivity,
  type CrmListParams,
} from '@/services/crm.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

// ============================================================
// Sub-tab type
// ============================================================

type DetailTab = 'contacts' | 'deals' | 'activities';

// ============================================================
// Edit Account Modal
// ============================================================

interface EditAccountModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  account: CrmAccount | null;
}

const EditAccountModal: React.FC<EditAccountModalProps> = ({ isOpen, onClose, onSuccess, account }) => {
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
    status: 'active',
  });

  useEffect(() => {
    if (account) {
      setFormData({
        name: account.name || '',
        industry: account.industry || '',
        website: account.website || '',
        email: account.email || '',
        phone: account.phone || '',
        address_line1: account.address_line1 || '',
        address_line2: account.address_line2 || '',
        city: account.city || '',
        state: account.state || '',
        postal_code: account.postal_code || '',
        country: account.country || '',
        status: account.status || 'active',
      });
    }
  }, [account]);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!account || !formData.name.trim()) {
      toast.error('Account name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await crmService.updateAccount(account.uuid, formData);
      toast.success('Account updated successfully');
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to update account:', error);
      toast.error('Failed to update account');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Edit Account">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Name *</label>
            <input name="name" value={formData.name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Industry</label>
            <input name="industry" value={formData.industry} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Website</label>
            <input name="website" value={formData.website} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Email</label>
            <input name="email" type="email" value={formData.email} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Phone</label>
            <input name="phone" value={formData.phone} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Address Line 1</label>
            <input name="address_line1" value={formData.address_line1} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Address Line 2</label>
            <input name="address_line2" value={formData.address_line2} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">City</label>
            <input name="city" value={formData.city} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">State</label>
            <input name="state" value={formData.state} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Postal Code</label>
            <input name="postal_code" value={formData.postal_code} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Country</label>
            <input name="country" value={formData.country} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Status</label>
            <div className="relative">
              <select name="status" value={formData.status} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Saving...' : 'Save Changes'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Add Contact Modal (for account)
// ============================================================

interface AddContactToAccountModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  accountUuid: string;
}

const AddContactToAccountModal: React.FC<AddContactToAccountModalProps> = ({ isOpen, onClose, onSuccess, accountUuid }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({ first_name: '', last_name: '', email: '', phone: '', job_title: '' });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.first_name.trim()) { toast.error('First name is required'); return; }
    setIsSubmitting(true);
    try {
      await crmService.createContact({ ...formData, account_uuid: accountUuid });
      toast.success('Contact added successfully');
      setFormData({ first_name: '', last_name: '', email: '', phone: '', job_title: '' });
      onSuccess();
      onClose();
    } catch (error) {
      toast.error('Failed to add contact');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add Contact">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">First Name *</label>
            <input name="first_name" value={formData.first_name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Last Name</label>
            <input name="last_name" value={formData.last_name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Email</label>
            <input name="email" type="email" value={formData.email} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Phone</label>
            <input name="phone" value={formData.phone} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Job Title</label>
            <input name="job_title" value={formData.job_title} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Adding...' : 'Add Contact'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Add Deal Modal (for account)
// ============================================================

interface AddDealToAccountModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  accountUuid: string;
}

const DEAL_STAGE_OPTIONS = [
  { value: 'prospecting', label: 'Prospecting' },
  { value: 'qualification', label: 'Qualification' },
  { value: 'proposal', label: 'Proposal' },
  { value: 'negotiation', label: 'Negotiation' },
  { value: 'closed_won', label: 'Closed Won' },
  { value: 'closed_lost', label: 'Closed Lost' },
];

const AddDealToAccountModal: React.FC<AddDealToAccountModalProps> = ({ isOpen, onClose, onSuccess, accountUuid }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({ name: '', stage: 'prospecting', value: '', probability: '', expected_close_date: '' });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.name.trim()) { toast.error('Deal name is required'); return; }
    setIsSubmitting(true);
    try {
      const payload: Record<string, unknown> = { ...formData, account_uuid: accountUuid };
      if (formData.value) payload.value = parseFloat(formData.value);
      if (formData.probability) payload.probability = parseInt(formData.probability, 10);
      await crmService.createDeal(payload);
      toast.success('Deal added successfully');
      setFormData({ name: '', stage: 'prospecting', value: '', probability: '', expected_close_date: '' });
      onSuccess();
      onClose();
    } catch (error) {
      toast.error('Failed to add deal');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add Deal">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Deal Name *</label>
            <input name="name" value={formData.name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Stage</label>
            <div className="relative">
              <select name="stage" value={formData.stage} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                {DEAL_STAGE_OPTIONS.map((opt) => (
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
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Expected Close</label>
            <input name="expected_close_date" type="date" value={formData.expected_close_date} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Adding...' : 'Add Deal'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Add Activity Modal (for account)
// ============================================================

interface AddActivityToAccountModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  accountUuid: string;
}

const ACTIVITY_TYPE_OPTIONS = [
  { value: 'call', label: 'Call' },
  { value: 'email', label: 'Email' },
  { value: 'meeting', label: 'Meeting' },
  { value: 'note', label: 'Note' },
  { value: 'task', label: 'Task' },
];

const AddActivityToAccountModal: React.FC<AddActivityToAccountModalProps> = ({ isOpen, onClose, onSuccess, accountUuid }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({ subject: '', type: 'call', description: '', due_date: '' });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.subject.trim()) { toast.error('Subject is required'); return; }
    setIsSubmitting(true);
    try {
      await crmService.createActivity({ ...formData, related_type: 'account', related_uuid: accountUuid });
      toast.success('Activity added successfully');
      setFormData({ subject: '', type: 'call', description: '', due_date: '' });
      onSuccess();
      onClose();
    } catch (error) {
      toast.error('Failed to add activity');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add Activity">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Subject *</label>
            <input name="subject" value={formData.subject} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Type</label>
            <div className="relative">
              <select name="type" value={formData.type} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer">
                {ACTIVITY_TYPE_OPTIONS.map((opt) => (
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
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <textarea name="description" value={formData.description} onChange={handleChange} rows={3} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none" />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Adding...' : 'Add Activity'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Account Detail Page Content
// ============================================================

function AccountDetailContent() {
  const params = useParams();
  const router = useRouter();
  const uuid = params.uuid as string;

  // Account data
  const [account, setAccount] = useState<CrmAccount | null>(null);
  const [isLoadingAccount, setIsLoadingAccount] = useState(true);

  // Sub-tab
  const [activeTab, setActiveTab] = useState<DetailTab>('contacts');

  // Related data
  const [contacts, setContacts] = useState<CrmContact[]>([]);
  const [deals, setDeals] = useState<CrmDeal[]>([]);
  const [activities, setActivities] = useState<CrmActivity[]>([]);
  const [isLoadingRelated, setIsLoadingRelated] = useState(true);

  // Pagination for related
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const perPage = 10;

  // Modals
  const [isEditOpen, setIsEditOpen] = useState(false);
  const [isAddContactOpen, setIsAddContactOpen] = useState(false);
  const [isAddDealOpen, setIsAddDealOpen] = useState(false);
  const [isAddActivityOpen, setIsAddActivityOpen] = useState(false);

  // Delete
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  // Refs
  const fetchIdRef = useRef(0);

  // Load account
  const fetchAccount = useCallback(async () => {
    setIsLoadingAccount(true);
    try {
      const data = await crmService.getAccount(uuid);
      setAccount(data);
    } catch (error) {
      console.error('Failed to fetch account:', error);
      toast.error('Failed to load account');
    } finally {
      setIsLoadingAccount(false);
    }
  }, [uuid]);

  useEffect(() => {
    fetchAccount();
  }, [fetchAccount]);

  // Reset page on tab change
  useEffect(() => {
    setCurrentPage(1);
  }, [activeTab]);

  // Fetch related data
  const fetchRelated = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoadingRelated(true);

    try {
      const params: CrmListParams = { page: currentPage, perPage, search: uuid };

      if (activeTab === 'contacts') {
        const response = await crmService.getContacts({ ...params, search: undefined, status: undefined });
        if (fetchId === fetchIdRef.current) {
          // Filter contacts by account_uuid client-side as a fallback
          setContacts(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      } else if (activeTab === 'deals') {
        const response = await crmService.getDeals({ ...params, search: undefined });
        if (fetchId === fetchIdRef.current) {
          setDeals(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      } else if (activeTab === 'activities') {
        const response = await crmService.getActivities({ ...params, search: undefined });
        if (fetchId === fetchIdRef.current) {
          setActivities(response.data);
          setTotalPages(response.total_pages);
          setTotalItems(response.total);
        }
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error(`Failed to fetch ${activeTab}:`, error);
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoadingRelated(false);
      }
    }
  }, [activeTab, currentPage, uuid]);

  useEffect(() => {
    if (uuid) fetchRelated();
  }, [fetchRelated, uuid]);

  // Delete account
  const handleDeleteConfirm = async () => {
    setIsDeleting(true);
    try {
      await crmService.deleteAccount(uuid);
      toast.success('Account deleted successfully');
      router.push('/dashboard/crm');
    } catch (error) {
      toast.error('Failed to delete account');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
    }
  };

  // Complete activity
  const handleCompleteActivity = useCallback(async (activityUuid: string) => {
    try {
      await crmService.completeActivity(activityUuid);
      toast.success('Activity marked as complete');
      fetchRelated();
    } catch (error) {
      toast.error('Failed to complete activity');
    }
  }, [fetchRelated]);

  // ---- Table columns for related records ----

  const contactColumns: TableColumn<CrmContact>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
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
      render: (contact) => (
        <span className="text-sm text-secondary-600">{contact.email || '--'}</span>
      ),
    },
    {
      key: 'phone',
      header: 'Phone',
      render: (contact) => (
        <span className="text-sm text-secondary-600">{contact.phone || '--'}</span>
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
  ], []);

  const dealColumns: TableColumn<CrmDeal>[] = useMemo(() => [
    {
      key: 'name',
      header: 'Name',
      render: (deal) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-green-100 rounded-lg flex items-center justify-center">
            <DollarSign className="w-5 h-5 text-green-600" />
          </div>
          <p className="font-medium text-secondary-900">{deal.name}</p>
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
  ], []);

  const activityColumns: TableColumn<CrmActivity>[] = useMemo(() => [
    {
      key: 'subject',
      header: 'Subject',
      render: (activity) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-amber-100 rounded-lg flex items-center justify-center">
            <CalendarCheck className="w-5 h-5 text-amber-600" />
          </div>
          <p className="font-medium text-secondary-900">{activity.subject}</p>
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
      key: 'due_date',
      header: 'Date',
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
      width: 'w-16',
      render: (activity) => (
        activity.status === 'pending' ? (
          <button
            onClick={(e) => { e.stopPropagation(); handleCompleteActivity(activity.uuid); }}
            className="p-1.5 text-secondary-500 hover:text-green-500 hover:bg-green-50 rounded-lg transition-colors"
            title="Complete"
          >
            <CalendarCheck className="w-4 h-4" />
          </button>
        ) : null
      ),
    },
  ], [handleCompleteActivity]);

  // Loading skeleton
  if (isLoadingAccount) {
    return (
      <div className="space-y-6">
        <div className="animate-pulse">
          <div className="h-8 bg-secondary-200 rounded w-1/3 mb-4" />
          <div className="h-4 bg-secondary-200 rounded w-1/2 mb-8" />
          <div className="grid grid-cols-3 gap-4">
            <div className="h-32 bg-secondary-200 rounded-xl" />
            <div className="h-32 bg-secondary-200 rounded-xl" />
            <div className="h-32 bg-secondary-200 rounded-xl" />
          </div>
        </div>
      </div>
    );
  }

  if (!account) {
    return (
      <div className="text-center py-12">
        <p className="text-secondary-500">Account not found</p>
        <button onClick={() => router.push('/dashboard/crm')} className="mt-4 text-primary-600 hover:underline text-sm">Back to CRM</button>
      </div>
    );
  }

  // Build address string
  const addressParts = [account.address_line1, account.address_line2, account.city, account.state, account.postal_code, account.country].filter(Boolean);
  const fullAddress = addressParts.join(', ');

  // Sub-tab config
  const detailTabs: { key: DetailTab; label: string; icon: React.ReactNode }[] = [
    { key: 'contacts', label: 'Contacts', icon: <Users className="w-4 h-4" /> },
    { key: 'deals', label: 'Deals', icon: <DollarSign className="w-4 h-4" /> },
    { key: 'activities', label: 'Activities', icon: <CalendarCheck className="w-4 h-4" /> },
  ];

  const handleAddRelated = () => {
    if (activeTab === 'contacts') setIsAddContactOpen(true);
    else if (activeTab === 'deals') setIsAddDealOpen(true);
    else if (activeTab === 'activities') setIsAddActivityOpen(true);
  };

  return (
    <div className="space-y-6">
      {/* Back + Actions */}
      <div className="flex items-center justify-between">
        <button
          onClick={() => router.push('/dashboard/crm')}
          className="flex items-center gap-2 text-sm text-secondary-600 hover:text-secondary-900 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          Back to CRM
        </button>
        <div className="flex items-center gap-3">
          <button
            onClick={() => setIsEditOpen(true)}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <Edit className="w-4 h-4" />
            Edit
          </button>
          <button
            onClick={() => setDeleteDialogOpen(true)}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-red-600 bg-white border border-red-300 rounded-lg hover:bg-red-50 transition-colors"
          >
            <Trash2 className="w-4 h-4" />
            Delete
          </button>
        </div>
      </div>

      {/* Account Header */}
      <div className="bg-white rounded-xl border border-secondary-200 p-6 shadow-sm">
        <div className="flex items-start gap-5">
          <div className="w-16 h-16 bg-primary-100 rounded-xl flex items-center justify-center flex-shrink-0">
            <Building2 className="w-8 h-8 text-primary-600" />
          </div>
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-3 mb-1">
              <h1 className="text-2xl font-bold text-secondary-900">{account.name}</h1>
              <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
                account.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-secondary-100 text-secondary-600'
              }`}>
                {account.status}
              </span>
            </div>
            {account.industry && (
              <p className="text-secondary-500 mb-3">{account.industry}</p>
            )}
            <div className="flex flex-wrap items-center gap-4 text-sm text-secondary-600">
              {account.email && (
                <div className="flex items-center gap-1.5">
                  <Mail className="w-4 h-4 text-secondary-400" />
                  <span>{account.email}</span>
                </div>
              )}
              {account.phone && (
                <div className="flex items-center gap-1.5">
                  <Phone className="w-4 h-4 text-secondary-400" />
                  <span>{account.phone}</span>
                </div>
              )}
              {account.website && (
                <div className="flex items-center gap-1.5">
                  <Globe className="w-4 h-4 text-secondary-400" />
                  <a href={account.website} target="_blank" rel="noopener noreferrer" className="text-primary-600 hover:underline">{account.website}</a>
                </div>
              )}
            </div>
          </div>
          {/* Quick stats */}
          <div className="flex gap-6 flex-shrink-0">
            <div className="text-center">
              <p className="text-2xl font-bold text-secondary-900">{account.contact_count ?? 0}</p>
              <p className="text-xs text-secondary-500">Contacts</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-secondary-900">{account.deal_count ?? 0}</p>
              <p className="text-xs text-secondary-500">Deals</p>
            </div>
          </div>
        </div>

        {/* Address */}
        {fullAddress && (
          <div className="mt-4 pt-4 border-t border-secondary-200">
            <div className="flex items-start gap-2 text-sm text-secondary-600">
              <MapPin className="w-4 h-4 text-secondary-400 mt-0.5 flex-shrink-0" />
              <span>{fullAddress}</span>
            </div>
          </div>
        )}
      </div>

      {/* Related Records Tabs */}
      <div className="border-b border-secondary-200">
        <nav className="flex gap-0 -mb-px">
          {detailTabs.map((tab) => (
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
          <div className="ml-auto flex items-center">
            <Button size="sm" leftIcon={<Plus className="w-4 h-4" />} onClick={handleAddRelated}>
              Add {activeTab.slice(0, -1)}
            </Button>
          </div>
        </nav>
      </div>

      {/* Related Table */}
      <div>
        {activeTab === 'contacts' && (
          <Table
            columns={contactColumns}
            data={contacts}
            keyExtractor={(c) => c.uuid}
            isLoading={isLoadingRelated}
            emptyMessage="No contacts linked to this account"
          />
        )}

        {activeTab === 'deals' && (
          <Table
            columns={dealColumns}
            data={deals}
            keyExtractor={(d) => d.uuid}
            isLoading={isLoadingRelated}
            emptyMessage="No deals linked to this account"
          />
        )}

        {activeTab === 'activities' && (
          <Table
            columns={activityColumns}
            data={activities}
            keyExtractor={(a) => a.uuid}
            isLoading={isLoadingRelated}
            emptyMessage="No activities for this account"
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

      {/* Modals */}
      <EditAccountModal
        isOpen={isEditOpen}
        onClose={() => setIsEditOpen(false)}
        onSuccess={fetchAccount}
        account={account}
      />

      <AddContactToAccountModal
        isOpen={isAddContactOpen}
        onClose={() => setIsAddContactOpen(false)}
        onSuccess={fetchRelated}
        accountUuid={uuid}
      />

      <AddDealToAccountModal
        isOpen={isAddDealOpen}
        onClose={() => setIsAddDealOpen(false)}
        onSuccess={fetchRelated}
        accountUuid={uuid}
      />

      <AddActivityToAccountModal
        isOpen={isAddActivityOpen}
        onClose={() => setIsAddActivityOpen(false)}
        onSuccess={fetchRelated}
        accountUuid={uuid}
      />

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Account"
        message={`Are you sure you want to delete "${account.name}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}

export default function AccountDetailPage() {
  return (
    <ProtectedPage module="crm" title="Account Details">
      <AccountDetailContent />
    </ProtectedPage>
  );
}
