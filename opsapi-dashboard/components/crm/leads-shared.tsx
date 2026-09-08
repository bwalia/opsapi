'use client';

/**
 * CRM Leads — shared presentational pieces
 *
 * Single source of truth for lead option lists, status/source/priority badge
 * maps, and the Create/Convert modals — reused by BOTH the CRM workspace
 * (/dashboard/crm, leads tab) and the dedicated Leads inbox (/dashboard/leads).
 *
 * Business logic + API calls live in crmService (namespace-scoped via the axios
 * client). These are thin display/form components only.
 */

import React, { useState, useEffect } from 'react';
import {
  ChevronDown,
  UserPlus,
  Mail,
  Phone,
  Building2,
  Briefcase,
  Tag,
  Megaphone,
  Globe,
  Link2,
  Star,
  CalendarClock,
  MessageSquare,
  ArrowRightCircle,
  Trash2,
  Bell,
  Send,
  Info,
  ExternalLink,
} from 'lucide-react';
import { Modal } from '@/components/ui';
import { crmService, type CrmLead, type LeadNotificationSettings } from '@/services/crm.service';
import { formatDate } from '@/lib/utils';
import toast from 'react-hot-toast';

// A compact on/off toggle switch (no extra dependency).
const Toggle: React.FC<{ checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }> = ({ checked, onChange, disabled }) => (
  <button
    type="button"
    role="switch"
    aria-checked={checked}
    disabled={disabled}
    onClick={() => onChange(!checked)}
    className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-primary-500/30 disabled:opacity-50 ${checked ? 'bg-primary-600' : 'bg-secondary-300'}`}
  >
    <span className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform ${checked ? 'translate-x-5' : 'translate-x-0.5'}`} />
  </button>
);

// ============================================================
// Option lists
// ============================================================

export const LEAD_STATUS_OPTIONS = [
  { value: 'all', label: 'All Status' },
  { value: 'new', label: 'New' },
  { value: 'contacted', label: 'Contacted' },
  { value: 'qualified', label: 'Qualified' },
  { value: 'converted', label: 'Converted' },
  { value: 'lost', label: 'Lost' },
];

export const LEAD_SOURCE_OPTIONS = [
  { value: 'all', label: 'All Sources' },
  { value: 'website_form', label: 'Website Form' },
  { value: 'email', label: 'Email' },
  { value: 'social_media', label: 'Social Media' },
  { value: 'manual', label: 'Manual Entry' },
  { value: 'api', label: 'API / Webhook' },
  { value: 'referral', label: 'Referral' },
];

export const LEAD_PRIORITY_OPTIONS = [
  { value: 'low', label: 'Low' },
  { value: 'medium', label: 'Medium' },
  { value: 'high', label: 'High' },
  { value: 'urgent', label: 'Urgent' },
];

// ============================================================
// Badge maps
// ============================================================

export const leadStatusColors: Record<string, string> = {
  new: 'bg-blue-100 text-blue-800',
  contacted: 'bg-amber-100 text-amber-800',
  qualified: 'bg-green-100 text-green-800',
  converted: 'bg-purple-100 text-purple-800',
  lost: 'bg-red-100 text-red-800',
};

export const leadSourceLabels: Record<string, string> = {
  website_form: 'Website',
  email: 'Email',
  social_media: 'Social',
  manual: 'Manual',
  api: 'API',
  referral: 'Referral',
};

export const leadPriorityColors: Record<string, string> = {
  low: 'bg-secondary-100 text-secondary-700',
  medium: 'bg-blue-100 text-blue-700',
  high: 'bg-amber-100 text-amber-700',
  urgent: 'bg-red-100 text-red-700',
};

// ============================================================
// Create Lead Modal
// ============================================================

interface CreateLeadModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

export const CreateLeadModal: React.FC<CreateLeadModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState({
    first_name: '',
    last_name: '',
    email: '',
    phone: '',
    company_name: '',
    job_title: '',
    source: 'manual',
    channel: '',
    campaign: '',
    priority: 'medium',
    notes: '',
  });

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    setFormData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.first_name.trim() && !formData.email.trim()) {
      toast.error('First name or email is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await crmService.createLead(formData);
      toast.success('Lead created successfully');
      setFormData({ first_name: '', last_name: '', email: '', phone: '', company_name: '', job_title: '', source: 'manual', channel: '', campaign: '', priority: 'medium', notes: '' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to create lead:', error);
      toast.error('Failed to create lead');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Lead">
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
            <label className="block text-sm font-medium text-secondary-700 mb-1">Email *</label>
            <input name="email" type="email" value={formData.email} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="email@example.com" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Phone</label>
            <input name="phone" value={formData.phone} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="+44 7700 000000" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Company</label>
            <input name="company_name" value={formData.company_name} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Company name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Job Title</label>
            <input name="job_title" value={formData.job_title} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="e.g. Marketing Director" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Source</label>
            <div className="relative">
              <select name="source" value={formData.source} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
                {LEAD_SOURCE_OPTIONS.filter((o) => o.value !== 'all').map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Priority</label>
            <div className="relative">
              <select name="priority" value={formData.priority} onChange={handleChange} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
                {LEAD_PRIORITY_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Channel</label>
            <input name="channel" value={formData.channel} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="e.g. organic, paid, social" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Campaign</label>
            <input name="campaign" value={formData.campaign} onChange={handleChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Campaign name" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Notes</label>
            <textarea name="notes" value={formData.notes} onChange={handleChange} rows={3} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none" placeholder="Additional notes about this lead..." />
          </div>
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Creating...' : 'Create Lead'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Convert Lead Modal
// ============================================================

interface ConvertLeadModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  lead: CrmLead | null;
}

export const ConvertLeadModal: React.FC<ConvertLeadModalProps> = ({ isOpen, onClose, onSuccess, lead }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [createDeal, setCreateDeal] = useState(false);
  const [dealData, setDealData] = useState({ name: '', value: '', currency: 'GBP', stage: 'new' });

  const handleDealChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setDealData((prev) => ({ ...prev, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!lead) return;

    setIsSubmitting(true);
    try {
      const deal = createDeal && dealData.name.trim() ? {
        name: dealData.name,
        value: dealData.value ? parseFloat(dealData.value) : 0,
        currency: dealData.currency,
        stage: dealData.stage,
      } : undefined;

      await crmService.convertLead(lead.uuid, deal);
      toast.success('Lead converted to contact successfully');
      setCreateDeal(false);
      setDealData({ name: '', value: '', currency: 'GBP', stage: 'new' });
      onSuccess();
      onClose();
    } catch (error) {
      console.error('Failed to convert lead:', error);
      toast.error('Failed to convert lead');
    } finally {
      setIsSubmitting(false);
    }
  };

  if (!lead) return null;

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Convert Lead">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Lead summary */}
        <div className="bg-secondary-50 rounded-lg p-4 space-y-1">
          <p className="text-sm font-medium text-secondary-900">{lead.first_name} {lead.last_name}</p>
          {lead.email && <p className="text-sm text-secondary-600">{lead.email}</p>}
          {lead.company_name && <p className="text-sm text-secondary-600">{lead.company_name}</p>}
          {lead.phone && <p className="text-sm text-secondary-600">{lead.phone}</p>}
        </div>

        <p className="text-sm text-secondary-600">
          This will create a new <strong>CRM Contact</strong> from this lead&apos;s information.
        </p>

        {/* Optional deal creation */}
        <div className="border border-secondary-200 rounded-lg p-4 space-y-3">
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              checked={createDeal}
              onChange={(e) => setCreateDeal(e.target.checked)}
              className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
            />
            <span className="text-sm font-medium text-secondary-700">Also create a deal</span>
          </label>

          {createDeal && (
            <div className="grid grid-cols-2 gap-3 pt-2">
              <div className="col-span-2">
                <label className="block text-sm font-medium text-secondary-700 mb-1">Deal Name *</label>
                <input name="name" value={dealData.name} onChange={handleDealChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="Deal name" />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Value</label>
                <input name="value" type="number" step="0.01" value={dealData.value} onChange={handleDealChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="0.00" />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
                <input name="currency" value={dealData.currency} onChange={handleDealChange} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500" placeholder="GBP" />
              </div>
            </div>
          )}
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
          <button type="submit" disabled={isSubmitting} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSubmitting ? 'Converting...' : 'Convert Lead'}</button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Lead detail drawer — "check the lead" (row click → this)
// ============================================================

const DetailRow: React.FC<{ icon: React.ReactNode; label: string; value?: React.ReactNode }> = ({ icon, label, value }) => {
  if (value === undefined || value === null || value === '') return null;
  return (
    <div className="flex items-start gap-3 py-2">
      <div className="w-8 h-8 rounded-lg bg-secondary-100 text-secondary-500 flex items-center justify-center shrink-0">{icon}</div>
      <div className="min-w-0">
        <p className="text-xs font-medium text-secondary-500">{label}</p>
        <p className="text-sm text-secondary-900 break-words">{value}</p>
      </div>
    </div>
  );
};

interface LeadDetailModalProps {
  isOpen: boolean;
  lead: CrmLead | null;
  onClose: () => void;
  onSaved: () => void;
  onConvert: (lead: CrmLead) => void;
  onDelete: (lead: CrmLead) => void;
}

export const LeadDetailModal: React.FC<LeadDetailModalProps> = ({ isOpen, lead, onClose, onSaved, onConvert, onDelete }) => {
  const [status, setStatus] = useState('new');
  const [priority, setPriority] = useState('medium');
  const [notes, setNotes] = useState('');
  const [isSaving, setIsSaving] = useState(false);

  // Sync form fields whenever a different lead is opened.
  useEffect(() => {
    if (lead) {
      setStatus(lead.status);
      setPriority(lead.priority);
      setNotes(lead.notes || '');
    }
  }, [lead]);

  if (!lead) return null;

  const dirty = status !== lead.status || priority !== lead.priority || (notes || '') !== (lead.notes || '');

  const handleSave = async () => {
    setIsSaving(true);
    try {
      await crmService.updateLead(lead.uuid, { status, priority, notes });
      toast.success('Lead updated');
      onSaved();
    } catch (error) {
      console.error('Failed to update lead:', error);
      toast.error('Failed to update lead');
    } finally {
      setIsSaving(false);
    }
  };

  const fullName = `${lead.first_name} ${lead.last_name || ''}`.trim();
  const convertedName = lead.converted_contact_first_name
    ? `${lead.converted_contact_first_name} ${lead.converted_contact_last_name || ''}`.trim()
    : null;

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Lead details" size="2xl">
      <div className="space-y-5">
        {/* Header */}
        <div className="flex items-center gap-3">
          <div className="w-12 h-12 bg-violet-100 rounded-xl flex items-center justify-center">
            <UserPlus className="w-6 h-6 text-violet-600" />
          </div>
          <div>
            <p className="text-lg font-semibold text-secondary-900">{fullName || lead.email || 'Unnamed lead'}</p>
            <div className="flex items-center gap-2 mt-0.5">
              <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${leadStatusColors[lead.status] || 'bg-secondary-100 text-secondary-600'}`}>{lead.status}</span>
              <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-secondary-100 text-secondary-700">{leadSourceLabels[lead.source] || lead.source}</span>
            </div>
          </div>
        </div>

        {/* The message the visitor submitted (stored in notes). This is the
            first thing to read when triaging an inbound enquiry. */}
        {lead.notes ? (
          <div className="rounded-lg bg-secondary-50 border border-secondary-200 p-4">
            <div className="flex items-center gap-2 mb-1.5">
              <MessageSquare className="w-4 h-4 text-secondary-500" />
              <p className="text-xs font-semibold uppercase tracking-wide text-secondary-500">Message</p>
            </div>
            <p className="text-sm text-secondary-900 whitespace-pre-wrap break-words">{lead.notes}</p>
          </div>
        ) : null}

        {/* Captured info */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
          <DetailRow icon={<Mail className="w-4 h-4" />} label="Email" value={lead.email} />
          <DetailRow icon={<Phone className="w-4 h-4" />} label="Phone" value={lead.phone} />
          <DetailRow icon={<Building2 className="w-4 h-4" />} label="Company" value={lead.company_name} />
          <DetailRow icon={<Briefcase className="w-4 h-4" />} label="Job title" value={lead.job_title} />
          <DetailRow icon={<Tag className="w-4 h-4" />} label="Channel" value={lead.channel} />
          <DetailRow icon={<Megaphone className="w-4 h-4" />} label="Campaign" value={lead.campaign} />
          <DetailRow icon={<Globe className="w-4 h-4" />} label="Referrer" value={lead.referrer_url} />
          <DetailRow icon={<Link2 className="w-4 h-4" />} label="Landing page" value={lead.landing_page_url} />
          <DetailRow icon={<Star className="w-4 h-4" />} label="Score" value={String(lead.score)} />
          <DetailRow icon={<CalendarClock className="w-4 h-4" />} label="Captured" value={formatDate(lead.created_at)} />
        </div>

        {convertedName && (
          <div className="rounded-lg bg-purple-50 border border-purple-100 p-3 text-sm text-purple-800">
            Converted to contact <strong>{convertedName}</strong>
            {lead.converted_deal_name ? <> · deal <strong>{lead.converted_deal_name}</strong></> : null}
          </div>
        )}

        {/* Editable triage fields */}
        <div className="border-t border-secondary-200 pt-4 grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Status</label>
            <div className="relative">
              <select value={status} onChange={(e) => setStatus(e.target.value)} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
                {LEAD_STATUS_OPTIONS.filter((o) => o.value !== 'all').map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Priority</label>
            <div className="relative">
              <select value={priority} onChange={(e) => setPriority(e.target.value)} className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer">
                {LEAD_PRIORITY_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div className="sm:col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Message / notes</label>
            <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={4} className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none" placeholder="What the lead submitted — edit or append your own notes..." />
          </div>
        </div>

        {/* Actions */}
        <div className="flex flex-wrap items-center justify-between gap-3 pt-4 border-t border-secondary-200">
          <div className="flex items-center gap-2">
            {lead.status !== 'converted' && (
              <button type="button" onClick={() => onConvert(lead)} className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 transition-colors">
                <ArrowRightCircle className="w-4 h-4" /> Convert
              </button>
            )}
            <button type="button" onClick={() => onDelete(lead)} className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-error-600 bg-error-50 rounded-lg hover:bg-error-100 transition-colors">
              <Trash2 className="w-4 h-4" /> Delete
            </button>
          </div>
          <div className="flex items-center gap-2">
            <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Close</button>
            <button type="button" onClick={handleSave} disabled={!dirty || isSaving} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{isSaving ? 'Saving...' : 'Save changes'}</button>
          </div>
        </div>
      </div>
    </Modal>
  );
};

// ============================================================
// Lead notifications settings modal
// ============================================================

interface LeadNotificationsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const Field: React.FC<{ label: string; hint?: string; children: React.ReactNode }> = ({ label, hint, children }) => (
  <div className="flex items-center justify-between gap-4 py-3">
    <div className="min-w-0">
      <p className="text-sm font-medium text-secondary-900">{label}</p>
      {hint ? <p className="text-xs text-secondary-500 mt-0.5">{hint}</p> : null}
    </div>
    <div className="shrink-0">{children}</div>
  </div>
);

export const LeadNotificationsModal: React.FC<LeadNotificationsModalProps> = ({ isOpen, onClose }) => {
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [showGuide, setShowGuide] = useState(false);

  const [notifyAdmin, setNotifyAdmin] = useState(true);
  const [adminEmail, setAdminEmail] = useState('');
  const [sendConfirmation, setSendConfirmation] = useState(true);
  const [telegramEnabled, setTelegramEnabled] = useState(false);
  const [telegramChatId, setTelegramChatId] = useState('');
  const [telegramToken, setTelegramToken] = useState('');
  const [tokenHint, setTokenHint] = useState('');
  const [hasToken, setHasToken] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    setLoading(true);
    setTelegramToken('');
    crmService.getLeadNotificationSettings()
      .then((s: LeadNotificationSettings) => {
        if (cancelled) return;
        setNotifyAdmin(s.notify_admin);
        setAdminEmail(s.admin_email || '');
        setSendConfirmation(s.send_confirmation);
        setTelegramEnabled(s.telegram_enabled);
        setTelegramChatId(s.telegram_chat_id || '');
        setHasToken(s.has_telegram_token);
        setTokenHint(s.telegram_token_hint || '');
      })
      .catch(() => { if (!cancelled) toast.error('Failed to load notification settings'); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [isOpen]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const saved = await crmService.updateLeadNotificationSettings({
        notify_admin: notifyAdmin,
        admin_email: adminEmail,
        send_confirmation: sendConfirmation,
        telegram_enabled: telegramEnabled,
        telegram_chat_id: telegramChatId,
        telegram_bot_token: telegramToken || undefined,
      });
      setHasToken(saved.has_telegram_token);
      setTokenHint(saved.telegram_token_hint || '');
      setTelegramToken('');
      toast.success('Notification settings saved');
      onClose();
    } catch {
      toast.error('Failed to save — only the namespace owner can change these');
    } finally {
      setSaving(false);
    }
  };

  const handleTest = async () => {
    setTesting(true);
    try {
      await crmService.testTelegram({
        telegram_bot_token: telegramToken || undefined,
        telegram_chat_id: telegramChatId || undefined,
      });
      toast.success('Test message sent — check Telegram');
    } catch (e) {
      const msg = (e as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(msg || 'Telegram test failed — check the token and chat id');
    } finally {
      setTesting(false);
    }
  };

  const inputCls = 'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Lead notifications" size="2xl">
      {loading ? (
        <div className="py-10 text-center text-sm text-secondary-500">Loading settings…</div>
      ) : (
        <div className="space-y-6">
          {/* Email */}
          <section>
            <div className="flex items-center gap-2 mb-1">
              <Mail className="w-4 h-4 text-secondary-500" />
              <h3 className="text-sm font-semibold text-secondary-900">Email</h3>
            </div>
            <div className="divide-y divide-secondary-100 border border-secondary-200 rounded-xl px-4">
              <Field label="Email me on a new lead" hint="Sends to the namespace owner (or the override below).">
                <Toggle checked={notifyAdmin} onChange={setNotifyAdmin} />
              </Field>
              {notifyAdmin && (
                <div className="py-3">
                  <label className="block text-xs font-medium text-secondary-500 mb-1">Send to (optional override)</label>
                  <input type="email" value={adminEmail} onChange={(e) => setAdminEmail(e.target.value)} placeholder="Defaults to the namespace owner's email" className={inputCls} />
                </div>
              )}
              <Field label="Confirmation to the person" hint="Sends a “we got your enquiry” email to the lead.">
                <Toggle checked={sendConfirmation} onChange={setSendConfirmation} />
              </Field>
            </div>
          </section>

          {/* Telegram */}
          <section>
            <div className="flex items-center gap-2 mb-1">
              <Send className="w-4 h-4 text-secondary-500" />
              <h3 className="text-sm font-semibold text-secondary-900">Telegram</h3>
            </div>
            <div className="border border-secondary-200 rounded-xl px-4">
              <Field label="Telegram alerts" hint="Push a message to a chat whenever a lead arrives.">
                <Toggle checked={telegramEnabled} onChange={setTelegramEnabled} />
              </Field>

              {telegramEnabled && (
                <div className="pb-4 space-y-3 border-t border-secondary-100 pt-3">
                  <div>
                    <label className="block text-xs font-medium text-secondary-500 mb-1">Bot token</label>
                    <input
                      type="password"
                      value={telegramToken}
                      onChange={(e) => setTelegramToken(e.target.value)}
                      placeholder={hasToken ? `Saved (${tokenHint}) — leave blank to keep` : 'Paste the token from @BotFather'}
                      className={inputCls}
                      autoComplete="off"
                    />
                  </div>
                  <div>
                    <label className="block text-xs font-medium text-secondary-500 mb-1">Chat ID</label>
                    <input value={telegramChatId} onChange={(e) => setTelegramChatId(e.target.value)} placeholder="e.g. 123456789 or -1001234567890" className={inputCls} />
                  </div>

                  <div className="flex items-center gap-3">
                    <button type="button" onClick={handleTest} disabled={testing} className="inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 transition-colors disabled:opacity-50">
                      <Send className="w-4 h-4" /> {testing ? 'Sending…' : 'Send test message'}
                    </button>
                    <button type="button" onClick={() => setShowGuide((v) => !v)} className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-700">
                      <Info className="w-4 h-4" /> How do I set this up?
                    </button>
                  </div>

                  {showGuide && (
                    <ol className="text-sm text-secondary-600 space-y-2 bg-secondary-50 rounded-lg p-4 list-decimal list-inside">
                      <li>In Telegram, message <strong>@BotFather</strong> → send <code>/newbot</code> → follow the prompts. It gives you a <strong>bot token</strong> — paste it above.</li>
                      <li>Start a chat with your new bot (tap <em>Start</em>), or add it to a group/channel where you want the alerts.</li>
                      <li>Get your <strong>Chat ID</strong>: message <strong>@userinfobot</strong> for a personal chat, or add <strong>@RawDataBot</strong> to a group. Paste the id above (group ids start with <code>-100</code>).</li>
                      <li>Click <strong>Send test message</strong> — you should receive it instantly. Then Save.</li>
                      <li className="flex items-center gap-1">
                        <a href="https://core.telegram.org/bots#how-do-i-create-a-bot" target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-primary-600 hover:underline">Telegram bot docs <ExternalLink className="w-3 h-3" /></a>
                      </li>
                    </ol>
                  )}
                </div>
              )}
            </div>
          </section>

          <div className="flex items-center justify-between gap-3 pt-2 border-t border-secondary-200">
            <p className="text-xs text-secondary-400 flex items-center gap-1"><Bell className="w-3.5 h-3.5" /> Applies to leads captured for this namespace.</p>
            <div className="flex items-center gap-2">
              <button type="button" onClick={onClose} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">Cancel</button>
              <button type="button" onClick={handleSave} disabled={saving} className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50">{saving ? 'Saving…' : 'Save settings'}</button>
            </div>
          </div>
        </div>
      )}
    </Modal>
  );
};
