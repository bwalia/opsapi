'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Pencil, Plus, RefreshCw, Search, Truck, Upload } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, Pagination, SearchableSelect, Select, Table, Textarea } from '@/components/ui';
import type { SearchableSelectOption } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { FilterSelect, ShopLoading } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { formatMoney } from '@/lib/shop';
import {
  SHOP_SUPPLIER_FIELDS,
  type ShopSupplier,
  type ShopSupplierField,
  type ShopSupplierInput,
  type ShopSupplierItem,
  type ShopSupplierSummary,
  type TableColumn,
} from '@/types';

const FIELD_LABEL: Record<ShopSupplierField, string> = {
  supplier_sku: 'Supplier SKU *',
  name: 'Product name *',
  cost: 'Trade price (cost) *',
  mpn: 'Manufacturer part no.',
  brand: 'Brand',
  category: 'Category',
  stock: 'Stock',
  lead_time_days: 'Lead time',
  rrp: 'RRP',
  url: 'Product URL',
  ean: 'EAN / barcode',
};

/** Plain-English one-liner for a sync/import result. */
function summaryLine(s: ShopSupplierSummary): string {
  const p = s.pricing;
  return (
    `${s.kept} NVIDIA item(s) from ${s.records} row(s)` +
    (s.filtered_out ? `, ${s.filtered_out} other item(s) skipped` : '') +
    (s.invalid ? `, ${s.invalid} unreadable row(s)` : '') +
    (s.cost_changed ? `, ${s.cost_changed} cost change(s)` : '') +
    (p ? ` · prices: ${p.applied} updated, ${p.pending} waiting for approval` : '')
  );
}

// ---------------------------------------------------------------------------------------- supplier form

interface FormState {
  name: string;
  feed_format: 'csv' | 'json' | 'xml';
  feed_url: string;
  delimiter: string;
  records_path: string;
  record_tag: string;
  auth_type: 'none' | 'basic' | 'bearer' | 'header';
  auth_username: string;
  auth_header_name: string;
  auth_secret: string;
  mapping: Partial<Record<ShopSupplierField, string>>;
  keywords: string;
  prices_include_vat: boolean;
  default_margin_pct: string;
  change_threshold_pct: string;
  sync_hours: string;
  update_lead_times: boolean;
  is_active: boolean;
}

function toForm(s?: ShopSupplier): FormState {
  return {
    name: s?.name ?? '',
    feed_format: s?.feed_format ?? 'csv',
    feed_url: s?.feed_url ?? '',
    delimiter: s?.feed_options?.delimiter === '\t' ? '\\t' : s?.feed_options?.delimiter ?? '',
    records_path: s?.feed_options?.records_path ?? '',
    record_tag: s?.feed_options?.record_tag ?? '',
    auth_type: s?.auth_type ?? 'none',
    auth_username: s?.auth_username ?? '',
    auth_header_name: s?.auth_header_name ?? '',
    auth_secret: '',
    mapping: s?.mapping ?? {},
    keywords: (s?.filter?.keywords ?? []).join(', '),
    prices_include_vat: s?.prices_include_vat ?? false,
    default_margin_pct: String(s?.default_margin_pct ?? 15),
    change_threshold_pct: String(s?.change_threshold_pct ?? 10),
    sync_hours: String(s?.sync_hours ?? 24),
    update_lead_times: s?.update_lead_times ?? true,
    is_active: s?.is_active ?? true,
  };
}

function SupplierModal({ supplier, open, onClose, onSaved }: { supplier?: ShopSupplier; open: boolean; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<FormState>(toForm(supplier));
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (open) setF(toForm(supplier));
  }, [open, supplier]);

  const set = <K extends keyof FormState>(k: K, v: FormState[K]) => setF((prev) => ({ ...prev, [k]: v }));
  const valid = f.name.trim() && f.mapping.supplier_sku?.trim() && f.mapping.name?.trim() && f.mapping.cost?.trim();

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid) return;
    setSaving(true);
    const mapping = Object.fromEntries(Object.entries(f.mapping).filter(([, v]) => v && v.trim()).map(([k, v]) => [k, v!.trim()]));
    const body: ShopSupplierInput = {
      name: f.name.trim(),
      feed_format: f.feed_format,
      feed_url: f.feed_url.trim() || null,
      feed_options: {
        ...(f.delimiter ? { delimiter: f.delimiter } : {}),
        ...(f.records_path ? { records_path: f.records_path.trim() } : {}),
        ...(f.record_tag ? { record_tag: f.record_tag.trim() } : {}),
      },
      auth_type: f.auth_type,
      auth_username: f.auth_username.trim() || null,
      auth_header_name: f.auth_header_name.trim() || null,
      mapping,
      prices_include_vat: f.prices_include_vat,
      default_margin_pct: Number(f.default_margin_pct),
      change_threshold_pct: Number(f.change_threshold_pct),
      sync_hours: Number(f.sync_hours),
      update_lead_times: f.update_lead_times,
      is_active: f.is_active,
      ...(f.keywords.trim() ? { filter: { keywords: f.keywords.split(',').map((k) => k.trim()).filter(Boolean) } } : {}),
      ...(f.auth_secret ? { auth_secret: f.auth_secret } : {}),
    };
    try {
      if (supplier) await shopService.updateSupplier(supplier.uuid, body);
      else await shopService.createSupplier(body);
      toast.success(supplier ? 'Supplier saved' : 'Supplier added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to save the supplier'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title={supplier ? `Edit ${supplier.name}` : 'Add supplier'} description="Where their price file comes from and how to read it." size="lg">
      <form onSubmit={submit} className="space-y-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Supplier name *" id="sp-name" value={f.name} onChange={(e) => set('name', e.target.value)} autoFocus />
          <Select label="File format" id="sp-format" value={f.feed_format} onChange={(e) => set('feed_format', e.target.value as FormState['feed_format'])}>
            <option value="csv">CSV (spreadsheet)</option>
            <option value="json">JSON</option>
            <option value="xml">XML</option>
          </Select>
        </div>
        <Input
          label="Feed URL (leave blank to upload files by hand)"
          id="sp-url"
          placeholder="https://supplier.example/pricefile.csv"
          value={f.feed_url}
          onChange={(e) => set('feed_url', e.target.value)}
        />
        {f.feed_format === 'csv' && <Input label="Column separator (blank = comma; \t = tab)" id="sp-delim" value={f.delimiter} onChange={(e) => set('delimiter', e.target.value)} />}
        {f.feed_format === 'json' && <Input label="Where the product list is (e.g. data.items)" id="sp-path" value={f.records_path} onChange={(e) => set('records_path', e.target.value)} />}
        {f.feed_format === 'xml' && <Input label="XML element for one product (e.g. product) *" id="sp-tag" value={f.record_tag} onChange={(e) => set('record_tag', e.target.value)} />}

        <fieldset className="space-y-3 rounded-md border border-secondary-200 p-3">
          <legend className="px-1 text-sm font-medium text-secondary-700">Feed login</legend>
          <Select label="Login type" id="sp-auth" value={f.auth_type} onChange={(e) => set('auth_type', e.target.value as FormState['auth_type'])}>
            <option value="none">None</option>
            <option value="basic">Username and password</option>
            <option value="bearer">Token (Bearer)</option>
            <option value="header">API key in a header</option>
          </Select>
          {f.auth_type === 'basic' && <Input label="Username" id="sp-user" value={f.auth_username} onChange={(e) => set('auth_username', e.target.value)} />}
          {f.auth_type === 'header' && <Input label="Header name" id="sp-hdr" placeholder="X-API-Key" value={f.auth_header_name} onChange={(e) => set('auth_header_name', e.target.value)} />}
          {f.auth_type !== 'none' && (
            <Input
              label={supplier?.has_auth_secret ? 'Password / token (saved — type to replace)' : 'Password / token'}
              id="sp-secret"
              type="password"
              autoComplete="new-password"
              value={f.auth_secret}
              onChange={(e) => set('auth_secret', e.target.value)}
            />
          )}
        </fieldset>

        <fieldset className="rounded-md border border-secondary-200 p-3">
          <legend className="px-1 text-sm font-medium text-secondary-700">Column names in their file</legend>
          <div className="grid gap-3 sm:grid-cols-2">
            {SHOP_SUPPLIER_FIELDS.map((k) => (
              <Input key={k} label={FIELD_LABEL[k]} id={`sp-map-${k}`} value={f.mapping[k] ?? ''} onChange={(e) => set('mapping', { ...f.mapping, [k]: e.target.value })} />
            ))}
          </div>
        </fieldset>

        <Textarea
          label="Only keep items mentioning (comma-separated; blank = the NVIDIA list)"
          id="sp-kw"
          rows={2}
          value={f.keywords}
          onChange={(e) => set('keywords', e.target.value)}
        />
        <div className="grid gap-4 sm:grid-cols-3">
          <Input label="Default margin %" id="sp-margin" inputMode="decimal" value={f.default_margin_pct} onChange={(e) => set('default_margin_pct', e.target.value)} />
          <Input label="Ask me above (% change)" id="sp-thr" inputMode="decimal" value={f.change_threshold_pct} onChange={(e) => set('change_threshold_pct', e.target.value)} />
          <Input label="Sync every (hours)" id="sp-hours" inputMode="numeric" value={f.sync_hours} onChange={(e) => set('sync_hours', e.target.value)} />
        </div>
        <div className="space-y-2 text-sm text-secondary-700">
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={f.prices_include_vat} onChange={(e) => set('prices_include_vat', e.target.checked)} />
            Their prices include VAT
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={f.update_lead_times} onChange={(e) => set('update_lead_times', e.target.checked)} />
            Use their lead times on linked products
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={f.is_active} onChange={(e) => set('is_active', e.target.checked)} />
            Active (included in the daily sync)
          </label>
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={!valid || saving} isLoading={saving}>
            Save
          </Button>
        </div>
      </form>
    </Modal>
  );
}

// ---------------------------------------------------------------------------------------- linking

function LinkModal({ item, onClose, onDone }: { item: ShopSupplierItem | null; onClose: () => void; onDone: () => void }) {
  const [options, setOptions] = useState<SearchableSelectOption[] | null>(null);
  const [product, setProduct] = useState('');
  const [pricing, setPricing] = useState<'supplier' | 'manual'>('supplier');
  const [margin, setMargin] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!item) return;
    setProduct(item.product_uuid ?? '');
    setPricing(item.pricing_source ?? 'supplier');
    setMargin(item.product_margin_pct === null || item.product_margin_pct === undefined ? '' : String(item.product_margin_pct));
    if (!options) {
      shopService
        .getProducts({ limit: 500 })
        .then((r) => setOptions(r.data.map((p) => ({ value: p.uuid, label: p.name, hint: p.sku }))))
        .catch((err) => {
          setOptions([]);
          toast.error(extractApiError(err, 'Failed to load products'));
        });
    }
  }, [item, options]);

  const save = async (unlink = false) => {
    if (!item) return;
    setSaving(true);
    try {
      const res = await shopService.linkSupplierItem(item.uuid, {
        product_uuid: unlink ? null : product,
        pricing_source: pricing,
        margin_pct: margin.trim() === '' ? null : Number(margin),
      });
      const p = res.pricing;
      toast.success(
        unlink ? 'Unlinked' : p?.applied ? 'Linked — price updated' : p?.pending ? 'Linked — new price waiting for approval' : 'Linked'
      );
      onDone();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to link'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={!!item} onClose={onClose} title="Link to a shop product" description={item ? `${item.supplier_sku} · ${item.name}` : undefined} size="md">
      {item && (
        <div className="space-y-4">
          {options === null ? (
            <ShopLoading label="Loading products…" />
          ) : (
            <SearchableSelect label="Shop product" options={options} value={product} onChange={setProduct} placeholder="Select a product" searchPlaceholder="Search name or SKU…" />
          )}
          <Select label="Price" id="lk-pricing" value={pricing} onChange={(e) => setPricing(e.target.value as 'supplier' | 'manual')}>
            <option value="supplier">Follow this supplier (cost + margin)</option>
            <option value="manual">I set the price myself (cost shown for reference)</option>
          </Select>
          {pricing === 'supplier' && (
            <Input
              label="Margin % for this product (blank = category, then supplier default)"
              id="lk-margin"
              inputMode="decimal"
              value={margin}
              onChange={(e) => setMargin(e.target.value)}
            />
          )}
          <p className="text-sm text-secondary-600">
            Cost {formatMoney(item.cost_minor)} ex VAT
            {pricing === 'supplier' && margin.trim() !== '' && !Number.isNaN(Number(margin))
              ? ` → shop price ${formatMoney(Math.round(item.cost_minor * (1 + Number(margin) / 100)))} ex VAT`
              : ''}
            . Changes over the supplier&apos;s threshold wait in Price changes.
          </p>
          <div className="flex justify-between gap-2">
            {item.product_uuid ? (
              <Button variant="ghost" onClick={() => save(true)} disabled={saving}>
                Unlink
              </Button>
            ) : (
              <span />
            )}
            <Button onClick={() => save(false)} disabled={!product || saving} isLoading={saving}>
              Save
            </Button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function ItemsPanel({ supplier, version }: { supplier: ShopSupplier; version: number }) {
  const [rows, setRows] = useState<ShopSupplierItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [linked, setLinked] = useState<'' | 'true' | 'false'>('');
  const [changed, setChanged] = useState(false);
  const [page, setPage] = useState(1);
  const [linking, setLinking] = useState<ShopSupplierItem | null>(null);
  const [reload, setReload] = useState(0);
  const PER = 25;

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopService
      .getSupplierItems(supplier.uuid, { q: q || undefined, linked, changed, limit: PER, offset: (page - 1) * PER })
      .then((r) => {
        if (!active) return;
        setRows(r.data);
        setTotal(r.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load items')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [supplier.uuid, q, linked, changed, page, reload, version]);

  const columns: TableColumn<ShopSupplierItem>[] = [
    {
      key: 'item',
      header: 'Supplier item',
      render: (i) => (
        <div className="min-w-0 max-w-sm">
          <p className="truncate text-secondary-900">{i.name}</p>
          <p className="font-mono text-xs text-secondary-500">
            {i.supplier_sku}
            {i.mpn ? ` · ${i.mpn}` : ''}
          </p>
        </div>
      ),
    },
    {
      key: 'cost',
      header: 'Cost (ex VAT)',
      render: (i) => (
        <div className="tabular-nums">
          <p>{formatMoney(i.cost_minor)}</p>
          {i.cost_change_pct !== null && i.cost_changed_at && (
            <p className={`text-xs ${i.cost_change_pct > 0 ? 'text-error-600' : 'text-success-600'}`}>
              {i.cost_change_pct > 0 ? '+' : ''}
              {i.cost_change_pct.toFixed(1)}% since {formatMoney(i.previous_cost_minor)}
            </p>
          )}
        </div>
      ),
    },
    {
      key: 'stock',
      header: 'Stock / lead',
      render: (i) => (
        <p className="text-sm text-secondary-600">
          {i.stock_qty !== null ? `${i.stock_qty} in stock` : i.in_stock ? 'In stock' : i.in_stock === false ? 'Out of stock' : '—'}
          {i.lead_time_days !== null ? ` · ${i.lead_time_days} days` : ''}
        </p>
      ),
    },
    {
      key: 'product',
      header: 'Shop product',
      render: (i) =>
        i.product_uuid ? (
          <div>
            <p className="truncate text-sm text-secondary-900">{i.product_name}</p>
            <p className="text-xs text-secondary-500">
              {formatMoney(i.product_price_minor)} · {i.pricing_source === 'supplier' ? 'follows supplier' : 'manual price'}
            </p>
          </div>
        ) : (
          <span className="text-sm text-secondary-400">Not linked</span>
        ),
    },
    {
      key: 'actions',
      header: '',
      render: (i) => (
        <Button size="sm" variant="ghost" onClick={() => setLinking(i)}>
          {i.product_uuid ? 'Change' : 'Link'}
        </Button>
      ),
    },
  ];

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-3">
        <div className="min-w-[200px] max-w-sm flex-1">
          <Input placeholder="SKU, MPN or name…" aria-label="Search items" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
        </div>
        <FilterSelect aria-label="Linked" value={linked} onChange={(e) => { setLinked(e.target.value as '' | 'true' | 'false'); setPage(1); }}>
          <option value="">All items</option>
          <option value="true">Linked to a product</option>
          <option value="false">Not linked</option>
        </FilterSelect>
        <label className="flex items-center gap-2 text-sm text-secondary-700">
          <input type="checkbox" checked={changed} onChange={(e) => { setChanged(e.target.checked); setPage(1); }} />
          Cost changed in the last 7 days
        </label>
      </div>
      <Table columns={columns} data={rows} keyExtractor={(i) => i.uuid} isLoading={loading} emptyMessage="No items yet — sync or upload a price file" caption={`${supplier.name} items`} />
      <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER))} totalItems={total} perPage={PER} onPageChange={setPage} />
      <LinkModal item={linking} onClose={() => setLinking(null)} onDone={() => setReload((n) => n + 1)} />
    </div>
  );
}

// ---------------------------------------------------------------------------------------- page

function SuppliersContent() {
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [editing, setEditing] = useState<ShopSupplier | undefined>(undefined);
  const [formOpen, setFormOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const fileRef = useRef<HTMLInputElement>(null);

  const load = useCallback(() => {
    shopService
      .getSuppliers()
      .then((list) => {
        setSuppliers(list);
        setSelected((cur) => cur ?? list[0]?.uuid ?? null);
      })
      .catch((err) => {
        setSuppliers([]);
        toast.error(extractApiError(err, 'Failed to load suppliers'));
      });
  }, []);
  useEffect(load, [load]);

  const after = (s: ShopSupplierSummary) => {
    toast.success(summaryLine(s), { duration: 8000 });
    load();
    setVersion((v) => v + 1);
  };

  const sync = async (s: ShopSupplier) => {
    setBusy(s.uuid);
    try {
      after(await shopService.syncSupplier(s.uuid));
    } catch (err) {
      toast.error(extractApiError(err, 'Sync failed'));
      load();
    } finally {
      setBusy(null);
    }
  };

  const upload = async (file: File | undefined) => {
    const s = suppliers?.find((x) => x.uuid === selected);
    if (!file || !s) return;
    if (file.size > 10 * 1024 * 1024) {
      toast.error('Files are limited to 10 MB — use a feed URL for bigger files');
      return;
    }
    setBusy(s.uuid);
    try {
      after(await shopService.importSupplierFile(s.uuid, file));
    } catch (err) {
      toast.error(extractApiError(err, 'Upload failed'));
      load();
    } finally {
      setBusy(null);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const current = suppliers?.find((s) => s.uuid === selected);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Suppliers"
        description="Supplier price files keep costs, stock and lead times current. Linked products can follow cost + margin."
        icon={<Truck className="h-5 w-5" />}
        actions={
          <Button
            leftIcon={<Plus className="h-4 w-4" />}
            onClick={() => {
              setEditing(undefined);
              setFormOpen(true);
            }}
          >
            Add supplier
          </Button>
        }
      />

      {suppliers === null ? (
        <ShopLoading label="Loading suppliers…" />
      ) : suppliers.length === 0 ? (
        <Card padding="lg">
          <p className="text-secondary-600">No suppliers yet. Add one with its price-file column names, then sync its feed or upload a file.</p>
        </Card>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {suppliers.map((s) => (
            <Card key={s.uuid} padding="md" className={s.uuid === selected ? 'ring-2 ring-primary-400' : undefined}>
              <button type="button" className="w-full text-left" onClick={() => setSelected(s.uuid)} aria-pressed={s.uuid === selected}>
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="font-semibold text-secondary-900">{s.name}</p>
                    <p className="text-xs uppercase text-secondary-500">
                      {s.feed_format} · {s.feed_url ? `every ${s.sync_hours} h` : 'upload only'}
                      {!s.is_active ? ' · paused' : ''}
                    </p>
                  </div>
                  <Badge variant={s.last_status === 'ok' ? 'success' : s.last_status === 'error' ? 'error' : s.last_status === 'running' ? 'warning' : 'secondary'}>
                    {s.last_status === 'ok' ? 'OK' : s.last_status === 'error' ? 'Failed' : s.last_status === 'running' ? 'Running' : 'Never synced'}
                  </Badge>
                </div>
                <p className="mt-2 text-sm text-secondary-600">
                  {s.item_counts.active} items · {s.item_counts.linked} linked · margin {s.default_margin_pct}% · ask above {s.change_threshold_pct}%
                </p>
                {s.last_synced_at && <p className="text-xs text-secondary-500">Last sync {formatDateTime(s.last_synced_at)}</p>}
                {s.last_status === 'error' && s.last_error && <p className="mt-1 text-xs text-error-600">{s.last_error}</p>}
                {s.last_status === 'ok' && s.last_summary && <p className="mt-1 text-xs text-secondary-500">{summaryLine(s.last_summary)}</p>}
              </button>
              <div className="mt-3 flex flex-wrap gap-2">
                <Button size="sm" variant="ghost" leftIcon={<Pencil className="h-3.5 w-3.5" />} onClick={() => { setEditing(s); setFormOpen(true); }}>
                  Edit
                </Button>
                {s.feed_url && (
                  <Button size="sm" variant="ghost" leftIcon={<RefreshCw className="h-3.5 w-3.5" />} onClick={() => sync(s)} isLoading={busy === s.uuid} disabled={!!busy}>
                    Sync now
                  </Button>
                )}
                <Button
                  size="sm"
                  variant="ghost"
                  leftIcon={<Upload className="h-3.5 w-3.5" />}
                  disabled={!!busy}
                  onClick={() => {
                    setSelected(s.uuid);
                    fileRef.current?.click();
                  }}
                >
                  Upload file
                </Button>
              </div>
            </Card>
          ))}
        </div>
      )}
      <input ref={fileRef} type="file" accept=".csv,.json,.xml,.txt,text/csv,application/json,application/xml,text/xml" className="hidden" onChange={(e) => upload(e.target.files?.[0])} />

      {current && (
        <Card padding="md">
          <h2 className="mb-3 text-lg font-semibold text-secondary-900">{current.name} items</h2>
          <ItemsPanel supplier={current} version={version} />
        </Card>
      )}

      <SupplierModal supplier={editing} open={formOpen} onClose={() => setFormOpen(false)} onSaved={load} />
    </div>
  );
}

export default function ShopSuppliersPage() {
  return (
    <ProtectedPage module="shop" title="Suppliers">
      <SuppliersContent />
    </ProtectedPage>
  );
}
