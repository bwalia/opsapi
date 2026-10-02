'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { BookOpen, ChevronDown, ChevronRight, ExternalLink, Plus, RefreshCw, Search, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, ConfirmDialog, Input, Modal, Select, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { SHOP_MODULE, ShopLoading } from '@/components/shop/shared';
import { cn, extractApiError, formatDateTime } from '@/lib/utils';
import { humanize } from '@/lib/shop';
import { SHOP_KNOWLEDGE_SOURCES, type ShopKnowledgeDoc, type ShopKnowledgeInput, type ShopKnowledgeSourceType } from '@/types/shop';

const PAGE = 200;

type Doc = ShopKnowledgeDoc;

const SOURCE_LABEL: Record<ShopKnowledgeSourceType, string> = {
  product: 'Products',
  cms_post: 'Blog posts',
  faq: 'FAQs',
  manual: 'Manuals',
  url: 'Web pages',
};

function KnowledgeContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [source, setSource] = useState<ShopKnowledgeSourceType | ''>('');
  const [rows, setRows] = useState<Doc[] | null>(null);
  const [total, setTotal] = useState(0);
  const [limit, setLimit] = useState(PAGE);
  const [version, setVersion] = useState(0);
  const [search, setSearch] = useState('');
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [addOpen, setAddOpen] = useState(false);
  const [toDelete, setToDelete] = useState<Doc | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [reindexing, setReindexing] = useState<string | null>(null);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getKnowledge({ source_type: source, limit, offset: 0 })
      .then((r) => {
        if (!active) return;
        setRows(r.data);
        setTotal(r.meta.total);
      })
      .catch((err) => {
        if (!active) return;
        setRows([]);
        toast.error(extractApiError(err, 'Failed to load knowledge'));
      });
    return () => {
      active = false;
    };
  }, [source, limit, version]);

  const docs = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows ?? [])
      .filter((d) => !q || d.title.toLowerCase().includes(q) || d.source_ref.toLowerCase().includes(q) || (d.preview ?? '').toLowerCase().includes(q))
      .sort((a, b) => a.source_type.localeCompare(b.source_type) || a.title.localeCompare(b.title));
  }, [rows, search]);

  const reindex = async (sources: ('products' | 'cms_posts')[]) => {
    const label = sources.join(',');
    setReindexing(label);
    try {
      const res = await shopService.reindexKnowledge(sources);
      const parts = Object.entries(res ?? {})
        .filter(([, v]) => typeof v === 'number')
        .map(([k, v]) => `${humanize(k)}: ${v}`);
      toast.success(`Reindexed${parts.length ? ` — ${parts.join(', ')}` : ''}`);
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Reindex failed'));
    } finally {
      setReindexing(null);
    }
  };

  const confirmDelete = async () => {
    if (!toDelete) return;
    setDeleting(true);
    try {
      await shopService.deleteKnowledge(toDelete.source_ref, toDelete.source_type);
      toast.success('Document removed from the knowledge base');
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to delete'));
    } finally {
      setDeleting(false);
      setToDelete(null);
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Knowledge base"
        description="What the AI sales assistant can search: products, blog posts, FAQs, manuals and web pages"
        icon={<BookOpen className="h-5 w-5" />}
        actions={
          <>
            {canUpdate(SHOP_MODULE) && (
              <>
                <Button variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} isLoading={reindexing === 'products'} disabled={!!reindexing} onClick={() => reindex(['products'])}>
                  Reindex products
                </Button>
                <Button variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} isLoading={reindexing === 'cms_posts'} disabled={!!reindexing} onClick={() => reindex(['cms_posts'])}>
                  Reindex blog
                </Button>
              </>
            )}
            {canCreate(SHOP_MODULE) && (
              <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setAddOpen(true)}>
                Add document
              </Button>
            )}
          </>
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Filter loaded documents…" aria-label="Filter documents" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <div className="flex flex-wrap gap-1" role="group" aria-label="Source type">
            {(['', ...SHOP_KNOWLEDGE_SOURCES] as const).map((s) => (
              <button
                key={s || 'all'}
                type="button"
                aria-pressed={source === s}
                onClick={() => {
                  setSource(s);
                  setLimit(PAGE);
                  setRows(null);
                }}
                className={cn(
                  'rounded-full px-3 py-1.5 text-sm font-medium transition-colors',
                  source === s ? 'bg-primary-500 text-white' : 'bg-secondary-100 text-secondary-600 hover:bg-secondary-200'
                )}
              >
                {s ? SOURCE_LABEL[s] : 'All'}
              </button>
            ))}
          </div>
        </div>
      </Card>

      {rows === null ? (
        <ShopLoading label="Loading knowledge…" />
      ) : docs.length === 0 ? (
        <Card>
          <p className="py-8 text-center text-sm text-secondary-500">
            No documents{source ? ` of type ${SOURCE_LABEL[source as ShopKnowledgeSourceType]}` : ''}. Reindex products/blog or add an FAQ.
          </p>
        </Card>
      ) : (
        <div className="space-y-2">
          <p className="text-sm text-secondary-500">
            {docs.length} of {total} documents loaded
          </p>
          {docs.map((d) => {
            const k = `${d.source_type}:${d.source_ref}`;
            const open = expanded[k];
            return (
              <div key={k} className="rounded-xl border border-secondary-200 bg-surface">
                <div className="flex items-center gap-3 px-4 py-3">
                  <button
                    type="button"
                    onClick={() => setExpanded((e) => ({ ...e, [k]: !e[k] }))}
                    className="flex min-w-0 flex-1 items-center gap-3 text-left"
                    aria-expanded={open}
                  >
                    {open ? <ChevronDown className="h-4 w-4 shrink-0 text-secondary-400" /> : <ChevronRight className="h-4 w-4 shrink-0 text-secondary-400" />}
                    <Badge size="sm" variant={d.source_type === 'product' ? 'info' : d.source_type === 'cms_post' ? 'success' : 'default'}>
                      {humanize(d.source_type)}
                    </Badge>
                    <span className="min-w-0">
                      <span className="block truncate font-medium text-secondary-900">{d.title}</span>
                      <span className="block truncate font-mono text-xs text-secondary-400">{d.source_ref}</span>
                    </span>
                  </button>
                  <span className="hidden shrink-0 text-xs text-secondary-500 sm:inline">
                    {d.chunks} chunk{d.chunks === 1 ? '' : 's'} · {d.embedded_chunks} embedded
                  </span>
                  {d.url && (
                    <a href={d.url} target="_blank" rel="noopener noreferrer" className="rounded-lg p-1.5 text-secondary-500 hover:bg-secondary-100" aria-label="Open source URL">
                      <ExternalLink className="h-4 w-4" />
                    </a>
                  )}
                  {canDelete(SHOP_MODULE) && (
                    <button type="button" onClick={() => setToDelete(d)} className="rounded-lg p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-500" aria-label={`Delete ${d.title}`}>
                      <Trash2 className="h-4 w-4" />
                    </button>
                  )}
                </div>
                {open && (
                  <div className="space-y-1 border-t border-secondary-100 px-4 py-3">
                    <p className="text-xs font-medium text-secondary-500">
                      {d.characters ?? 0} characters · updated {d.updated_at ? formatDateTime(d.updated_at) : '—'}
                      {d.embedded_chunks < d.chunks && (
                        <span className="ml-2 text-warning-600">
                          {d.chunks - d.embedded_chunks} chunk{d.chunks - d.embedded_chunks === 1 ? '' : 's'} without embedding (full-text only)
                        </span>
                      )}
                    </p>
                    <p className="whitespace-pre-wrap rounded-lg bg-secondary-50 p-3 text-sm text-secondary-700">{d.preview || '—'}{(d.characters ?? 0) > (d.preview?.length ?? 0) ? '…' : ''}</p>
                  </div>
                )}
              </div>
            );
          })}
          {(rows?.length ?? 0) < total && (
            <div className="flex justify-center pt-2">
              <Button variant="ghost" onClick={() => setLimit((l) => l + PAGE)}>
                Load more ({total - (rows?.length ?? 0)} remaining)
              </Button>
            </div>
          )}
        </div>
      )}

      <AddDocModal open={addOpen} onClose={() => setAddOpen(false)} onAdded={reload} />

      <ConfirmDialog
        isOpen={!!toDelete}
        onClose={() => setToDelete(null)}
        onConfirm={confirmDelete}
        title="Remove document"
        message={`Remove "${toDelete?.title}" and its ${toDelete?.chunks ?? 0} chunk(s) from the assistant's knowledge? Product and blog documents come back on the next reindex.`}
        confirmText="Remove"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

function AddDocModal({ open, onClose, onAdded }: { open: boolean; onClose: () => void; onAdded: () => void }) {
  const empty: ShopKnowledgeInput = { source_type: 'faq', title: '', url: '', content: '' };
  const [form, setForm] = useState<ShopKnowledgeInput>(empty);
  const [saving, setSaving] = useState(false);

  const close = () => {
    setForm(empty);
    onClose();
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim() || !form.content.trim()) {
      toast.error('Title and content are required');
      return;
    }
    if (form.source_type === 'url' && !/^https?:\/\//i.test(form.url?.trim() ?? '')) {
      toast.error('A valid URL is required for web pages');
      return;
    }
    setSaving(true);
    try {
      await shopService.addKnowledge({
        source_type: form.source_type,
        title: form.title.trim(),
        url: form.url?.trim() || undefined,
        content: form.content.trim(),
      });
      toast.success('Document added and indexed');
      onAdded();
      close();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to add document'));
    } finally {
      setSaving(false);
    }
  };

  const chunksEstimate = Math.max(1, Math.ceil(form.content.length / 700));

  return (
    <Modal isOpen={open} onClose={close} title="Add knowledge document" description="Split into ~800-character chunks and embedded for the assistant's search" size="2xl">
      {open && (
        <form onSubmit={submit} className="space-y-4">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <Select label="Type" id="kn-type" value={form.source_type} onChange={(e) => setForm({ ...form, source_type: e.target.value as ShopKnowledgeInput['source_type'] })}>
              <option value="faq">FAQ</option>
              <option value="manual">Manual / doc</option>
              <option value="url">Web page</option>
            </Select>
            <div className="sm:col-span-2">
              <Input label="Title *" id="kn-title" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} autoFocus />
            </div>
          </div>
          <Input
            label={form.source_type === 'url' ? 'URL *' : 'URL (optional, cited by the assistant)'}
            id="kn-url"
            value={form.url ?? ''}
            onChange={(e) => setForm({ ...form, url: e.target.value })}
            placeholder="https://…"
          />
          <Textarea
            label="Content *"
            id="kn-content"
            rows={12}
            value={form.content}
            onChange={(e) => setForm({ ...form, content: e.target.value })}
            placeholder={form.source_type === 'faq' ? 'Q: What warranty do workstations have?\nA: …' : 'Paste the document text…'}
            helperText={form.content ? `${form.content.length.toLocaleString()} characters · ~${chunksEstimate} chunk${chunksEstimate === 1 ? '' : 's'}` : undefined}
          />
          <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
            <Button type="button" variant="ghost" onClick={close}>Cancel</Button>
            <Button type="submit" isLoading={saving}>Add &amp; index</Button>
          </div>
        </form>
      )}
    </Modal>
  );
}

export default function ShopKnowledgePage() {
  return (
    <ProtectedPage module="shop" title="Shop Knowledge">
      <KnowledgeContent />
    </ProtectedPage>
  );
}
