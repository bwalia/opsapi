'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Plus, Edit, Trash2, Loader2, Star, Eye, Code2, LayoutTemplate, Globe } from 'lucide-react';
import { usePermissions } from '@/contexts/PermissionsContext';
import { Button, Input, Select, Card, Badge, Modal, ConfirmDialog } from '@/components/ui';
import {
  renderTemplatesService,
  renderTemplateTypeLabel,
  type RenderTemplate,
  type RenderTemplateType,
} from '@/services/render-templates.service';
import toast from 'react-hot-toast';

const TYPE_FILTERS: { value: '' | RenderTemplateType; label: string }[] = [
  { value: '', label: 'All types' },
  { value: 'cms_page', label: 'Page layouts' },
  { value: 'domain_wslproxy', label: 'Domain (WSL Proxy JSON)' },
];

const SAMPLE_CONTENT: Record<RenderTemplateType, string> = {
  cms_page:
    '<article class="page">\n  <h1>{{title}}</h1>\n  <div class="excerpt">{{excerpt}}</div>\n  <main>{{content}}</main>\n</article>',
  domain_wslproxy:
    '{\n  "id": "host:{{server_name}}",\n  "root": "{{root}}",\n  "ssl_enabled": {{ssl_enabled}}\n}',
};
const SAMPLE_DATA: Record<RenderTemplateType, string> = {
  cms_page: '{\n  "title": "About Us",\n  "excerpt": "Who we are",\n  "content": "<p>Body…</p>"\n}',
  domain_wslproxy: '{\n  "server_name": "acme.com",\n  "root": "/var/www",\n  "ssl_enabled": true\n}',
};

interface EditorState {
  uuid?: string;
  name: string;
  template_type: RenderTemplateType;
  content: string;
  sample_data: string;
  description: string;
  is_default: boolean;
}

const emptyEditor = (type: RenderTemplateType = 'cms_page'): EditorState => ({
  name: '',
  template_type: type,
  content: SAMPLE_CONTENT[type],
  sample_data: SAMPLE_DATA[type],
  description: '',
  is_default: false,
});

export default function TemplatesTab() {
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('templates', 'update');
  const canDelete = hasPermission('templates', 'delete');

  const [templates, setTemplates] = useState<RenderTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [typeFilter, setTypeFilter] = useState<'' | RenderTemplateType>('');

  const [editor, setEditor] = useState<EditorState | null>(null);
  const [saving, setSaving] = useState(false);
  const [preview, setPreview] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<RenderTemplate | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setTemplates(await renderTemplatesService.list(typeFilter || undefined));
    } catch {
      toast.error('Failed to load templates');
    } finally {
      setLoading(false);
    }
  }, [typeFilter]);

  useEffect(() => {
    load();
  }, [load]);

  const openNew = () => {
    setPreview(null);
    setEditor(emptyEditor((typeFilter as RenderTemplateType) || 'cms_page'));
  };
  const openEdit = (t: RenderTemplate) => {
    setPreview(null);
    setEditor({
      uuid: t.uuid,
      name: t.name,
      template_type: t.template_type,
      content: t.content ?? '',
      sample_data: t.sample_data ?? '',
      description: t.description ?? '',
      is_default: t.is_default,
    });
  };

  const runPreview = async () => {
    if (!editor) return;
    setPreviewing(true);
    try {
      let data: Record<string, unknown> | undefined;
      if (editor.sample_data.trim()) {
        try {
          data = JSON.parse(editor.sample_data);
        } catch {
          toast.error('Sample data is not valid JSON');
          setPreviewing(false);
          return;
        }
      }
      const res = await renderTemplatesService.previewRaw(editor.content, data);
      setPreview(res.rendered);
    } catch {
      toast.error('Preview failed');
    } finally {
      setPreviewing(false);
    }
  };

  const save = async () => {
    if (!editor) return;
    if (!editor.name.trim()) {
      toast.error('Name is required');
      return;
    }
    if (editor.sample_data.trim()) {
      try {
        JSON.parse(editor.sample_data);
      } catch {
        toast.error('Sample data is not valid JSON');
        return;
      }
    }
    setSaving(true);
    try {
      const payload = {
        name: editor.name,
        template_type: editor.template_type,
        content: editor.content,
        sample_data: editor.sample_data,
        description: editor.description,
        is_default: editor.is_default,
      };
      if (editor.uuid) {
        await renderTemplatesService.update(editor.uuid, payload);
        toast.success('Template updated');
      } else {
        await renderTemplatesService.create(payload);
        toast.success('Template created');
      }
      setEditor(null);
      load();
    } catch {
      toast.error('Failed to save template');
    } finally {
      setSaving(false);
    }
  };

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await renderTemplatesService.remove(confirmDelete.uuid);
      toast.success('Template deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete template');
    } finally {
      setDeleting(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-sm text-secondary-500">
            Define a reusable layout/format with <code className="rounded bg-secondary-100 px-1">{'{{slots}}'}</code>{' '}
            once — then pick it in the Page editor or the Domains sync.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-48">
            <Select value={typeFilter} onChange={(e) => setTypeFilter(e.target.value as '' | RenderTemplateType)}>
              {TYPE_FILTERS.map((o) => (
                <option key={o.value || 'all'} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
          </div>
          {canWrite && (
            <Button onClick={openNew}>
              <Plus className="mr-1 h-4 w-4" /> New Template
            </Button>
          )}
        </div>
      </div>

      {loading ? (
        <div className="flex justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : templates.length === 0 ? (
        <Card>
          <div className="flex flex-col items-center gap-2 py-10 text-center">
            <LayoutTemplate className="h-8 w-8 text-secondary-300" />
            <p className="text-secondary-600">No templates yet.</p>
            <p className="text-sm text-secondary-400">
              Create a page layout or a domain JSON format to reuse across your content.
            </p>
          </div>
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          {templates.map((t) => (
            <Card key={t.uuid} className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  {t.template_type === 'cms_page' ? (
                    <LayoutTemplate className="h-4 w-4 shrink-0 text-primary-500" />
                  ) : (
                    <Globe className="h-4 w-4 shrink-0 text-primary-500" />
                  )}
                  <span className="truncate font-medium text-secondary-900">{t.name}</span>
                  {t.is_default && (
                    <Badge variant="success" size="sm">
                      <Star className="mr-0.5 h-3 w-3" /> default
                    </Badge>
                  )}
                </div>
                <div className="mt-1 flex flex-wrap items-center gap-1.5">
                  <Badge variant="secondary" size="sm">
                    {renderTemplateTypeLabel(t.template_type)}
                  </Badge>
                  <span className="truncate text-xs text-secondary-400">/{t.slug}</span>
                </div>
                {t.placeholders && t.placeholders.length > 0 && (
                  <div className="mt-2 flex flex-wrap gap-1">
                    {t.placeholders.slice(0, 8).map((p) => (
                      <code key={p} className="rounded bg-secondary-100 px-1.5 py-0.5 text-[11px] text-secondary-600">
                        {`{{${p}}}`}
                      </code>
                    ))}
                  </div>
                )}
              </div>
              <div className="flex shrink-0 items-center gap-1">
                {canWrite && (
                  <button onClick={() => openEdit(t)} className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-primary-600" aria-label="Edit">
                    <Edit className="h-4 w-4" />
                  </button>
                )}
                {canDelete && (
                  <button onClick={() => setConfirmDelete(t)} className="rounded p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600" aria-label="Delete">
                    <Trash2 className="h-4 w-4" />
                  </button>
                )}
              </div>
            </Card>
          ))}
        </div>
      )}

      {/* Editor modal */}
      <Modal
        isOpen={Boolean(editor)}
        onClose={() => setEditor(null)}
        title={editor?.uuid ? 'Edit template' : 'New template'}
        size="2xl"
      >
        {editor && (
          <div className="space-y-4">
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <Input label="Name" value={editor.name} onChange={(e) => setEditor({ ...editor, name: e.target.value })} placeholder="Landing Layout" />
              <Select
                label="Type"
                value={editor.template_type}
                onChange={(e) => {
                  const nt = e.target.value as RenderTemplateType;
                  // Swap the starter samples only when the fields are still the defaults/empty.
                  setEditor({
                    ...editor,
                    template_type: nt,
                    content: editor.content && editor.content !== SAMPLE_CONTENT[editor.template_type] ? editor.content : SAMPLE_CONTENT[nt],
                    sample_data: editor.sample_data && editor.sample_data !== SAMPLE_DATA[editor.template_type] ? editor.sample_data : SAMPLE_DATA[nt],
                  });
                }}
                disabled={Boolean(editor.uuid)}
              >
                <option value="cms_page">Page layout</option>
                <option value="domain_wslproxy">Domain (WSL Proxy JSON)</option>
              </Select>
            </div>

            <div>
              <label className="mb-1.5 flex items-center gap-1.5 text-sm font-medium text-secondary-700">
                <Code2 className="h-4 w-4" /> Template content — use{' '}
                <code className="rounded bg-secondary-100 px-1">{'{{slot}}'}</code> placeholders
              </label>
              <textarea
                value={editor.content}
                onChange={(e) => setEditor({ ...editor, content: e.target.value })}
                spellCheck={false}
                rows={9}
                className="block w-full resize-y rounded-lg border border-secondary-300 bg-surface p-3 font-mono text-[13px] leading-relaxed text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              />
            </div>

            <div>
              <label className="mb-1.5 block text-sm font-medium text-secondary-700">
                Sample data (JSON) — used for preview &amp; as a placeholder guide
              </label>
              <textarea
                value={editor.sample_data}
                onChange={(e) => setEditor({ ...editor, sample_data: e.target.value })}
                spellCheck={false}
                rows={5}
                className="block w-full resize-y rounded-lg border border-secondary-300 bg-surface p-3 font-mono text-[13px] leading-relaxed text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              />
            </div>

            <Input label="Description (optional)" value={editor.description} onChange={(e) => setEditor({ ...editor, description: e.target.value })} />

            <label className="flex cursor-pointer items-center gap-2 text-sm text-secondary-700">
              <input
                type="checkbox"
                checked={editor.is_default}
                onChange={(e) => setEditor({ ...editor, is_default: e.target.checked })}
                className="h-4 w-4 rounded border-secondary-300 text-primary-600"
              />
              Default template for this type
            </label>

            {preview !== null && (
              <div>
                <div className="mb-1 text-sm font-medium text-secondary-700">Preview (rendered with sample data)</div>
                <pre className="max-h-48 overflow-auto rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-[12px] leading-relaxed text-secondary-800 whitespace-pre-wrap wrap-break-word">
                  {preview}
                </pre>
              </div>
            )}

            <div className="flex items-center justify-between pt-1">
              <Button variant="outline" onClick={runPreview} disabled={previewing}>
                {previewing ? <Loader2 className="mr-1 h-4 w-4 animate-spin" /> : <Eye className="mr-1 h-4 w-4" />}
                Preview
              </Button>
              <div className="flex gap-2">
                <Button variant="outline" onClick={() => setEditor(null)}>
                  Cancel
                </Button>
                <Button onClick={save} disabled={saving}>
                  {saving && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}
                  {editor.uuid ? 'Save' : 'Create'}
                </Button>
              </div>
            </div>
          </div>
        )}
      </Modal>

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete template"
        message={`Delete "${confirmDelete?.name}"? Pages/domains using it fall back to the default or raw layout.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}
