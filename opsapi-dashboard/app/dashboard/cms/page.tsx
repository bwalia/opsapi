'use client';

import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  FileText,
  Plus,
  Search,
  Edit,
  Trash2,
  Loader2,
  Star,
  Eye,
  FolderTree,
  Tag as TagIcon,
  Newspaper,
  Files,
  Webhook,
  Copy,
  Check,
} from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  Table,
  Badge,
  Button,
  Input,
  Select,
  Pagination,
  Modal,
  ConfirmDialog,
  Card,
} from '@/components/ui';
import {
  cmsService,
  WEBHOOK_EVENTS,
  type CmsPost,
  type CmsPage,
  type CmsCategory,
  type CmsTag,
  type CmsWebhook,
  type PostStatus,
} from '@/services/cms.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const PER_PAGE = 20;
type TabKey = 'posts' | 'pages' | 'categories' | 'tags' | 'webhooks';

const TABS: { key: TabKey; label: string; icon: React.ReactNode }[] = [
  { key: 'posts', label: 'Blog Posts', icon: <Newspaper className="h-4 w-4" /> },
  { key: 'pages', label: 'Pages', icon: <Files className="h-4 w-4" /> },
  { key: 'categories', label: 'Categories', icon: <FolderTree className="h-4 w-4" /> },
  { key: 'tags', label: 'Tags', icon: <TagIcon className="h-4 w-4" /> },
  { key: 'webhooks', label: 'Webhooks', icon: <Webhook className="h-4 w-4" /> },
];

function statusVariant(status: string): 'success' | 'warning' | 'secondary' | 'info' | 'default' {
  switch (status) {
    case 'published':
      return 'success';
    case 'scheduled':
      return 'info';
    case 'draft':
      return 'warning';
    case 'archived':
      return 'secondary';
    default:
      return 'default';
  }
}

// ============================================================
// Posts tab
// ============================================================
function PostsTab() {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('cms', 'update');
  const canDelete = hasPermission('cms', 'delete');

  const [posts, setPosts] = useState<CmsPost[]>([]);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const [totalPages, setTotalPages] = useState(1);
  const [status, setStatus] = useState<PostStatus | ''>('');
  const [search, setSearch] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<CmsPost | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await cmsService.getPosts({ page, perPage: PER_PAGE, status, search });
      setPosts(res.data);
      setTotal(res.meta.total);
      setTotalPages(res.meta.totalPages || 1);
    } catch {
      toast.error('Failed to load posts');
    } finally {
      setLoading(false);
    }
  }, [page, status, search]);

  useEffect(() => {
    const t = setTimeout(load, search ? 300 : 0);
    return () => clearTimeout(t);
  }, [load, search]);

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await cmsService.deletePost(confirmDelete.uuid);
      toast.success('Post deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete post');
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<CmsPost>[] = [
    {
      key: 'title',
      header: 'Title',
      render: (p) => (
        <div className="min-w-0">
          <div className="flex items-center gap-1.5 font-medium text-secondary-900">
            {p.is_featured && <Star className="h-3.5 w-3.5 shrink-0 text-amber-500" />}
            <span className="truncate">{p.title}</span>
          </div>
          <div className="truncate text-xs text-secondary-400">/{p.slug}</div>
        </div>
      ),
    },
    {
      key: 'category',
      header: 'Category',
      render: (p) => (p.category ? <Badge variant="secondary" size="sm">{p.category.name}</Badge> : <span className="text-secondary-300">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (p) => (
        <Badge variant={statusVariant(p.status)} size="sm">
          {p.status}
        </Badge>
      ),
    },
    {
      key: 'view_count',
      header: 'Views',
      render: (p) => (
        <span className="inline-flex items-center gap-1 text-sm text-secondary-500">
          <Eye className="h-3.5 w-3.5" /> {p.view_count ?? 0}
        </span>
      ),
    },
    {
      key: 'published_at',
      header: 'Date',
      render: (p) => (
        <span className="text-sm text-secondary-500">
          {p.published_at ? formatDate(p.published_at) : formatDate(p.created_at || '')}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: '90px',
      render: (p) => (
        <div className="flex items-center justify-end gap-1">
          {canWrite && (
            <button
              onClick={() => router.push(`/dashboard/cms/posts/${p.uuid}`)}
              className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-primary-600"
              aria-label="Edit"
            >
              <Edit className="h-4 w-4" />
            </button>
          )}
          {canDelete && (
            <button
              onClick={() => setConfirmDelete(p)}
              className="rounded p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600"
              aria-label="Delete"
            >
              <Trash2 className="h-4 w-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <div className="w-full sm:w-72">
            <Input
              leftIcon={<Search className="h-4 w-4" />}
              value={search}
              onChange={(e) => {
                setPage(1);
                setSearch(e.target.value);
              }}
              placeholder="Search posts…"
            />
          </div>
          <div className="w-full sm:w-48">
            <Select
              value={status}
              onChange={(e) => {
                setPage(1);
                setStatus(e.target.value as PostStatus | '');
              }}
            >
              <option value="">All statuses</option>
              <option value="draft">Draft</option>
              <option value="published">Published</option>
              <option value="scheduled">Scheduled</option>
              <option value="archived">Archived</option>
            </Select>
          </div>
        </div>
        {canWrite && (
          <Button onClick={() => router.push('/dashboard/cms/posts/new')}>
            <Plus className="mr-1 h-4 w-4" /> New Post
          </Button>
        )}
      </div>

      <Table
        columns={columns}
        data={posts}
        keyExtractor={(p) => p.uuid}
        isLoading={loading}
        emptyMessage="No posts yet. Create your first article."
      />

      {totalPages > 1 && (
        <Pagination
          currentPage={page}
          totalPages={totalPages}
          totalItems={total}
          perPage={PER_PAGE}
          onPageChange={setPage}
        />
      )}

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete post"
        message={`Delete "${confirmDelete?.title}"? This can be recovered by support but will disappear from your site.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// ============================================================
// Pages tab
// ============================================================
function PagesTab() {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('cms', 'update');
  const canDelete = hasPermission('cms', 'delete');

  const [pages, setPages] = useState<CmsPage[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<CmsPage | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setPages(await cmsService.getPages({ search }));
    } catch {
      toast.error('Failed to load pages');
    } finally {
      setLoading(false);
    }
  }, [search]);

  useEffect(() => {
    const t = setTimeout(load, search ? 300 : 0);
    return () => clearTimeout(t);
  }, [load, search]);

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await cmsService.deletePage(confirmDelete.uuid);
      toast.success('Page deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete page');
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<CmsPage>[] = [
    {
      key: 'title',
      header: 'Title',
      render: (p) => (
        <div className="min-w-0">
          <div className="truncate font-medium text-secondary-900">{p.title}</div>
          <div className="truncate text-xs text-secondary-400">/{p.slug}</div>
        </div>
      ),
    },
    {
      key: 'show_in_nav',
      header: 'In nav',
      render: (p) => (p.show_in_nav ? <Badge variant="info" size="sm">Nav</Badge> : <span className="text-secondary-300">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (p) => (
        <Badge variant={statusVariant(p.status)} size="sm">
          {p.status}
        </Badge>
      ),
    },
    {
      key: 'updated_at',
      header: 'Updated',
      render: (p) => <span className="text-sm text-secondary-500">{formatDate(p.updated_at || '')}</span>,
    },
    {
      key: 'actions',
      header: '',
      width: '90px',
      render: (p) => (
        <div className="flex items-center justify-end gap-1">
          {canWrite && (
            <button
              onClick={() => router.push(`/dashboard/cms/pages/${p.uuid}`)}
              className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-primary-600"
              aria-label="Edit"
            >
              <Edit className="h-4 w-4" />
            </button>
          )}
          {canDelete && (
            <button
              onClick={() => setConfirmDelete(p)}
              className="rounded p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600"
              aria-label="Delete"
            >
              <Trash2 className="h-4 w-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="w-full sm:w-72">
          <Input
            leftIcon={<Search className="h-4 w-4" />}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search pages…"
          />
        </div>
        {canWrite && (
          <Button onClick={() => router.push('/dashboard/cms/pages/new')}>
            <Plus className="mr-1 h-4 w-4" /> New Page
          </Button>
        )}
      </div>

      <Table
        columns={columns}
        data={pages}
        keyExtractor={(p) => p.uuid}
        isLoading={loading}
        emptyMessage="No pages yet. Create your first page (About, Contact, …)."
      />

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete page"
        message={`Delete "${confirmDelete?.title}"?`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// ============================================================
// Categories tab
// ============================================================
function CategoriesTab() {
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('cms', 'update');
  const canDelete = hasPermission('cms', 'delete');

  const [cats, setCats] = useState<CmsCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<CmsCategory | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<CmsCategory | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setCats(await cmsService.getCategories());
    } catch {
      toast.error('Failed to load categories');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openNew = () => {
    setEditing(null);
    setName('');
    setDescription('');
    setShowForm(true);
  };
  const openEdit = (c: CmsCategory) => {
    setEditing(c);
    setName(c.name);
    setDescription(c.description ?? '');
    setShowForm(true);
  };

  const save = async () => {
    if (!name.trim()) {
      toast.error('Name is required');
      return;
    }
    setSaving(true);
    try {
      if (editing) {
        await cmsService.updateCategory(editing.uuid, { name, description });
        toast.success('Category updated');
      } else {
        await cmsService.createCategory({ name, description });
        toast.success('Category created');
      }
      setShowForm(false);
      load();
    } catch {
      toast.error('Failed to save category');
    } finally {
      setSaving(false);
    }
  };

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await cmsService.deleteCategory(confirmDelete.uuid);
      toast.success('Category deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete category');
    } finally {
      setDeleting(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-sm text-secondary-500">Group blog posts into browsable categories.</p>
        {canWrite && (
          <Button onClick={openNew}>
            <Plus className="mr-1 h-4 w-4" /> New Category
          </Button>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : cats.length === 0 ? (
        <Card>
          <p className="py-8 text-center text-secondary-500">No categories yet.</p>
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {cats.map((c) => (
            <Card key={c.uuid} className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="truncate font-medium text-secondary-900">{c.name}</div>
                <div className="truncate text-xs text-secondary-400">/{c.slug}</div>
                {c.description && <p className="mt-1 line-clamp-2 text-sm text-secondary-500">{c.description}</p>}
                <Badge variant="secondary" size="sm" className="mt-2">
                  {c.post_count ?? 0} posts
                </Badge>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                {canWrite && (
                  <button onClick={() => openEdit(c)} className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-primary-600" aria-label="Edit">
                    <Edit className="h-4 w-4" />
                  </button>
                )}
                {canDelete && (
                  <button onClick={() => setConfirmDelete(c)} className="rounded p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600" aria-label="Delete">
                    <Trash2 className="h-4 w-4" />
                  </button>
                )}
              </div>
            </Card>
          ))}
        </div>
      )}

      <Modal isOpen={showForm} onClose={() => setShowForm(false)} title={editing ? 'Edit category' : 'New category'}>
        <div className="space-y-4">
          <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Announcements" />
          <Input label="Description" value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Optional" />
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setShowForm(false)}>
              Cancel
            </Button>
            <Button onClick={save} disabled={saving}>
              {saving && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}
              {editing ? 'Save' : 'Create'}
            </Button>
          </div>
        </div>
      </Modal>

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete category"
        message={`Delete "${confirmDelete?.name}"? Posts in it become uncategorised.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// ============================================================
// Tags tab
// ============================================================
function TagsTab() {
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('cms', 'update');
  const canDelete = hasPermission('cms', 'delete');

  const [tags, setTags] = useState<CmsTag[]>([]);
  const [loading, setLoading] = useState(true);
  const [newTag, setNewTag] = useState('');
  const [creating, setCreating] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<CmsTag | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setTags(await cmsService.getTags());
    } catch {
      toast.error('Failed to load tags');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const create = async () => {
    if (!newTag.trim()) return;
    setCreating(true);
    try {
      await cmsService.createTag({ name: newTag.trim() });
      setNewTag('');
      load();
    } catch {
      toast.error('Failed to create tag');
    } finally {
      setCreating(false);
    }
  };

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await cmsService.deleteTag(confirmDelete.uuid);
      toast.success('Tag deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete tag');
    } finally {
      setDeleting(false);
    }
  };

  return (
    <div className="space-y-4">
      <p className="text-sm text-secondary-500">Lightweight labels for cross-cutting topics.</p>

      {canWrite && (
        <div className="flex max-w-md gap-2">
          <Input
            value={newTag}
            onChange={(e) => setNewTag(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && create()}
            placeholder="Add a tag…"
          />
          <Button onClick={create} disabled={creating}>
            {creating ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
          </Button>
        </div>
      )}

      {loading ? (
        <div className="flex justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : tags.length === 0 ? (
        <Card>
          <p className="py-8 text-center text-secondary-500">No tags yet.</p>
        </Card>
      ) : (
        <div className="flex flex-wrap gap-2">
          {tags.map((t) => (
            <span
              key={t.uuid}
              className="inline-flex items-center gap-2 rounded-full border border-secondary-200 bg-surface px-3 py-1.5 text-sm text-secondary-700"
            >
              <TagIcon className="h-3.5 w-3.5 text-secondary-400" />
              {t.name}
              <span className="text-xs text-secondary-400">{t.post_count ?? 0}</span>
              {canDelete && (
                <button onClick={() => setConfirmDelete(t)} className="text-secondary-400 hover:text-error-600" aria-label={`Delete ${t.name}`}>
                  <Trash2 className="h-3.5 w-3.5" />
                </button>
              )}
            </span>
          ))}
        </div>
      )}

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete tag"
        message={`Delete "${confirmDelete?.name}"? It will be removed from all posts.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// ============================================================
// Webhooks tab
// ============================================================
function WebhooksTab() {
  const { hasPermission } = usePermissions();
  const canWrite = hasPermission('cms', 'update');
  const canDelete = hasPermission('cms', 'delete');

  const [hooks, setHooks] = useState<CmsWebhook[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<CmsWebhook | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [events, setEvents] = useState<string[]>([...WEBHOOK_EVENTS]);
  const [active, setActive] = useState(true);
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<CmsWebhook | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setHooks(await cmsService.getWebhooks());
    } catch {
      toast.error('Failed to load webhooks');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openNew = () => {
    setEditing(null);
    setName('');
    setUrl('');
    setEvents([...WEBHOOK_EVENTS]);
    setActive(true);
    setShowForm(true);
  };
  const openEdit = (w: CmsWebhook) => {
    setEditing(w);
    setName(w.name ?? '');
    setUrl(w.url);
    setEvents(String(w.events || '').split(',').map((s) => s.trim()).filter(Boolean));
    setActive(w.active);
    setShowForm(true);
  };

  const toggleEvent = (e: string) =>
    setEvents((prev) => (prev.includes(e) ? prev.filter((x) => x !== e) : [...prev, e]));

  const save = async () => {
    if (!/^https?:\/\//.test(url.trim())) {
      toast.error('A valid http(s) URL is required');
      return;
    }
    if (events.length === 0) {
      toast.error('Select at least one event');
      return;
    }
    setSaving(true);
    try {
      if (editing) {
        await cmsService.updateWebhook(editing.uuid, { name, url, events, active });
        toast.success('Webhook updated');
      } else {
        await cmsService.createWebhook({ name, url, events, active });
        toast.success('Webhook created');
      }
      setShowForm(false);
      load();
    } catch {
      toast.error('Failed to save webhook');
    } finally {
      setSaving(false);
    }
  };

  const doDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    try {
      await cmsService.deleteWebhook(confirmDelete.uuid);
      toast.success('Webhook deleted');
      setConfirmDelete(null);
      load();
    } catch {
      toast.error('Failed to delete webhook');
    } finally {
      setDeleting(false);
    }
  };

  const copySecret = async (w: CmsWebhook) => {
    try {
      await navigator.clipboard.writeText(w.secret);
      setCopied(w.uuid);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      toast.error('Could not copy');
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-secondary-500">
          Notify an external URL when content changes. OPSAPI POSTs a signed payload
          (<code className="text-xs">X-Opsapi-Signature-256</code>) on the events you pick.
        </p>
        {canWrite && (
          <Button onClick={openNew}>
            <Plus className="mr-1 h-4 w-4" /> New Webhook
          </Button>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : hooks.length === 0 ? (
        <Card>
          <p className="py-8 text-center text-secondary-500">No webhooks yet.</p>
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
          {hooks.map((w) => (
            <Card key={w.uuid} className="space-y-2">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium text-secondary-900">{w.name || 'Webhook'}</span>
                    <Badge variant={w.active ? 'success' : 'secondary'} size="sm">
                      {w.active ? 'active' : 'paused'}
                    </Badge>
                  </div>
                  <div className="truncate text-xs text-secondary-400">{w.url}</div>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  {canWrite && (
                    <button onClick={() => openEdit(w)} className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-primary-600" aria-label="Edit">
                      <Edit className="h-4 w-4" />
                    </button>
                  )}
                  {canDelete && (
                    <button onClick={() => setConfirmDelete(w)} className="rounded p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-600" aria-label="Delete">
                      <Trash2 className="h-4 w-4" />
                    </button>
                  )}
                </div>
              </div>
              <div className="flex flex-wrap gap-1">
                {String(w.events || '').split(',').filter(Boolean).map((e) => (
                  <Badge key={e} variant="secondary" size="sm">
                    {e.trim()}
                  </Badge>
                ))}
              </div>
              <div className="flex items-center justify-between gap-2 text-xs text-secondary-400">
                <button onClick={() => copySecret(w)} className="inline-flex items-center gap-1 hover:text-primary-600" aria-label="Copy signing secret">
                  {copied === w.uuid ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
                  secret: {w.secret ? `${w.secret.slice(0, 8)}…` : '—'}
                </button>
                <span>
                  {w.last_triggered_at ? `last: ${w.last_status ?? '?'} · ${formatDate(w.last_triggered_at)}` : 'never fired'}
                </span>
              </div>
            </Card>
          ))}
        </div>
      )}

      <Modal isOpen={showForm} onClose={() => setShowForm(false)} title={editing ? 'Edit webhook' : 'New webhook'}>
        <div className="space-y-4">
          <Input label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Website revalidation" />
          <Input label="URL" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://www.example.com/api/revalidate" />
          <div>
            <label className="mb-1.5 block text-sm font-medium text-secondary-700">Events</label>
            <div className="flex flex-col gap-2">
              {WEBHOOK_EVENTS.map((e) => (
                <label key={e} className="flex items-center gap-2 text-sm text-secondary-800">
                  <input type="checkbox" className="h-4 w-4" checked={events.includes(e)} onChange={() => toggleEvent(e)} />
                  {e}
                </label>
              ))}
            </div>
          </div>
          <label className="flex items-center gap-2 text-sm text-secondary-800">
            <input type="checkbox" className="h-4 w-4" checked={active} onChange={(e) => setActive(e.target.checked)} />
            Active
          </label>
          {editing && (
            <p className="text-xs text-secondary-400">
              A signing secret was generated when this webhook was created — copy it from the card to configure the receiver.
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setShowForm(false)}>
              Cancel
            </Button>
            <Button onClick={save} disabled={saving}>
              {saving && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}
              {editing ? 'Save' : 'Create'}
            </Button>
          </div>
        </div>
      </Modal>

      <ConfirmDialog
        isOpen={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        onConfirm={doDelete}
        title="Delete webhook"
        message={`Delete the webhook to "${confirmDelete?.url}"?`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// ============================================================
// Hub
// ============================================================
function CmsHub() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const initial = (searchParams.get('tab') as TabKey) || 'posts';
  const [tab, setTab] = useState<TabKey>(
    TABS.some((t) => t.key === initial) ? initial : 'posts',
  );

  const setActive = (key: TabKey) => {
    setTab(key);
    router.replace(`/dashboard/cms?tab=${key}`);
  };

  const activeLabel = useMemo(() => TABS.find((t) => t.key === tab)?.label, [tab]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Content"
        description="Manage your website pages and blog — articles, categories and tags."
        icon={<FileText className="h-6 w-6" />}
      />

      {/* Tabs */}
      <div className="border-b border-secondary-200">
        <nav className="-mb-px flex flex-wrap gap-1" aria-label="CMS sections">
          {TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => setActive(t.key)}
              className={`inline-flex items-center gap-2 border-b-2 px-4 py-2.5 text-sm font-medium transition-colors ${
                tab === t.key
                  ? 'border-primary-500 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:border-secondary-300 hover:text-secondary-700'
              }`}
              aria-current={tab === t.key ? 'page' : undefined}
            >
              {t.icon}
              {t.label}
            </button>
          ))}
        </nav>
      </div>

      <div role="tabpanel" aria-label={activeLabel}>
        {tab === 'posts' && <PostsTab />}
        {tab === 'pages' && <PagesTab />}
        {tab === 'categories' && <CategoriesTab />}
        {tab === 'tags' && <TagsTab />}
        {tab === 'webhooks' && <WebhooksTab />}
      </div>
    </div>
  );
}

export default function CmsContentPage() {
  return (
    <ProtectedPage module="cms" action="read" title="Content">
      <Suspense
        fallback={
          <div className="flex justify-center py-24">
            <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
          </div>
        }
      >
        <CmsHub />
      </Suspense>
    </ProtectedPage>
  );
}
