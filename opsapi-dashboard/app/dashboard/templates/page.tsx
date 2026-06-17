'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import {
  Search,
  FileText,
  RefreshCw,
  Plus,
  Star,
  Copy,
  Trash2,
  Edit3,
  ChevronDown,
  X,
} from 'lucide-react';
import { Input, Table, Pagination, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  templatesService,
  type TemplateFilters,
  type DocumentTemplate,
  type TemplateType,
  type TemplatePayload,
} from '@/services/templates.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

// Type badge component
const TemplatTypeBadge: React.FC<{ type: TemplateType }> = ({ type }) => {
  const config: Record<TemplateType, { label: string; classes: string }> = {
    invoice: { label: 'Invoice', classes: 'bg-blue-100 text-blue-700' },
    timesheet: { label: 'Timesheet', classes: 'bg-green-100 text-green-700' },
  };

  const { label, classes } = config[type] || { label: type, classes: 'bg-gray-100 text-gray-700' };

  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${classes}`}>
      {label}
    </span>
  );
};

// Tab options
const TYPE_TABS: { value: TemplateType | 'all'; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'invoice', label: 'Invoice' },
  { value: 'timesheet', label: 'Timesheet' },
];

// Create Template Modal
interface CreateTemplateModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

const CreateTemplateModal: React.FC<CreateTemplateModalProps> = ({ isOpen, onClose, onCreated }) => {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formData, setFormData] = useState<TemplatePayload>({
    name: '',
    type: 'invoice',
    description: '',
    page_size: 'A4',
    page_orientation: 'portrait',
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.name.trim()) {
      toast.error('Template name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await templatesService.createTemplate(formData);
      toast.success('Template created successfully');
      onCreated();
      onClose();
      setFormData({
        name: '',
        type: 'invoice',
        description: '',
        page_size: 'A4',
        page_orientation: 'portrait',
      });
    } catch (error) {
      console.error('Failed to create template:', error);
      toast.error('Failed to create template');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create Template">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Name */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Template Name *</label>
          <input
            type="text"
            value={formData.name}
            onChange={(e) => setFormData((prev) => ({ ...prev, name: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="e.g. Standard Invoice"
            required
          />
        </div>

        {/* Type */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Type *</label>
          <div className="relative">
            <select
              value={formData.type}
              onChange={(e) => setFormData((prev) => ({ ...prev, type: e.target.value as TemplateType }))}
              className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
            >
              <option value="invoice">Invoice</option>
              <option value="timesheet">Timesheet</option>
            </select>
            <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
          </div>
        </div>

        {/* Description */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
          <textarea
            value={formData.description}
            onChange={(e) => setFormData((prev) => ({ ...prev, description: e.target.value }))}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            rows={3}
            placeholder="Brief description of this template..."
          />
        </div>

        {/* Page Settings */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Page Size</label>
            <div className="relative">
              <select
                value={formData.page_size}
                onChange={(e) => setFormData((prev) => ({ ...prev, page_size: e.target.value }))}
                className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
              >
                <option value="A4">A4</option>
                <option value="Letter">Letter</option>
                <option value="Legal">Legal</option>
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Orientation</label>
            <div className="relative">
              <select
                value={formData.page_orientation}
                onChange={(e) => setFormData((prev) => ({ ...prev, page_orientation: e.target.value }))}
                className="w-full appearance-none px-3 py-2 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface"
              >
                <option value="portrait">Portrait</option>
                <option value="landscape">Landscape</option>
              </select>
              <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
            </div>
          </div>
        </div>

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Creating...' : 'Create Template'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

// Clone Template Modal
interface CloneModalProps {
  isOpen: boolean;
  template: DocumentTemplate | null;
  onClose: () => void;
  onCloned: () => void;
}

const CloneTemplateModal: React.FC<CloneModalProps> = ({ isOpen, template, onClose, onCloned }) => {
  const [name, setName] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    if (template) {
      setName(`${template.name} (Copy)`);
    }
  }, [template]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!template || !name.trim()) return;

    setIsSubmitting(true);
    try {
      await templatesService.cloneTemplate(template.uuid, name.trim());
      toast.success('Template cloned successfully');
      onCloned();
      onClose();
    } catch (error) {
      console.error('Failed to clone template:', error);
      toast.error('Failed to clone template');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Clone Template">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">New Template Name *</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            placeholder="Enter name for the cloned template"
            required
          />
        </div>
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Cloning...' : 'Clone Template'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

function TemplatesPageContent() {
  const router = useRouter();

  // State
  const [templates, setTemplates] = useState<DocumentTemplate[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false);
  const [cloneTarget, setCloneTarget] = useState<DocumentTemplate | null>(null);

  // Filters
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<TemplateType | 'all'>('all');

  // Pagination & Sorting
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState<string>('updated_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const perPage = 10;

  // Refs
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  // Fetch templates
  const fetchTemplates = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const filters: TemplateFilters = {
        page: currentPage,
        perPage,
        orderBy: sortColumn as TemplateFilters['orderBy'],
        orderDir: sortDirection,
      };

      if (searchQuery.trim()) filters.search = searchQuery.trim();
      if (typeFilter !== 'all') filters.type = typeFilter;

      const response = await templatesService.getTemplates(filters);

      if (fetchId === fetchIdRef.current) {
        setTemplates(response.data);
        setTotalPages(response.total_pages);
        setTotalItems(response.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch templates:', error);
        toast.error('Failed to load templates');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, searchQuery, typeFilter]);

  // Fetch templates when filters change
  useEffect(() => {
    fetchTemplates();
  }, [fetchTemplates]);

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

  // Navigate to template editor
  const handleEditTemplate = useCallback(
    (template: DocumentTemplate) => {
      router.push(`/dashboard/templates/${template.uuid}`);
    },
    [router]
  );

  // Set as default
  const handleSetDefault = useCallback(
    async (template: DocumentTemplate) => {
      try {
        await templatesService.setDefault(template.uuid);
        toast.success(`"${template.name}" set as default ${template.type} template`);
        fetchTemplates();
      } catch (error) {
        console.error('Failed to set default template:', error);
        toast.error('Failed to set default template');
      }
    },
    [fetchTemplates]
  );

  // Delete template
  const handleDelete = useCallback(
    async (template: DocumentTemplate) => {
      if (!confirm(`Are you sure you want to delete "${template.name}"? This action cannot be undone.`)) {
        return;
      }

      try {
        await templatesService.deleteTemplate(template.uuid);
        toast.success('Template deleted successfully');
        fetchTemplates();
      } catch (error) {
        console.error('Failed to delete template:', error);
        toast.error('Failed to delete template');
      }
    },
    [fetchTemplates]
  );

  // Handle template created or cloned
  const handleTemplateCreated = useCallback(() => {
    fetchTemplates();
  }, [fetchTemplates]);

  // Table columns
  const columns: TableColumn<DocumentTemplate>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Name',
        sortable: true,
        render: (template) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
              <FileText className="w-5 h-5 text-secondary-500" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">{template.name}</p>
              {template.description && (
                <p className="text-xs text-secondary-500 truncate max-w-[250px]">{template.description}</p>
              )}
            </div>
          </div>
        ),
      },
      {
        key: 'type',
        header: 'Type',
        render: (template) => <TemplatTypeBadge type={template.type} />,
      },
      {
        key: 'is_default',
        header: 'Default',
        render: (template) => (
          <div className="flex items-center">
            {template.is_default ? (
              <Star className="w-5 h-5 text-amber-500 fill-amber-500" />
            ) : (
              <Star className="w-5 h-5 text-secondary-300" />
            )}
          </div>
        ),
      },
      {
        key: 'version',
        header: 'Version',
        render: (template) => (
          <span className="text-sm text-secondary-700">v{template.version}</span>
        ),
      },
      {
        key: 'updated_at',
        header: 'Last Updated',
        sortable: true,
        render: (template) => (
          <span className="text-sm text-secondary-700">{formatDate(template.updated_at)}</span>
        ),
      },
      {
        key: 'actions',
        header: 'Actions',
        render: (template) => (
          <div className="flex items-center gap-1" onClick={(e) => e.stopPropagation()}>
            <button
              onClick={() => handleEditTemplate(template)}
              className="p-1.5 text-secondary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit"
            >
              <Edit3 className="w-4 h-4" />
            </button>
            <button
              onClick={() => setCloneTarget(template)}
              className="p-1.5 text-secondary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
              title="Clone"
            >
              <Copy className="w-4 h-4" />
            </button>
            {!template.is_default && (
              <button
                onClick={() => handleSetDefault(template)}
                className="p-1.5 text-secondary-500 hover:text-amber-600 hover:bg-amber-50 rounded-lg transition-colors"
                title="Set as Default"
              >
                <Star className="w-4 h-4" />
              </button>
            )}
            <button
              onClick={() => handleDelete(template)}
              className="p-1.5 text-secondary-500 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
              title="Delete"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          </div>
        ),
      },
    ],
    [handleEditTemplate, handleSetDefault, handleDelete]
  );

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Document Templates</h1>
          <p className="text-secondary-500 mt-1">Manage invoice and timesheet templates</p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => fetchTemplates()}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
          <button
            onClick={() => setIsCreateModalOpen(true)}
            className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors"
          >
            <Plus className="w-4 h-4" />
            Create Template
          </button>
        </div>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          {/* Type Tabs */}
          <div className="flex bg-secondary-100 rounded-lg p-1">
            {TYPE_TABS.map((tab) => (
              <button
                key={tab.value}
                onClick={() => {
                  setTypeFilter(tab.value);
                  setCurrentPage(1);
                }}
                className={`px-4 py-1.5 text-sm font-medium rounded-md transition-colors ${
                  typeFilter === tab.value
                    ? 'bg-surface text-secondary-900 shadow-sm'
                    : 'text-secondary-600 hover:text-secondary-900'
                }`}
              >
                {tab.label}
              </button>
            ))}
          </div>

          {/* Search */}
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search templates by name..."
              value={searchQuery}
              onChange={(e) => handleSearchChange(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>

          {/* Clear Search */}
          {searchQuery && (
            <button
              onClick={() => {
                setSearchQuery('');
                setCurrentPage(1);
              }}
              className="flex items-center gap-1 px-3 py-2.5 text-sm text-red-600 hover:bg-red-50 rounded-lg transition-colors"
            >
              <X className="w-4 h-4" />
              Clear
            </button>
          )}
        </div>
      </Card>

      {/* Templates Table */}
      <div>
        <Table
          columns={columns}
          data={templates}
          keyExtractor={(template) => template.uuid}
          onRowClick={handleEditTemplate}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage={
            searchQuery || typeFilter !== 'all'
              ? 'No templates match your filters. Try adjusting your search criteria.'
              : 'No templates found. Create your first template to get started.'
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

      {/* Create Template Modal */}
      <CreateTemplateModal
        isOpen={isCreateModalOpen}
        onClose={() => setIsCreateModalOpen(false)}
        onCreated={handleTemplateCreated}
      />

      {/* Clone Template Modal */}
      <CloneTemplateModal
        isOpen={!!cloneTarget}
        template={cloneTarget}
        onClose={() => setCloneTarget(null)}
        onCloned={handleTemplateCreated}
      />
    </div>
  );
}

export default function TemplatesPage() {
  return (
    <ProtectedPage module="templates" title="Document Templates">
      <TemplatesPageContent />
    </ProtectedPage>
  );
}
