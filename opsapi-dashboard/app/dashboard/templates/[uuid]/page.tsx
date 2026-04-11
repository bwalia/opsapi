'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useRouter, useParams } from 'next/navigation';
import {
  ArrowLeft,
  Save,
  Eye,
  Star,
  Copy,
  History,
  Code,
  ChevronDown,
  ChevronRight,
  Search,
  RefreshCw,
  FileText,
  Palette,
  Settings,
  X,
  Check,
  AlertCircle,
} from 'lucide-react';
import { Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  templatesService,
  type DocumentTemplate,
  type TemplateVariable,
  type TemplateVersion,
  type TemplatePayload,
} from '@/services/templates.service';
import { formatDate, formatDateTime } from '@/lib/utils';
import toast from 'react-hot-toast';

// ============================================================================
// Snippets data
// ============================================================================
interface Snippet {
  name: string;
  description: string;
  html: string;
}

const SNIPPETS: Snippet[] = [
  {
    name: 'Table Row Loop',
    description: 'Loop over line items in a table',
    html: `{% for item in items %}
<tr>
  <td>{{item.description}}</td>
  <td>{{item.quantity}}</td>
  <td>{{item.unit_price}}</td>
  <td>{{item.total}}</td>
</tr>
{% endfor %}`,
  },
  {
    name: 'Conditional Block',
    description: 'Show content conditionally',
    html: `{% if notes %}
<div class="notes">
  <h4>Notes</h4>
  <p>{{notes}}</p>
</div>
{% endif %}`,
  },
  {
    name: 'Company Header',
    description: 'Company branding header block',
    html: `<div class="header" style="display:flex;justify-content:space-between;align-items:center;margin-bottom:30px;">
  <div>
    <h1 style="margin:0;font-size:24px;color:{{theme.primary_color}};">{{company.name}}</h1>
    <p style="margin:4px 0 0;color:#666;">{{company.address}}</p>
    <p style="margin:2px 0 0;color:#666;">{{company.email}} | {{company.phone}}</p>
  </div>
  <div style="text-align:right;">
    <h2 style="margin:0;font-size:28px;color:{{theme.primary_color}};">INVOICE</h2>
    <p style="margin:4px 0 0;">#{{invoice.number}}</p>
    <p style="margin:2px 0 0;">Date: {{invoice.date}}</p>
  </div>
</div>`,
  },
  {
    name: 'Line Items Table',
    description: 'Full line items table with header',
    html: `<table style="width:100%;border-collapse:collapse;margin:20px 0;">
  <thead>
    <tr style="background:{{theme.primary_color}};color:#fff;">
      <th style="padding:10px;text-align:left;">Description</th>
      <th style="padding:10px;text-align:right;width:80px;">Qty</th>
      <th style="padding:10px;text-align:right;width:100px;">Rate</th>
      <th style="padding:10px;text-align:right;width:100px;">Amount</th>
    </tr>
  </thead>
  <tbody>
    {% for item in items %}
    <tr style="border-bottom:1px solid #eee;">
      <td style="padding:10px;">{{item.description}}</td>
      <td style="padding:10px;text-align:right;">{{item.quantity}}</td>
      <td style="padding:10px;text-align:right;">{{item.unit_price}}</td>
      <td style="padding:10px;text-align:right;">{{item.total}}</td>
    </tr>
    {% endfor %}
  </tbody>
</table>`,
  },
  {
    name: 'Totals Section',
    description: 'Subtotal, tax, and total section',
    html: `<div style="display:flex;justify-content:flex-end;margin-top:20px;">
  <table style="width:250px;">
    <tr>
      <td style="padding:6px 10px;color:#666;">Subtotal:</td>
      <td style="padding:6px 10px;text-align:right;">{{invoice.subtotal}}</td>
    </tr>
    <tr>
      <td style="padding:6px 10px;color:#666;">Tax:</td>
      <td style="padding:6px 10px;text-align:right;">{{invoice.tax_total}}</td>
    </tr>
    <tr style="border-top:2px solid {{theme.primary_color}};font-weight:bold;font-size:1.1em;">
      <td style="padding:10px;">Total:</td>
      <td style="padding:10px;text-align:right;color:{{theme.primary_color}};">{{invoice.total}}</td>
    </tr>
  </table>
</div>`,
  },
];

// ============================================================================
// Variable groups (fallback when API unavailable)
// ============================================================================
interface VariableGroup {
  name: string;
  variables: TemplateVariable[];
}

function groupVariables(variables: TemplateVariable[]): VariableGroup[] {
  const groups: Record<string, TemplateVariable[]> = {};

  variables.forEach((v) => {
    const prefix = v.path.split('.')[0] || 'Other';
    const groupName = prefix.charAt(0).toUpperCase() + prefix.slice(1);
    if (!groups[groupName]) groups[groupName] = [];
    groups[groupName].push(v);
  });

  return Object.entries(groups).map(([name, variables]) => ({ name, variables }));
}

const FALLBACK_VARIABLES: Record<string, TemplateVariable[]> = {
  invoice: [
    { path: 'company.name', description: 'Company name', example: 'Acme Corp' },
    { path: 'company.address', description: 'Company address', example: '123 Main St' },
    { path: 'company.email', description: 'Company email', example: 'info@acme.com' },
    { path: 'company.phone', description: 'Company phone', example: '+1 555-0100' },
    { path: 'invoice.number', description: 'Invoice number', example: 'INV-001' },
    { path: 'invoice.date', description: 'Issue date', example: '2025-01-15' },
    { path: 'invoice.due_date', description: 'Due date', example: '2025-02-15' },
    { path: 'invoice.subtotal', description: 'Subtotal amount', example: '$1,000.00' },
    { path: 'invoice.tax_total', description: 'Tax total', example: '$100.00' },
    { path: 'invoice.total', description: 'Total amount', example: '$1,100.00' },
    { path: 'invoice.notes', description: 'Invoice notes', example: 'Thank you for your business' },
    { path: 'client.name', description: 'Client name', example: 'John Doe' },
    { path: 'client.email', description: 'Client email', example: 'john@example.com' },
    { path: 'client.address', description: 'Client address', example: '456 Oak Ave' },
    { path: 'theme.primary_color', description: 'Primary color', example: '#2563eb' },
    { path: 'theme.secondary_color', description: 'Secondary color', example: '#64748b' },
    { path: 'theme.font_family', description: 'Font family', example: 'Inter, sans-serif' },
  ],
  timesheet: [
    { path: 'company.name', description: 'Company name', example: 'Acme Corp' },
    { path: 'company.address', description: 'Company address', example: '123 Main St' },
    { path: 'company.email', description: 'Company email', example: 'info@acme.com' },
    { path: 'company.phone', description: 'Company phone', example: '+1 555-0100' },
    { path: 'timesheet.period_start', description: 'Period start date', example: '2025-01-01' },
    { path: 'timesheet.period_end', description: 'Period end date', example: '2025-01-15' },
    { path: 'timesheet.total_hours', description: 'Total hours', example: '80.00' },
    { path: 'timesheet.total_amount', description: 'Total amount', example: '$4,000.00' },
    { path: 'employee.name', description: 'Employee name', example: 'Jane Smith' },
    { path: 'employee.email', description: 'Employee email', example: 'jane@example.com' },
    { path: 'employee.role', description: 'Employee role', example: 'Developer' },
    { path: 'theme.primary_color', description: 'Primary color', example: '#2563eb' },
    { path: 'theme.secondary_color', description: 'Secondary color', example: '#64748b' },
    { path: 'theme.font_family', description: 'Font family', example: 'Inter, sans-serif' },
  ],
};

// ============================================================================
// Version History Modal
// ============================================================================
interface VersionHistoryModalProps {
  isOpen: boolean;
  onClose: () => void;
  versions: TemplateVersion[];
  currentVersion: number;
  onRestore: (version: number) => void;
  isRestoring: boolean;
}

const VersionHistoryModal: React.FC<VersionHistoryModalProps> = ({
  isOpen,
  onClose,
  versions,
  currentVersion,
  onRestore,
  isRestoring,
}) => (
  <Modal isOpen={isOpen} onClose={onClose} title="Version History">
    <div className="space-y-2 max-h-[400px] overflow-y-auto">
      {versions.length === 0 ? (
        <p className="text-sm text-secondary-500 text-center py-8">No version history available.</p>
      ) : (
        versions.map((v) => (
          <div
            key={v.version}
            className={`flex items-center justify-between p-3 rounded-lg border ${
              v.version === currentVersion
                ? 'border-primary-300 bg-primary-50'
                : 'border-secondary-200 hover:bg-secondary-50'
            }`}
          >
            <div>
              <p className="text-sm font-medium text-secondary-900">
                Version {v.version}
                {v.version === currentVersion && (
                  <span className="ml-2 text-xs text-primary-600 font-normal">(current)</span>
                )}
              </p>
              <p className="text-xs text-secondary-500">
                {formatDateTime(v.created_at)}
                {v.updated_by && ` by ${v.updated_by}`}
              </p>
              {v.change_summary && (
                <p className="text-xs text-secondary-500 mt-1">{v.change_summary}</p>
              )}
            </div>
            {v.version !== currentVersion && (
              <button
                onClick={() => onRestore(v.version)}
                disabled={isRestoring}
                className="px-3 py-1.5 text-xs font-medium text-primary-600 bg-white border border-primary-300 rounded-lg hover:bg-primary-50 disabled:opacity-50 transition-colors"
              >
                Restore
              </button>
            )}
          </div>
        ))
      )}
    </div>
  </Modal>
);

// ============================================================================
// Main Template Builder Page
// ============================================================================
function TemplateBuilderContent() {
  const router = useRouter();
  const params = useParams();
  const uuid = params.uuid as string;

  // Core state
  const [template, setTemplate] = useState<DocumentTemplate | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [hasUnsavedChanges, setHasUnsavedChanges] = useState(false);

  // Editor state
  const [templateHtml, setTemplateHtml] = useState('');
  const [templateCss, setTemplateCss] = useState('');
  const [activeEditorTab, setActiveEditorTab] = useState<'html' | 'preview'>('html');

  // Preview state
  const [previewHtml, setPreviewHtml] = useState('');
  const [isPreviewLoading, setIsPreviewLoading] = useState(false);

  // Properties state
  const [templateName, setTemplateName] = useState('');
  const [description, setDescription] = useState('');
  const [pageSize, setPageSize] = useState('A4');
  const [pageOrientation, setPageOrientation] = useState('portrait');
  const [marginTop, setMarginTop] = useState('20mm');
  const [marginBottom, setMarginBottom] = useState('20mm');
  const [marginLeft, setMarginLeft] = useState('15mm');
  const [marginRight, setMarginRight] = useState('15mm');
  const [primaryColor, setPrimaryColor] = useState('#2563eb');
  const [secondaryColor, setSecondaryColor] = useState('#64748b');
  const [fontFamily, setFontFamily] = useState('Inter, sans-serif');
  const [footerText, setFooterText] = useState('');
  const [configJson, setConfigJson] = useState('{}');

  // Variables & panels
  const [variables, setVariables] = useState<TemplateVariable[]>([]);
  const [variableSearch, setVariableSearch] = useState('');
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({});
  const [expandedSnippets, setExpandedSnippets] = useState(true);
  const [expandedVariables, setExpandedVariables] = useState(true);

  // Version history
  const [versions, setVersions] = useState<TemplateVersion[]>([]);
  const [showVersionHistory, setShowVersionHistory] = useState(false);
  const [isRestoring, setIsRestoring] = useState(false);

  // Refs
  const htmlEditorRef = useRef<HTMLTextAreaElement>(null);
  const previewDebounceRef = useRef<NodeJS.Timeout | null>(null);
  const fetchIdRef = useRef(0);

  // ----------------------------------
  // Load template
  // ----------------------------------
  const loadTemplate = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const data = await templatesService.getTemplate(uuid);

      if (fetchId !== fetchIdRef.current) return;

      setTemplate(data);
      setTemplateHtml(data.template_html || '');
      setTemplateCss(data.template_css || '');
      setTemplateName(data.name);
      setDescription(data.description || '');
      setPageSize(data.page_size || 'A4');
      setPageOrientation(data.page_orientation || 'portrait');
      setMarginTop(data.margin_top || '20mm');
      setMarginBottom(data.margin_bottom || '20mm');
      setMarginLeft(data.margin_left || '15mm');
      setMarginRight(data.margin_right || '15mm');
      setConfigJson(JSON.stringify(data.config || {}, null, 2));

      // Extract theme from config if present
      const cfg = data.config || {};
      if (cfg.primary_color) setPrimaryColor(cfg.primary_color as string);
      if (cfg.secondary_color) setSecondaryColor(cfg.secondary_color as string);
      if (cfg.font_family) setFontFamily(cfg.font_family as string);
      if (cfg.footer_text) setFooterText(cfg.footer_text as string);

      setHasUnsavedChanges(false);
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to load template:', error);
        toast.error('Failed to load template');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [uuid]);

  // Load variables
  const loadVariables = useCallback(async (type: string) => {
    try {
      const vars = await templatesService.getVariables(type as 'invoice' | 'timesheet');
      if (vars && vars.length > 0) {
        setVariables(vars);
      } else {
        setVariables(FALLBACK_VARIABLES[type] || FALLBACK_VARIABLES.invoice);
      }
    } catch {
      // Fallback to local data
      setVariables(FALLBACK_VARIABLES[type] || FALLBACK_VARIABLES.invoice);
    }
  }, []);

  // Initial load
  useEffect(() => {
    loadTemplate();
  }, [loadTemplate]);

  // Load variables when template type is known
  useEffect(() => {
    if (template?.type) {
      loadVariables(template.type);
      // Expand all groups by default
      const groups = groupVariables(FALLBACK_VARIABLES[template.type] || []);
      const expanded: Record<string, boolean> = {};
      groups.forEach((g) => {
        expanded[g.name] = true;
      });
      setExpandedGroups(expanded);
    }
  }, [template?.type, loadVariables]);

  // ----------------------------------
  // Auto-preview on edit (debounced)
  // ----------------------------------
  useEffect(() => {
    if (activeEditorTab !== 'preview') return;

    if (previewDebounceRef.current) {
      clearTimeout(previewDebounceRef.current);
    }

    previewDebounceRef.current = setTimeout(() => {
      refreshPreview();
    }, 2000);

    return () => {
      if (previewDebounceRef.current) {
        clearTimeout(previewDebounceRef.current);
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [templateHtml, templateCss, activeEditorTab]);

  // ----------------------------------
  // Actions
  // ----------------------------------
  const refreshPreview = useCallback(async () => {
    if (!uuid) return;
    setIsPreviewLoading(true);
    try {
      const result = await templatesService.previewTemplate(uuid, {
        template_html: templateHtml,
        template_css: templateCss,
        primary_color: primaryColor,
        secondary_color: secondaryColor,
        font_family: fontFamily,
      });
      setPreviewHtml(result.html || '');
    } catch {
      // Fallback: render raw HTML with CSS in an iframe-compatible wrapper
      setPreviewHtml(`<style>${templateCss}</style>${templateHtml}`);
    } finally {
      setIsPreviewLoading(false);
    }
  }, [uuid, templateHtml, templateCss, primaryColor, secondaryColor, fontFamily]);

  const handleSave = useCallback(async () => {
    if (!template) return;

    setIsSaving(true);
    try {
      // Build config from theme fields
      let config: Record<string, unknown> = {};
      try {
        config = JSON.parse(configJson);
      } catch {
        // Keep existing if JSON is invalid
        config = template.config || {};
      }
      config.primary_color = primaryColor;
      config.secondary_color = secondaryColor;
      config.font_family = fontFamily;
      config.footer_text = footerText;

      const payload: Partial<TemplatePayload> = {
        name: templateName,
        description,
        template_html: templateHtml,
        template_css: templateCss,
        page_size: pageSize,
        page_orientation: pageOrientation,
        margin_top: marginTop,
        margin_bottom: marginBottom,
        margin_left: marginLeft,
        margin_right: marginRight,
        config,
      };

      const updated = await templatesService.updateTemplate(uuid, payload);
      setTemplate(updated);
      setHasUnsavedChanges(false);
      toast.success('Template saved successfully');
    } catch (error) {
      console.error('Failed to save template:', error);
      toast.error('Failed to save template');
    } finally {
      setIsSaving(false);
    }
  }, [
    template, uuid, templateName, description, templateHtml, templateCss,
    pageSize, pageOrientation, marginTop, marginBottom, marginLeft, marginRight,
    primaryColor, secondaryColor, fontFamily, footerText, configJson,
  ]);

  const handleSetDefault = useCallback(async () => {
    if (!template) return;
    try {
      await templatesService.setDefault(uuid);
      toast.success(`Set as default ${template.type} template`);
      loadTemplate();
    } catch (error) {
      console.error('Failed to set default:', error);
      toast.error('Failed to set as default');
    }
  }, [template, uuid, loadTemplate]);

  const handleClone = useCallback(async () => {
    if (!template) return;
    const name = prompt('Enter name for the cloned template:', `${template.name} (Copy)`);
    if (!name) return;

    try {
      const cloned = await templatesService.cloneTemplate(uuid, name);
      toast.success('Template cloned successfully');
      router.push(`/dashboard/templates/${cloned.uuid}`);
    } catch (error) {
      console.error('Failed to clone template:', error);
      toast.error('Failed to clone template');
    }
  }, [template, uuid, router]);

  const handlePreviewPdf = useCallback(async () => {
    if (!template) return;
    toast.loading('Generating PDF preview...', { id: 'pdf-preview' });
    try {
      const blob = template.type === 'invoice'
        ? await templatesService.generateInvoicePdf('sample', uuid)
        : await templatesService.generateTimesheetPdf('sample', uuid);

      const url = URL.createObjectURL(blob);
      window.open(url, '_blank');
      toast.success('PDF generated', { id: 'pdf-preview' });
    } catch {
      toast.error('PDF preview is not available for unsaved templates', { id: 'pdf-preview' });
    }
  }, [template, uuid]);

  const handleShowVersions = useCallback(async () => {
    try {
      const v = await templatesService.getVersions(uuid);
      setVersions(v);
      setShowVersionHistory(true);
    } catch {
      toast.error('Failed to load version history');
    }
  }, [uuid]);

  const handleRestoreVersion = useCallback(async (version: number) => {
    setIsRestoring(true);
    try {
      await templatesService.restoreVersion(uuid, version);
      toast.success(`Restored to version ${version}`);
      setShowVersionHistory(false);
      loadTemplate();
    } catch (error) {
      console.error('Failed to restore version:', error);
      toast.error('Failed to restore version');
    } finally {
      setIsRestoring(false);
    }
  }, [uuid, loadTemplate]);

  // ----------------------------------
  // Insert variable / snippet at cursor
  // ----------------------------------
  const insertAtCursor = useCallback((text: string) => {
    const textarea = htmlEditorRef.current;
    if (!textarea) {
      setTemplateHtml((prev) => prev + text);
      setHasUnsavedChanges(true);
      return;
    }

    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const before = templateHtml.substring(0, start);
    const after = templateHtml.substring(end);
    const newValue = before + text + after;

    setTemplateHtml(newValue);
    setHasUnsavedChanges(true);

    // Restore cursor position after React re-render
    requestAnimationFrame(() => {
      textarea.focus();
      textarea.selectionStart = start + text.length;
      textarea.selectionEnd = start + text.length;
    });
  }, [templateHtml]);

  const handleInsertVariable = useCallback((path: string) => {
    insertAtCursor(`{{${path}}}`);
    // Switch to HTML tab if on preview
    setActiveEditorTab('html');
  }, [insertAtCursor]);

  const handleInsertSnippet = useCallback((html: string) => {
    insertAtCursor('\n' + html + '\n');
    setActiveEditorTab('html');
  }, [insertAtCursor]);

  // Mark changes as unsaved
  const markDirty = useCallback(() => {
    setHasUnsavedChanges(true);
  }, []);

  // Filtered & grouped variables
  const variableGroups = useMemo(() => {
    let filtered = variables;
    if (variableSearch.trim()) {
      const q = variableSearch.toLowerCase();
      filtered = variables.filter(
        (v) =>
          v.path.toLowerCase().includes(q) ||
          v.description.toLowerCase().includes(q)
      );
    }
    return groupVariables(filtered);
  }, [variables, variableSearch]);

  // ----------------------------------
  // Loading state
  // ----------------------------------
  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-[calc(100vh-64px)]">
        <div className="text-center">
          <RefreshCw className="w-8 h-8 text-primary-500 animate-spin mx-auto" />
          <p className="text-secondary-500 mt-3">Loading template...</p>
        </div>
      </div>
    );
  }

  if (!template) {
    return (
      <div className="flex items-center justify-center h-[calc(100vh-64px)]">
        <div className="text-center">
          <AlertCircle className="w-12 h-12 text-red-400 mx-auto" />
          <p className="text-secondary-700 font-medium mt-3">Template not found</p>
          <button
            onClick={() => router.push('/dashboard/templates')}
            className="mt-4 px-4 py-2 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 transition-colors"
          >
            Back to Templates
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-[calc(100vh-64px)]">
      {/* ================================================================ */}
      {/* TOP BAR                                                          */}
      {/* ================================================================ */}
      <div className="flex items-center justify-between px-4 py-2.5 border-b border-secondary-200 bg-white shrink-0">
        {/* Left side */}
        <div className="flex items-center gap-3">
          <button
            onClick={() => router.push('/dashboard/templates')}
            className="p-1.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            title="Back to templates"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>

          <div className="flex items-center gap-2">
            <input
              type="text"
              value={templateName}
              onChange={(e) => {
                setTemplateName(e.target.value);
                markDirty();
              }}
              className="text-lg font-semibold text-secondary-900 bg-transparent border-none outline-none focus:ring-0 px-0 max-w-[300px]"
              title="Click to edit template name"
            />
            <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${
              template.is_active ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-600'
            }`}>
              {template.is_active ? 'Active' : 'Inactive'}
            </span>
          </div>
        </div>

        {/* Right side */}
        <div className="flex items-center gap-2">
          {/* Save indicator */}
          <span className={`text-xs px-2 py-1 rounded ${
            hasUnsavedChanges
              ? 'text-amber-700 bg-amber-50'
              : 'text-green-700 bg-green-50'
          }`}>
            {hasUnsavedChanges ? 'Unsaved changes' : 'Saved'}
          </span>

          <button
            onClick={handleSave}
            disabled={isSaving}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 transition-colors"
          >
            <Save className="w-4 h-4" />
            {isSaving ? 'Saving...' : 'Save'}
          </button>

          <button
            onClick={handlePreviewPdf}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            <Eye className="w-4 h-4" />
            Preview PDF
          </button>

          {!template.is_default && (
            <button
              onClick={handleSetDefault}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
              title="Set as default"
            >
              <Star className="w-4 h-4" />
            </button>
          )}

          <button
            onClick={handleClone}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
            title="Clone template"
          >
            <Copy className="w-4 h-4" />
          </button>

          <button
            onClick={handleShowVersions}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
            title="Version history"
          >
            <History className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* ================================================================ */}
      {/* 3-PANEL LAYOUT                                                   */}
      {/* ================================================================ */}
      <div className="flex flex-1 min-h-0">
        {/* ============================================================== */}
        {/* LEFT PANEL - Variables & Snippets                              */}
        {/* ============================================================== */}
        <div className="w-[250px] border-r border-secondary-200 overflow-y-auto bg-secondary-50 shrink-0">
          {/* Variables Section */}
          <div className="border-b border-secondary-200">
            <button
              onClick={() => setExpandedVariables(!expandedVariables)}
              className="flex items-center justify-between w-full px-3 py-2.5 text-sm font-semibold text-secondary-700 hover:bg-secondary-100 transition-colors"
            >
              <span className="flex items-center gap-2">
                <Code className="w-4 h-4" />
                Variables
              </span>
              {expandedVariables ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
            </button>

            {expandedVariables && (
              <div className="px-2 pb-2">
                {/* Search */}
                <div className="relative mb-2">
                  <Search className="w-3.5 h-3.5 absolute left-2.5 top-1/2 -translate-y-1/2 text-secondary-400" />
                  <input
                    type="text"
                    value={variableSearch}
                    onChange={(e) => setVariableSearch(e.target.value)}
                    placeholder="Filter variables..."
                    className="w-full pl-8 pr-2 py-1.5 text-xs border border-secondary-200 rounded-md bg-white focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                  />
                </div>

                {/* Grouped variables */}
                {variableGroups.map((group) => (
                  <div key={group.name} className="mb-1">
                    <button
                      onClick={() =>
                        setExpandedGroups((prev) => ({
                          ...prev,
                          [group.name]: !prev[group.name],
                        }))
                      }
                      className="flex items-center gap-1 w-full px-1.5 py-1 text-xs font-semibold text-secondary-600 hover:text-secondary-800 transition-colors"
                    >
                      {expandedGroups[group.name] ? (
                        <ChevronDown className="w-3 h-3" />
                      ) : (
                        <ChevronRight className="w-3 h-3" />
                      )}
                      {group.name}
                      <span className="text-secondary-400 ml-auto">{group.variables.length}</span>
                    </button>

                    {expandedGroups[group.name] && (
                      <div className="ml-2">
                        {group.variables.map((v) => (
                          <button
                            key={v.path}
                            onClick={() => handleInsertVariable(v.path)}
                            className="w-full text-left px-2 py-1.5 text-xs rounded hover:bg-white hover:shadow-sm transition-all group"
                            title={`${v.description} - Example: ${v.example}`}
                          >
                            <span className="font-mono text-primary-700 group-hover:text-primary-800">
                              {`{{${v.path}}}`}
                            </span>
                            <p className="text-secondary-400 text-[10px] truncate mt-0.5">
                              {v.example}
                            </p>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Snippets Section */}
          <div>
            <button
              onClick={() => setExpandedSnippets(!expandedSnippets)}
              className="flex items-center justify-between w-full px-3 py-2.5 text-sm font-semibold text-secondary-700 hover:bg-secondary-100 transition-colors"
            >
              <span className="flex items-center gap-2">
                <FileText className="w-4 h-4" />
                Snippets
              </span>
              {expandedSnippets ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
            </button>

            {expandedSnippets && (
              <div className="px-2 pb-2 space-y-1">
                {SNIPPETS.map((snippet) => (
                  <button
                    key={snippet.name}
                    onClick={() => handleInsertSnippet(snippet.html)}
                    className="w-full text-left px-2.5 py-2 rounded-md hover:bg-white hover:shadow-sm transition-all"
                  >
                    <p className="text-xs font-medium text-secondary-800">{snippet.name}</p>
                    <p className="text-[10px] text-secondary-400 mt-0.5">{snippet.description}</p>
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>

        {/* ============================================================== */}
        {/* CENTER PANEL - Editor / Preview                                */}
        {/* ============================================================== */}
        <div className="flex-1 flex flex-col min-w-0">
          {/* Tabs */}
          <div className="flex items-center border-b border-secondary-200 bg-white px-4 shrink-0">
            <button
              onClick={() => setActiveEditorTab('html')}
              className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
                activeEditorTab === 'html'
                  ? 'border-primary-600 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:text-secondary-700'
              }`}
            >
              <span className="flex items-center gap-1.5">
                <Code className="w-4 h-4" />
                Edit HTML
              </span>
            </button>
            <button
              onClick={() => {
                setActiveEditorTab('preview');
                refreshPreview();
              }}
              className={`px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
                activeEditorTab === 'preview'
                  ? 'border-primary-600 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:text-secondary-700'
              }`}
            >
              <span className="flex items-center gap-1.5">
                <Eye className="w-4 h-4" />
                Preview
              </span>
            </button>

            {activeEditorTab === 'preview' && (
              <button
                onClick={refreshPreview}
                disabled={isPreviewLoading}
                className="ml-auto flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-secondary-600 hover:text-secondary-800 transition-colors"
              >
                <RefreshCw className={`w-3.5 h-3.5 ${isPreviewLoading ? 'animate-spin' : ''}`} />
                Refresh Preview
              </button>
            )}
          </div>

          {/* Editor content */}
          <div className="flex-1 overflow-hidden">
            {activeEditorTab === 'html' ? (
              <div className="flex flex-col h-full">
                {/* HTML Editor */}
                <div className="flex-1 min-h-0">
                  <div className="h-full relative">
                    <label className="absolute top-2 left-3 text-[10px] font-semibold text-secondary-400 uppercase tracking-wider z-10">
                      Template HTML
                    </label>
                    <textarea
                      ref={htmlEditorRef}
                      value={templateHtml}
                      onChange={(e) => {
                        setTemplateHtml(e.target.value);
                        markDirty();
                      }}
                      className="w-full h-full pt-7 px-3 pb-3 font-mono text-sm text-secondary-800 bg-secondary-50 border-none outline-none resize-none"
                      style={{
                        tabSize: 2,
                        lineHeight: '1.6',
                        counterReset: 'line',
                      }}
                      spellCheck={false}
                      placeholder="Enter your template HTML here..."
                    />
                  </div>
                </div>

                {/* CSS Editor (smaller) */}
                <div className="h-[180px] border-t border-secondary-200 shrink-0">
                  <div className="h-full relative">
                    <label className="absolute top-2 left-3 text-[10px] font-semibold text-secondary-400 uppercase tracking-wider z-10">
                      Template CSS
                    </label>
                    <textarea
                      value={templateCss}
                      onChange={(e) => {
                        setTemplateCss(e.target.value);
                        markDirty();
                      }}
                      className="w-full h-full pt-7 px-3 pb-3 font-mono text-xs text-secondary-800 bg-white border-none outline-none resize-none"
                      style={{ tabSize: 2, lineHeight: '1.6' }}
                      spellCheck={false}
                      placeholder="/* Custom CSS styles */"
                    />
                  </div>
                </div>
              </div>
            ) : (
              /* Preview Tab */
              <div className="h-full flex items-start justify-center overflow-auto bg-secondary-100 p-6">
                {isPreviewLoading ? (
                  <div className="flex items-center justify-center h-full">
                    <RefreshCw className="w-6 h-6 text-primary-500 animate-spin" />
                  </div>
                ) : (
                  <div
                    className="bg-white shadow-lg"
                    style={{
                      width: pageOrientation === 'landscape' ? '297mm' : '210mm',
                      minHeight: pageOrientation === 'landscape' ? '210mm' : '297mm',
                      maxWidth: '100%',
                      padding: '20mm',
                      transform: 'scale(0.7)',
                      transformOrigin: 'top center',
                    }}
                  >
                    {previewHtml ? (
                      <div dangerouslySetInnerHTML={{ __html: previewHtml }} />
                    ) : (
                      <div className="flex flex-col items-center justify-center h-[400px] text-secondary-400">
                        <Eye className="w-12 h-12 mb-3" />
                        <p className="text-sm">Click &quot;Refresh Preview&quot; to see a rendered preview</p>
                      </div>
                    )}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>

        {/* ============================================================== */}
        {/* RIGHT PANEL - Properties & Settings                            */}
        {/* ============================================================== */}
        <div className="w-[280px] border-l border-secondary-200 overflow-y-auto bg-white shrink-0">
          <div className="p-4 space-y-5">
            {/* Template Info */}
            <section>
              <h3 className="flex items-center gap-2 text-xs font-semibold text-secondary-500 uppercase tracking-wider mb-3">
                <Settings className="w-3.5 h-3.5" />
                Properties
              </h3>

              <div className="space-y-3">
                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Name</label>
                  <input
                    type="text"
                    value={templateName}
                    onChange={(e) => {
                      setTemplateName(e.target.value);
                      markDirty();
                    }}
                    className="w-full px-2.5 py-1.5 text-sm border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                  />
                </div>

                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Type</label>
                  <input
                    type="text"
                    value={template.type}
                    readOnly
                    className="w-full px-2.5 py-1.5 text-sm border border-secondary-200 rounded-md bg-secondary-50 text-secondary-500 capitalize"
                  />
                </div>

                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Description</label>
                  <textarea
                    value={description}
                    onChange={(e) => {
                      setDescription(e.target.value);
                      markDirty();
                    }}
                    rows={3}
                    className="w-full px-2.5 py-1.5 text-sm border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500 resize-none"
                    placeholder="Template description..."
                  />
                </div>
              </div>
            </section>

            {/* Page Settings */}
            <section>
              <h3 className="flex items-center gap-2 text-xs font-semibold text-secondary-500 uppercase tracking-wider mb-3">
                <FileText className="w-3.5 h-3.5" />
                Page Settings
              </h3>

              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="block text-xs font-medium text-secondary-600 mb-1">Size</label>
                    <select
                      value={pageSize}
                      onChange={(e) => {
                        setPageSize(e.target.value);
                        markDirty();
                      }}
                      className="w-full px-2 py-1.5 text-sm border border-secondary-200 rounded-md bg-white focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                    >
                      <option value="A4">A4</option>
                      <option value="Letter">Letter</option>
                      <option value="Legal">Legal</option>
                    </select>
                  </div>
                  <div>
                    <label className="block text-xs font-medium text-secondary-600 mb-1">Orientation</label>
                    <select
                      value={pageOrientation}
                      onChange={(e) => {
                        setPageOrientation(e.target.value);
                        markDirty();
                      }}
                      className="w-full px-2 py-1.5 text-sm border border-secondary-200 rounded-md bg-white focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                    >
                      <option value="portrait">Portrait</option>
                      <option value="landscape">Landscape</option>
                    </select>
                  </div>
                </div>

                {/* Margins */}
                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Margins</label>
                  <div className="grid grid-cols-2 gap-2">
                    <div>
                      <label className="block text-[10px] text-secondary-400 mb-0.5">Top</label>
                      <input
                        type="text"
                        value={marginTop}
                        onChange={(e) => {
                          setMarginTop(e.target.value);
                          markDirty();
                        }}
                        className="w-full px-2 py-1 text-xs border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                    <div>
                      <label className="block text-[10px] text-secondary-400 mb-0.5">Bottom</label>
                      <input
                        type="text"
                        value={marginBottom}
                        onChange={(e) => {
                          setMarginBottom(e.target.value);
                          markDirty();
                        }}
                        className="w-full px-2 py-1 text-xs border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                    <div>
                      <label className="block text-[10px] text-secondary-400 mb-0.5">Left</label>
                      <input
                        type="text"
                        value={marginLeft}
                        onChange={(e) => {
                          setMarginLeft(e.target.value);
                          markDirty();
                        }}
                        className="w-full px-2 py-1 text-xs border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                    <div>
                      <label className="block text-[10px] text-secondary-400 mb-0.5">Right</label>
                      <input
                        type="text"
                        value={marginRight}
                        onChange={(e) => {
                          setMarginRight(e.target.value);
                          markDirty();
                        }}
                        className="w-full px-2 py-1 text-xs border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </section>

            {/* Theme / Branding */}
            <section>
              <h3 className="flex items-center gap-2 text-xs font-semibold text-secondary-500 uppercase tracking-wider mb-3">
                <Palette className="w-3.5 h-3.5" />
                Theme / Branding
              </h3>

              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="block text-xs font-medium text-secondary-600 mb-1">Primary Color</label>
                    <div className="flex items-center gap-1.5">
                      <input
                        type="color"
                        value={primaryColor}
                        onChange={(e) => {
                          setPrimaryColor(e.target.value);
                          markDirty();
                        }}
                        className="w-8 h-8 rounded border border-secondary-200 cursor-pointer"
                      />
                      <input
                        type="text"
                        value={primaryColor}
                        onChange={(e) => {
                          setPrimaryColor(e.target.value);
                          markDirty();
                        }}
                        className="flex-1 px-2 py-1 text-xs font-mono border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                  </div>
                  <div>
                    <label className="block text-xs font-medium text-secondary-600 mb-1">Secondary Color</label>
                    <div className="flex items-center gap-1.5">
                      <input
                        type="color"
                        value={secondaryColor}
                        onChange={(e) => {
                          setSecondaryColor(e.target.value);
                          markDirty();
                        }}
                        className="w-8 h-8 rounded border border-secondary-200 cursor-pointer"
                      />
                      <input
                        type="text"
                        value={secondaryColor}
                        onChange={(e) => {
                          setSecondaryColor(e.target.value);
                          markDirty();
                        }}
                        className="flex-1 px-2 py-1 text-xs font-mono border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500"
                      />
                    </div>
                  </div>
                </div>

                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Font Family</label>
                  <select
                    value={fontFamily}
                    onChange={(e) => {
                      setFontFamily(e.target.value);
                      markDirty();
                    }}
                    className="w-full px-2 py-1.5 text-sm border border-secondary-200 rounded-md bg-white focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                  >
                    <option value="Inter, sans-serif">Inter</option>
                    <option value="Arial, sans-serif">Arial</option>
                    <option value="Helvetica, sans-serif">Helvetica</option>
                    <option value="Georgia, serif">Georgia</option>
                    <option value="'Times New Roman', serif">Times New Roman</option>
                    <option value="'Courier New', monospace">Courier New</option>
                    <option value="Roboto, sans-serif">Roboto</option>
                  </select>
                </div>

                <div>
                  <label className="block text-xs font-medium text-secondary-600 mb-1">Footer Text</label>
                  <input
                    type="text"
                    value={footerText}
                    onChange={(e) => {
                      setFooterText(e.target.value);
                      markDirty();
                    }}
                    className="w-full px-2.5 py-1.5 text-sm border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
                    placeholder="e.g. Thank you for your business"
                  />
                </div>
              </div>
            </section>

            {/* Advanced Config */}
            <section>
              <h3 className="text-xs font-semibold text-secondary-500 uppercase tracking-wider mb-2">
                Advanced Config (JSON)
              </h3>
              <textarea
                value={configJson}
                onChange={(e) => {
                  setConfigJson(e.target.value);
                  markDirty();
                }}
                rows={4}
                className="w-full px-2.5 py-1.5 font-mono text-xs border border-secondary-200 rounded-md focus:outline-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500 resize-none"
                spellCheck={false}
              />
            </section>

            {/* Version Info */}
            <section className="pt-3 border-t border-secondary-200">
              <div className="text-xs text-secondary-500 space-y-1">
                <p>
                  <span className="font-medium">Version:</span> {template.version}
                </p>
                <p>
                  <span className="font-medium">Last updated:</span> {formatDateTime(template.updated_at)}
                </p>
                <p>
                  <span className="font-medium">Created:</span> {formatDate(template.created_at)}
                </p>
              </div>
            </section>
          </div>
        </div>
      </div>

      {/* Version History Modal */}
      <VersionHistoryModal
        isOpen={showVersionHistory}
        onClose={() => setShowVersionHistory(false)}
        versions={versions}
        currentVersion={template.version}
        onRestore={handleRestoreVersion}
        isRestoring={isRestoring}
      />
    </div>
  );
}

export default function TemplateBuilderPage() {
  return (
    <ProtectedPage module="templates" title="Template Builder">
      <TemplateBuilderContent />
    </ProtectedPage>
  );
}
