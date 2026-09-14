'use client';

/**
 * Product detail — /dashboard/products/[uuid]
 *
 * View + light inline edit for a single storeproduct. In the field-service
 * world a product doubles as the serviceable "asset" a job/request points at,
 * so this is the reference page for what's being repaired.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Package, Edit, Trash2, Save, X, Loader2 } from 'lucide-react';
import { Button, Card, Badge, Input, Textarea, Select, ConfirmDialog } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { productsService } from '@/services';
import type { StoreProductDetail } from '@/services/products.service';
import { formatCurrency, formatDateTime } from '@/lib/utils';

/** The images column can be a JSON array, a single URL, or the odd "'[]'". */
function firstImage(p: StoreProductDetail): string | null {
  if (p.thumbnail_url) return p.thumbnail_url;
  const raw = (p.images || '').trim().replace(/^'|'$/g, '');
  if (!raw) return null;
  if (raw.startsWith('[')) {
    try {
      const arr = JSON.parse(raw);
      if (Array.isArray(arr) && arr.length) return typeof arr[0] === 'string' ? arr[0] : arr[0]?.url || null;
    } catch {
      return null;
    }
    return null;
  }
  return raw.startsWith('http') ? raw : null;
}

type EditForm = {
  name: string;
  sku: string;
  price: string;
  compare_price: string;
  cost_price: string;
  inventory_quantity: string;
  low_stock_threshold: string;
  short_description: string;
  description: string;
  is_active: string;
  is_featured: string;
};

function formFrom(p: StoreProductDetail): EditForm {
  const s = (v: unknown) => (v == null ? '' : String(v));
  return {
    name: p.name || '',
    sku: s(p.sku),
    price: s(p.price),
    compare_price: s(p.compare_price),
    cost_price: s(p.cost_price),
    inventory_quantity: s(p.inventory_quantity),
    low_stock_threshold: s(p.low_stock_threshold),
    short_description: s(p.short_description),
    description: s(p.description),
    is_active: p.is_active === false ? 'false' : 'true',
    is_featured: p.is_featured ? 'true' : 'false',
  };
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-secondary-400">{label}</dt>
      <dd className="mt-0.5 text-sm text-secondary-900">{children}</dd>
    </div>
  );
}

function ProductDetailContent() {
  const { uuid } = useParams<{ uuid: string }>();
  const router = useRouter();
  const { canUpdate, canDelete } = usePermissions();

  const [product, setProduct] = useState<StoreProductDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState<EditForm | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const p = await productsService.getStoreProduct(uuid);
      if (p && p.uuid) {
        setProduct(p);
        setForm(formFrom(p));
      } else {
        setNotFound(true);
      }
    } catch {
      setNotFound(true);
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const image = useMemo(() => (product ? firstImage(product) : null), [product]);

  const setField = (key: keyof EditForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) =>
    setForm((f) => (f ? { ...f, [key]: e.target.value } : f));

  const startEdit = () => {
    if (product) setForm(formFrom(product));
    setEditing(true);
  };

  const save = async () => {
    if (!form) return;
    if (!form.name.trim()) {
      toast.error('Name is required');
      return;
    }
    if (!form.price || Number(form.price) <= 0) {
      toast.error('Price must be greater than 0');
      return;
    }
    setSaving(true);
    try {
      const payload: Record<string, unknown> = {
        name: form.name.trim(),
        sku: form.sku.trim(),
        price: form.price.trim(),
        compare_price: form.compare_price.trim() || 'null',
        cost_price: form.cost_price.trim() || '0',
        inventory_quantity: form.inventory_quantity.trim() || '0',
        low_stock_threshold: form.low_stock_threshold.trim() || '0',
        short_description: form.short_description.trim(),
        description: form.description.trim(),
        is_active: form.is_active,
        is_featured: form.is_featured,
      };
      await productsService.updateStoreProduct(uuid, payload);
      toast.success('Product updated');
      setEditing(false);
      await load();
    } catch {
      toast.error('Failed to save product');
    } finally {
      setSaving(false);
    }
  };

  const remove = async () => {
    setDeleting(true);
    try {
      await productsService.deleteStoreProduct(uuid);
      toast.success('Product deleted');
      router.push('/dashboard/products');
    } catch {
      toast.error('Failed to delete product');
      setDeleting(false);
      setConfirmDelete(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading product…
      </div>
    );
  }

  if (notFound || !product || !form) {
    return (
      <div className="space-y-4">
        <Link href="/dashboard/products" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="w-4 h-4" /> Products
        </Link>
        <Card padding="lg">
          <p className="text-center text-secondary-600">Product not found.</p>
        </Card>
      </div>
    );
  }

  const qty = product.inventory_quantity ?? 0;
  const lowAt = product.low_stock_threshold ?? 0;
  const stockTone = qty <= 0 ? 'error' : qty <= lowAt ? 'warning' : 'success';

  return (
    <div className="space-y-6">
      <Link href="/dashboard/products" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="w-4 h-4" /> Products
      </Link>

      <PageHeader
        title={product.name}
        description={product.sku ? `SKU ${product.sku}` : 'Product'}
        icon={<Package className="w-5 h-5" />}
        actions={
          editing ? (
            <div className="flex gap-2">
              <Button variant="ghost" leftIcon={<X className="w-4 h-4" />} onClick={() => setEditing(false)} disabled={saving}>
                Cancel
              </Button>
              <Button leftIcon={<Save className="w-4 h-4" />} onClick={save} isLoading={saving}>
                Save
              </Button>
            </div>
          ) : (
            <div className="flex gap-2">
              {canUpdate('products') && (
                <Button variant="secondary" leftIcon={<Edit className="w-4 h-4" />} onClick={startEdit}>
                  Edit
                </Button>
              )}
              {canDelete('products') && (
                <Button variant="ghost" leftIcon={<Trash2 className="w-4 h-4" />} onClick={() => setConfirmDelete(true)}>
                  Delete
                </Button>
              )}
            </div>
          )
        }
      />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main */}
        <div className="lg:col-span-2 space-y-6">
          <Card padding="lg">
            <div className="flex gap-5">
              <div className="shrink-0">
                {image ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={image} alt={product.name} className="w-28 h-28 rounded-xl object-cover border border-secondary-200" />
                ) : (
                  <div className="w-28 h-28 rounded-xl bg-secondary-100 flex items-center justify-center">
                    <Package className="w-10 h-10 text-secondary-400" />
                  </div>
                )}
              </div>
              <div className="min-w-0 flex-1 space-y-3">
                {editing ? (
                  <>
                    <Input label="Name *" value={form.name} onChange={setField('name')} />
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                      <Input label="SKU" value={form.sku} onChange={setField('sku')} />
                      <Select label="Status" value={form.is_active} onChange={setField('is_active')}>
                        <option value="true">Active</option>
                        <option value="false">Inactive</option>
                      </Select>
                    </div>
                  </>
                ) : (
                  <>
                    <div className="flex items-center gap-2 flex-wrap">
                      <Badge variant={product.is_active === false ? 'secondary' : 'success'} size="sm">
                        {product.is_active === false ? 'Inactive' : 'Active'}
                      </Badge>
                      {product.is_featured && <Badge variant="info" size="sm">Featured</Badge>}
                      {product.is_digital && <Badge variant="default" size="sm">Digital</Badge>}
                    </div>
                    {product.short_description && <p className="text-sm text-secondary-600">{product.short_description}</p>}
                    {product.slug && <p className="text-xs text-secondary-400">/{product.slug}</p>}
                  </>
                )}
              </div>
            </div>
          </Card>

          <Card padding="lg">
            <h2 className="text-sm font-semibold text-secondary-800 mb-3">Description</h2>
            {editing ? (
              <div className="space-y-3">
                <Input label="Short description" value={form.short_description} onChange={setField('short_description')} />
                <Textarea label="Full description" rows={5} value={form.description} onChange={setField('description')} />
              </div>
            ) : product.description ? (
              <p className="text-sm text-secondary-700 whitespace-pre-wrap">{product.description}</p>
            ) : (
              <p className="text-sm text-secondary-400">No description.</p>
            )}
          </Card>
        </div>

        {/* Sidebar */}
        <div className="space-y-6">
          <Card padding="lg">
            <h2 className="text-sm font-semibold text-secondary-800 mb-3">Pricing</h2>
            {editing ? (
              <div className="space-y-3">
                <Input label="Price" inputMode="decimal" value={form.price} onChange={setField('price')} />
                <Input label="Compare-at price" inputMode="decimal" value={form.compare_price} onChange={setField('compare_price')} />
                <Input label="Cost price" inputMode="decimal" value={form.cost_price} onChange={setField('cost_price')} />
              </div>
            ) : (
              <dl className="space-y-3">
                <Field label="Price">
                  <span className="text-lg font-semibold">{formatCurrency(product.price)}</span>
                </Field>
                {product.compare_price != null && product.compare_price > product.price && (
                  <Field label="Compare at">
                    <span className="line-through text-secondary-400">{formatCurrency(product.compare_price)}</span>
                  </Field>
                )}
                {product.cost_price != null && product.cost_price > 0 && (
                  <Field label="Cost">{formatCurrency(product.cost_price)}</Field>
                )}
              </dl>
            )}
          </Card>

          <Card padding="lg">
            <h2 className="text-sm font-semibold text-secondary-800 mb-3">Inventory</h2>
            {editing ? (
              <div className="space-y-3">
                <Input label="Quantity" inputMode="numeric" value={form.inventory_quantity} onChange={setField('inventory_quantity')} />
                <Input label="Low-stock threshold" inputMode="numeric" value={form.low_stock_threshold} onChange={setField('low_stock_threshold')} />
                <Select label="Featured" value={form.is_featured} onChange={setField('is_featured')}>
                  <option value="false">No</option>
                  <option value="true">Yes</option>
                </Select>
              </div>
            ) : (
              <dl className="space-y-3">
                <Field label="In stock">
                  <Badge variant={stockTone} size="sm">{qty} in stock</Badge>
                </Field>
                <Field label="Low-stock threshold">{lowAt}</Field>
                <Field label="Tracked">{product.track_inventory ? 'Yes' : 'No'}</Field>
              </dl>
            )}
          </Card>

          <Card padding="lg">
            <h2 className="text-sm font-semibold text-secondary-800 mb-3">Details</h2>
            <dl className="space-y-3">
              {product.barcode && <Field label="Barcode">{product.barcode}</Field>}
              {product.weight != null && product.weight > 0 && <Field label="Weight">{product.weight}</Field>}
              {product.tags && <Field label="Tags">{product.tags}</Field>}
              {product.created_at && <Field label="Created">{formatDateTime(product.created_at)}</Field>}
              {product.updated_at && <Field label="Updated">{formatDateTime(product.updated_at)}</Field>}
            </dl>
          </Card>
        </div>
      </div>

      <ConfirmDialog
        isOpen={confirmDelete}
        onClose={() => setConfirmDelete(false)}
        onConfirm={remove}
        title="Delete product"
        message={`Delete "${product.name}"? This cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function ProductDetailPage() {
  return (
    <ProtectedPage module="products" title="Product">
      <ProductDetailContent />
    </ProtectedPage>
  );
}
