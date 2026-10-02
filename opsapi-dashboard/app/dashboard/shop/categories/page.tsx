'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Edit, FolderTree, Plus, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, ConfirmDialog, Input, Modal, Select, Table, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { SHOP_MODULE, ShopThumb } from '@/components/shop/shared';
import { CheckboxField } from '@/components/shop/editor-fields';
import { extractApiError } from '@/lib/utils';
import { slugify, typingSlug } from '@/lib/shop';
import type { ShopCategory, TableColumn } from '@/types';

interface CatForm {
  name: string;
  slug: string;
  description: string;
  image_url: string;
  parent_uuid: string;
  sort_order: string;
  is_active: boolean;
}

const emptyForm: CatForm = { name: '', slug: '', description: '', image_url: '', parent_uuid: '', sort_order: '0', is_active: true };

function CategoriesContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [rows, setRows] = useState<ShopCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [version, setVersion] = useState(0);
  const [editing, setEditing] = useState<ShopCategory | 'new' | null>(null);
  const [form, setForm] = useState<CatForm>(emptyForm);
  const [slugTouched, setSlugTouched] = useState(false);
  const [saving, setSaving] = useState(false);
  const [toDelete, setToDelete] = useState<ShopCategory | null>(null);
  const [deleting, setDeleting] = useState(false);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getCategories()
      .then((c) => active && setRows([...c].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || a.name.localeCompare(b.name))))
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load categories')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [version]);

  const open = (c: ShopCategory | 'new') => {
    setEditing(c);
    setSlugTouched(c !== 'new');
    setForm(
      c === 'new'
        ? { ...emptyForm, sort_order: String(rows.length) }
        : {
            name: c.name,
            slug: c.slug,
            description: c.description ?? '',
            image_url: c.image_url ?? '',
            parent_uuid: c.parent_uuid ?? '',
            sort_order: String(c.sort_order ?? 0),
            is_active: c.is_active !== false,
          }
    );
  };

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) {
      toast.error('Name is required');
      return;
    }
    const payload = {
      name: form.name.trim(),
      slug: form.slug.trim() || slugify(form.name),
      description: form.description.trim(),
      image_url: form.image_url.trim(),
      parent_uuid: form.parent_uuid || null,
      sort_order: parseInt(form.sort_order, 10) || 0,
      is_active: form.is_active,
    };
    setSaving(true);
    try {
      if (editing === 'new') {
        await shopService.createCategory(payload);
        toast.success('Category created');
      } else if (editing) {
        await shopService.updateCategory(editing.uuid, payload);
        toast.success('Category saved');
      }
      setEditing(null);
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to save category'));
    } finally {
      setSaving(false);
    }
  };

  const confirmDelete = async () => {
    if (!toDelete) return;
    setDeleting(true);
    try {
      await shopService.deleteCategory(toDelete.uuid);
      toast.success('Category deleted');
      reload();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to delete category'));
    } finally {
      setDeleting(false);
      setToDelete(null);
    }
  };

  const parentName = (uuid?: string | null) => (uuid ? rows.find((r) => r.uuid === uuid)?.name : undefined);

  const columns: TableColumn<ShopCategory>[] = [
    {
      key: 'name',
      header: 'Category',
      render: (c) => (
        <div className="flex items-center gap-3">
          <ShopThumb
            src={c.image_url}
            className="h-10 w-10 rounded-lg border border-secondary-200 object-cover"
            fallback={
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-secondary-100">
                <FolderTree className="h-5 w-5 text-secondary-400" />
              </div>
            }
          />
          <div>
            <p className="font-medium text-secondary-900">{c.name}</p>
            <p className="font-mono text-xs text-secondary-500">
              /c/{c.slug}
              {parentName(c.parent_uuid) ? ` · in ${parentName(c.parent_uuid)}` : ''}
            </p>
          </div>
        </div>
      ),
    },
    { key: 'product_count', header: 'Products', render: (c) => <span className="tabular-nums">{c.product_count ?? '—'}</span> },
    { key: 'sort_order', header: 'Order', render: (c) => <span className="tabular-nums">{c.sort_order ?? 0}</span> },
    {
      key: 'is_active',
      header: 'Status',
      render: (c) => (c.is_active ? <Badge size="sm" variant="success">Active</Badge> : <Badge size="sm" variant="secondary">Hidden</Badge>),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-20',
      render: (c) => (
        <div className="flex items-center gap-1">
          {canUpdate(SHOP_MODULE) && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                open(c);
              }}
              className="rounded-lg p-1.5 text-secondary-500 hover:bg-primary-50 hover:text-primary-500"
              aria-label={`Edit ${c.name}`}
            >
              <Edit className="h-4 w-4" />
            </button>
          )}
          {canDelete(SHOP_MODULE) && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                setToDelete(c);
              }}
              className="rounded-lg p-1.5 text-secondary-500 hover:bg-error-50 hover:text-error-500"
              aria-label={`Delete ${c.name}`}
            >
              <Trash2 className="h-4 w-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop categories"
        description="Category tiles and filters on the shop"
        icon={<FolderTree className="h-5 w-5" />}
        actions={
          canCreate(SHOP_MODULE) ? (
            <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => open('new')}>
              New category
            </Button>
          ) : undefined
        }
      />

      <Table
        columns={columns}
        data={rows}
        keyExtractor={(c) => c.uuid}
        onRowClick={canUpdate(SHOP_MODULE) ? open : undefined}
        isLoading={loading}
        emptyMessage="No categories yet"
        caption="Shop categories"
      />

      <Modal
        isOpen={editing !== null}
        onClose={() => setEditing(null)}
        title={editing === 'new' ? 'New category' : 'Edit category'}
        size="lg"
      >
        {editing !== null && (
          <form onSubmit={save} className="space-y-4">
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Input
                label="Name *"
                id="cat-name"
                value={form.name}
                autoFocus
                onChange={(e) => {
                  const name = e.target.value;
                  setForm((f) => ({ ...f, name, slug: slugTouched ? f.slug : slugify(name) }));
                }}
              />
              <Input
                label="Slug"
                id="cat-slug"
                value={form.slug}
                className="font-mono"
                onBlur={() => form.slug && setForm((f) => ({ ...f, slug: slugify(f.slug) }))}
                onChange={(e) => {
                  setSlugTouched(true);
                  setForm((f) => ({ ...f, slug: typingSlug(e.target.value) }));
                }}
              />
              <Select label="Parent" id="cat-parent" value={form.parent_uuid} onChange={(e) => setForm((f) => ({ ...f, parent_uuid: e.target.value }))}>
                <option value="">— None (top level) —</option>
                {rows
                  .filter((r) => editing === 'new' || r.uuid !== editing.uuid)
                  .map((r) => (
                    <option key={r.uuid} value={r.uuid}>{r.name}</option>
                  ))}
              </Select>
              <Input label="Sort order" id="cat-sort" value={form.sort_order} inputMode="numeric" onChange={(e) => setForm((f) => ({ ...f, sort_order: e.target.value }))} />
            </div>
            <Input label="Image URL" id="cat-img" value={form.image_url} onChange={(e) => setForm((f) => ({ ...f, image_url: e.target.value }))} placeholder="https://…" />
            <Textarea label="Description" id="cat-desc" rows={3} value={form.description} onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))} />
            <CheckboxField label="Active (visible on the shop)" checked={form.is_active} onChange={(v) => setForm((f) => ({ ...f, is_active: v }))} />
            <div className="flex justify-end gap-2 border-t border-secondary-200 pt-4">
              <Button type="button" variant="ghost" onClick={() => setEditing(null)}>Cancel</Button>
              <Button type="submit" isLoading={saving}>{editing === 'new' ? 'Create' : 'Save'}</Button>
            </div>
          </form>
        )}
      </Modal>

      <ConfirmDialog
        isOpen={!!toDelete}
        onClose={() => setToDelete(null)}
        onConfirm={confirmDelete}
        title="Delete category"
        message={`Delete "${toDelete?.name}"? Products in it become uncategorised.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function ShopCategoriesPage() {
  return (
    <ProtectedPage module="shop" title="Shop Categories">
      <CategoriesContent />
    </ProtectedPage>
  );
}
