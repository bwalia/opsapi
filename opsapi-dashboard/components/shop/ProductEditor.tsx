'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft, Archive, History, Package, Save, SlidersHorizontal, AlertTriangle, ExternalLink } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, ConfirmDialog, Input, Select, Textarea, Switch } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { estimateFromPrice, formatMoney, humanize, incVat, minorToPounds, poundsToMinor, slugify, typingSlug } from '@/lib/shop';
import {
  SHOP_PRICE_MODES,
  SHOP_PRODUCT_STATUSES,
  SHOP_PRODUCT_TYPES,
  type ShopCategory,
  type ShopPriceMode,
  type ShopProduct,
  type ShopProductInput,
  type ShopProductListItem,
  type ShopProductStatus,
  type ShopProductType,
} from '@/types/shop';
import {
  CheckboxField,
  ImageListEditor,
  JsonObjectField,
  KeyValueEditor,
  kvFromObject,
  kvToObject,
  parseJsonObject,
  prettyJson,
  type KvRow,
} from './editor-fields';
import { OptionGroupsEditor, groupToForm, groupsToPayload, type GroupForm } from './OptionGroupsEditor';
import { RulesEditor, ruleToForm, rulesToPayload, type RuleForm } from './RulesEditor';
import { MovementsDrawer, PriceVerifiedBadge, ProductStatusBadge, SHOP_MODULE, StockAdjustModal, type StockTarget } from './shared';

interface BasicsForm {
  name: string;
  slug: string;
  sku: string;
  brand: string;
  product_type: ShopProductType;
  price_mode: ShopPriceMode;
  status: ShopProductStatus;
  category: string; // uuid
  short_description: string;
  description: string;
  tags: string; // comma separated
  base_price: string; // pounds
  vat_rate: string; // percent
  stock_qty: string; // only used on create
  low_stock_threshold: string;
  lead_time_days: string;
  allow_backorder: boolean;
  price_verified: boolean;
  is_featured: boolean;
  sort_order: string;
}

function toBasics(p?: ShopProduct): BasicsForm {
  return {
    name: p?.name ?? '',
    slug: p?.slug ?? '',
    sku: p?.sku ?? '',
    brand: p?.brand ?? '',
    product_type: p?.product_type ?? 'workstation',
    price_mode: p?.price_mode ?? 'fixed',
    status: p?.status ?? 'draft',
    category: p?.category?.uuid ?? p?.category_uuid ?? '',
    short_description: p?.short_description ?? '',
    description: p?.description ?? '',
    tags: (p?.tags ?? []).join(', '),
    base_price: minorToPounds(p?.base_price_minor ?? 0),
    vat_rate: String(Math.round(((p?.vat_rate ?? 0.2) * 100) * 100) / 100),
    stock_qty: String(p?.stock_qty ?? 0),
    low_stock_threshold: String(p?.low_stock_threshold ?? 2),
    lead_time_days: String(p?.lead_time_days ?? 10),
    allow_backorder: p?.allow_backorder ?? true,
    price_verified: p?.price_verified ?? false,
    is_featured: p?.is_featured ?? false,
    sort_order: String(p?.sort_order ?? 0),
  };
}

const intOr = (s: string, d: number) => {
  const n = parseInt(s, 10);
  return Number.isFinite(n) ? n : d;
};

export function ProductEditor({ product, onReload }: { product?: ShopProduct; onReload?: () => void }) {
  const router = useRouter();
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const isNew = !product;
  const canSave = isNew ? canCreate(SHOP_MODULE) : canUpdate(SHOP_MODULE);

  const [basics, setBasics] = useState<BasicsForm>(() => toBasics(product));
  const [slugTouched, setSlugTouched] = useState(!!product);
  const [specs, setSpecs] = useState<KvRow[]>(() => kvFromObject(product?.specs));
  const [attributes, setAttributes] = useState<string>(() => prettyJson(product?.attributes));
  const [images, setImages] = useState<string[]>(() => product?.images ?? []);
  const [groups, setGroups] = useState<GroupForm[]>(() =>
    [...(product?.option_groups ?? [])].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0)).map(groupToForm)
  );
  const [rules, setRules] = useState<RuleForm[]>(() => (product?.rules ?? []).map(ruleToForm));
  const [categories, setCategories] = useState<ShopCategory[]>([]);
  const [componentProducts, setComponentProducts] = useState<ShopProductListItem[]>([]);
  const [saving, setSaving] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const [archiveOpen, setArchiveOpen] = useState(false);
  const [archiving, setArchiving] = useState(false);
  const [stockTarget, setStockTarget] = useState<StockTarget | null>(null);
  const [historyTarget, setHistoryTarget] = useState<StockTarget | null>(null);

  // Reset when a different product document is loaded (e.g. after save/reload).
  useEffect(() => {
    if (!product) return;
    setBasics(toBasics(product));
    setSpecs(kvFromObject(product.specs));
    setAttributes(prettyJson(product.attributes));
    setImages(product.images ?? []);
    setGroups([...(product.option_groups ?? [])].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0)).map(groupToForm));
    setRules((product.rules ?? []).map(ruleToForm));
  }, [product]);

  useEffect(() => {
    let active = true;
    shopService
      .getCategories()
      .then((c) => active && setCategories(c))
      .catch(() => active && toast.error('Failed to load categories'));
    shopService
      .getProducts({ limit: 500 })
      .then((r) => active && setComponentProducts(r.data.filter((p) => p.uuid !== product?.uuid && p.price_mode !== 'configurable')))
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [product?.uuid]);

  const set = <K extends keyof BasicsForm>(k: K, v: BasicsForm[K]) => setBasics((b) => ({ ...b, [k]: v }));

  const basePriceMinor = poundsToMinor(basics.base_price);
  const vatRate = (() => {
    const n = Number(basics.vat_rate);
    return Number.isFinite(n) ? n / 100 : 0.2;
  })();
  const [, attrError] = parseJsonObject(attributes);

  const fromPreview = useMemo(() => {
    const { groups: g } = groupsToPayload(groups);
    return estimateFromPrice(basePriceMinor ?? 0, g);
  }, [groups, basePriceMinor]);

  const buildPayload = (): { payload: ShopProductInput | null; errs: string[] } => {
    const errs: string[] = [];
    if (!basics.name.trim()) errs.push('Name is required');
    if (!basics.sku.trim()) errs.push('SKU is required');
    const slug = basics.slug.trim() || slugify(basics.name);
    if (!slug) errs.push('Slug is required');
    if (basePriceMinor === null || basePriceMinor < 0) errs.push('Base price must be a valid amount ≥ 0');
    const vat = Number(basics.vat_rate);
    if (!Number.isFinite(vat) || vat < 0 || vat > 100) errs.push('VAT rate must be between 0 and 100%');
    const [attrs, aErr] = parseJsonObject(attributes);
    if (aErr) errs.push(`Attributes: ${aErr}`);
    const specKeys = specs.map((s) => s.k.trim()).filter(Boolean);
    if (new Set(specKeys).size !== specKeys.length) errs.push('Specs: duplicate labels');
    const badImg = images.some((u) => u.trim() && !/^(https?:\/\/|\/)/i.test(u.trim()));
    if (badImg) errs.push('Images: every entry must be an http(s) URL or /path');
    const g = groupsToPayload(groups);
    const r = rulesToPayload(rules, groups);
    errs.push(...g.errors, ...r.errors);
    if (basics.price_mode === 'configurable' && g.groups.length === 0) errs.push('Configurable products need at least one option group');
    if (errs.length) return { payload: null, errs };

    const category = categories.find((c) => c.uuid === basics.category);
    const payload: ShopProductInput = {
      name: basics.name.trim(),
      slug,
      sku: basics.sku.trim(),
      brand: basics.brand.trim() || undefined,
      product_type: basics.product_type,
      price_mode: basics.price_mode,
      status: basics.status,
      category_uuid: basics.category || null,
      category_id: category?.id ?? null,
      short_description: basics.short_description.trim(),
      description: basics.description,
      tags: basics.tags.split(',').map((t) => t.trim()).filter(Boolean),
      base_price_minor: basePriceMinor ?? 0,
      currency: 'GBP',
      vat_rate: Math.round(vat * 100) / 10000,
      low_stock_threshold: Math.max(0, intOr(basics.low_stock_threshold, 2)),
      lead_time_days: Math.max(0, intOr(basics.lead_time_days, 10)),
      allow_backorder: basics.allow_backorder,
      price_verified: basics.price_verified,
      is_featured: basics.is_featured,
      sort_order: intOr(basics.sort_order, 0),
      specs: kvToObject(specs),
      attributes: attrs ?? {},
      images: images.map((u) => u.trim()).filter(Boolean),
      option_groups: g.groups,
      rules: r.rules,
    };
    // Stock on existing products is changed via the audited stock endpoint only.
    if (isNew) payload.stock_qty = Math.max(0, intOr(basics.stock_qty, 0));
    return { payload, errs };
  };

  const save = async () => {
    const { payload, errs } = buildPayload();
    setErrors(errs);
    if (!payload) {
      toast.error(`Fix ${errs.length} problem${errs.length === 1 ? '' : 's'} before saving`);
      return;
    }
    setSaving(true);
    try {
      if (isNew) {
        const created = await shopService.createProduct(payload);
        toast.success('Product created');
        router.push(created?.uuid ? `/dashboard/shop/products/${created.uuid}` : '/dashboard/shop/products');
      } else {
        await shopService.updateProduct(product.uuid, payload);
        toast.success('Product saved');
        onReload?.();
      }
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to save product'));
    } finally {
      setSaving(false);
    }
  };

  const archive = async () => {
    if (!product) return;
    setArchiving(true);
    try {
      const res = await shopService.deleteProduct(product.uuid);
      toast.success(res?.archived ? 'Product archived (it is referenced by orders/quotes)' : 'Product deleted');
      router.push('/dashboard/shop/products');
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to delete product'));
    } finally {
      setArchiving(false);
      setArchiveOpen(false);
    }
  };

  const productTarget: StockTarget | null = product
    ? { kind: 'product', uuid: product.uuid, label: `${product.name} (${product.sku})`, current: product.stock_qty ?? 0 }
    : null;

  return (
    <div className="space-y-6 pb-24">
      <PageHeader
        title={isNew ? 'New product' : product.name}
        description={isNew ? 'Add a product to the shop catalogue' : `SKU ${product.sku} · /p/${product.slug}`}
        icon={<Package className="h-5 w-5" />}
        actions={
          <>
            <Link href="/dashboard/shop/products">
              <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Products</Button>
            </Link>
            {!isNew && canDelete(SHOP_MODULE) && (
              <Button variant="ghost" leftIcon={<Archive className="h-4 w-4" />} onClick={() => setArchiveOpen(true)}>
                Delete / archive
              </Button>
            )}
            {canSave && (
              <Button leftIcon={<Save className="h-4 w-4" />} onClick={save} isLoading={saving}>
                {isNew ? 'Create' : 'Save'}
              </Button>
            )}
          </>
        }
      />

      {!isNew && (
        <div className="flex flex-wrap items-center gap-2">
          <ProductStatusBadge status={product.status} />
          <PriceVerifiedBadge verified={product.price_verified} />
          {product.has_embedding === false && <span className="text-xs text-secondary-500">Not indexed for AI search yet</span>}
        </div>
      )}

      {errors.length > 0 && (
        <div className="rounded-xl border border-error-200 bg-error-50 p-4" role="alert">
          <p className="mb-2 flex items-center gap-2 text-sm font-semibold text-error-700">
            <AlertTriangle className="h-4 w-4" /> Please fix the following
          </p>
          <ul className="list-disc space-y-0.5 pl-6 text-sm text-error-700">
            {errors.map((e, i) => (
              <li key={i}>{e}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        {/* Left column */}
        <div className="space-y-6 xl:col-span-2">
          <Card>
            <h2 className="mb-4 text-base font-semibold text-secondary-900">Basics</h2>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Input
                label="Name *"
                id="p-name"
                value={basics.name}
                onChange={(e) => {
                  const name = e.target.value;
                  setBasics((b) => ({ ...b, name, slug: slugTouched ? b.slug : slugify(name) }));
                }}
              />
              <Input
                label="Slug *"
                id="p-slug"
                value={basics.slug}
                onChange={(e) => {
                  setSlugTouched(true);
                  set('slug', typingSlug(e.target.value));
                }}
                onBlur={() => basics.slug && set('slug', slugify(basics.slug))}
                className="font-mono"
                helperText="Shop URL: /p/<slug>"
              />
              <Input label="SKU *" id="p-sku" value={basics.sku} onChange={(e) => set('sku', e.target.value.toUpperCase())} className="font-mono" />
              <Input label="Brand" id="p-brand" value={basics.brand} onChange={(e) => set('brand', e.target.value)} />
              <Select label="Category" id="p-cat" value={basics.category} onChange={(e) => set('category', e.target.value)}>
                <option value="">— Uncategorised —</option>
                {categories.map((c) => (
                  <option key={c.uuid} value={c.uuid}>{c.name}</option>
                ))}
              </Select>
              <Select label="Product type" id="p-type" value={basics.product_type} onChange={(e) => set('product_type', e.target.value as ShopProductType)}>
                {SHOP_PRODUCT_TYPES.map((t) => (
                  <option key={t} value={t}>{humanize(t)}</option>
                ))}
              </Select>
              <Select label="Status" id="p-status" value={basics.status} onChange={(e) => set('status', e.target.value as ShopProductStatus)}>
                {SHOP_PRODUCT_STATUSES.map((t) => (
                  <option key={t} value={t}>{humanize(t)}</option>
                ))}
              </Select>
              <Input label="Tags" id="p-tags" value={basics.tags} onChange={(e) => set('tags', e.target.value)} helperText="Comma separated" />
            </div>
            <div className="mt-4 space-y-4">
              <Input label="Short description" id="p-short" value={basics.short_description} onChange={(e) => set('short_description', e.target.value)} />
              <Textarea label="Description (Markdown)" id="p-desc" value={basics.description} onChange={(e) => set('description', e.target.value)} rows={8} className="font-mono text-xs" />
            </div>
          </Card>

          <Card>
            <h2 className="mb-1 text-base font-semibold text-secondary-900">Specs</h2>
            <p className="mb-4 text-sm text-secondary-500">Human-readable spec table shown on the product page. Only state published manufacturer facts.</p>
            <KeyValueEditor rows={specs} onChange={setSpecs} keyPlaceholder="Label (e.g. GPU)" valuePlaceholder="Value (e.g. 4× RTX PRO 6000 Blackwell)" />
          </Card>

          <Card>
            <h2 className="mb-1 text-base font-semibold text-secondary-900">Attributes</h2>
            <p className="mb-4 text-sm text-secondary-500">Machine-readable JSON used by the pricing engine and AI agent (rules reference these keys).</p>
            <JsonObjectField
              label="Attributes JSON"
              value={attributes}
              onChange={setAttributes}
              rows={8}
              helperText='e.g. {"gpu_slots":4,"psu_watts":2000,"socket":"sTR5","max_memory_gb":2048,"form_factor":"tower","memory_type":"DDR5-RDIMM"}'
            />
          </Card>

          <Card>
            <h2 className="mb-4 text-base font-semibold text-secondary-900">Images</h2>
            <ImageListEditor urls={images} onChange={setImages} />
          </Card>

          <Card>
            <div className="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 className="flex items-center gap-2 text-base font-semibold text-secondary-900">
                  <SlidersHorizontal className="h-4 w-4 text-primary-500" /> Option groups & options
                </h2>
                <p className="text-sm text-secondary-500">
                  Saved as one document: groups/options are upserted by code and missing ones deactivated.
                </p>
              </div>
            </div>
            {basics.price_mode !== 'configurable' && groups.length === 0 ? (
              <p className="text-sm text-secondary-500">
                Option groups are used by <strong>configurable</strong> products. Change the price mode to configure options.
              </p>
            ) : (
              <OptionGroupsEditor groups={groups} onChange={setGroups} componentProducts={componentProducts} />
            )}
          </Card>

          <Card>
            <h2 className="mb-1 text-base font-semibold text-secondary-900">Compatibility rules</h2>
            <p className="mb-4 text-sm text-secondary-500">Evaluated server-side by the pricing engine on every configuration.</p>
            <RulesEditor rules={rules} onChange={setRules} groups={groups} />
          </Card>
        </div>

        {/* Right column */}
        <div className="space-y-6">
          <Card>
            <h2 className="mb-4 text-base font-semibold text-secondary-900">Pricing</h2>
            <div className="space-y-4">
              <Select label="Price mode" id="p-mode" value={basics.price_mode} onChange={(e) => set('price_mode', e.target.value as ShopPriceMode)}>
                {SHOP_PRICE_MODES.map((m) => (
                  <option key={m} value={m}>{humanize(m)}</option>
                ))}
              </Select>
              <Input
                label="Base price (£ ex VAT)"
                id="p-price"
                value={basics.base_price}
                onChange={(e) => set('base_price', e.target.value)}
                onBlur={() => basePriceMinor !== null && set('base_price', minorToPounds(basePriceMinor))}
                inputMode="decimal"
                leftIcon={<span className="text-sm">£</span>}
                error={basePriceMinor === null ? 'Enter an amount, e.g. 1299.00' : undefined}
                helperText={basePriceMinor !== null ? `${formatMoney(incVat(basePriceMinor, vatRate))} inc VAT` : undefined}
              />
              <Input label="VAT rate (%)" id="p-vat" value={basics.vat_rate} onChange={(e) => set('vat_rate', e.target.value)} inputMode="decimal" />
              <div className="flex items-center justify-between gap-3 rounded-lg border border-secondary-200 px-3 py-2.5">
                <div>
                  <p className="text-sm font-medium text-secondary-800">Price verified</p>
                  <p className="text-xs text-secondary-500">Off = indicative; the AI flags it “confirmed on quote”.</p>
                </div>
                <Switch checked={basics.price_verified} onChange={(v) => set('price_verified', v)} aria-label="Price verified" />
              </div>
              {basics.price_mode === 'configurable' && (
                <div className="rounded-lg bg-secondary-50 p-3 text-sm">
                  <p className="text-secondary-500">From-price preview (cheapest valid options)</p>
                  <p className="text-lg font-semibold tabular-nums text-secondary-900">{formatMoney(fromPreview)}</p>
                  <p className="text-xs tabular-nums text-secondary-500">{formatMoney(incVat(fromPreview, vatRate))} inc VAT</p>
                  {product?.from_price_minor !== undefined && (
                    <p className="mt-1 text-xs text-secondary-500">Server (last saved): {formatMoney(product.from_price_minor)}</p>
                  )}
                </div>
              )}
              {basics.price_mode === 'quote_only' && (
                <p className="text-xs text-secondary-500">Quote-only products can be added to a cart but force a quote instead of checkout.</p>
              )}
            </div>
          </Card>

          <Card>
            <h2 className="mb-4 text-base font-semibold text-secondary-900">Stock</h2>
            <div className="space-y-4">
              {isNew ? (
                <Input label="Initial stock qty" id="p-stock" value={basics.stock_qty} onChange={(e) => set('stock_qty', e.target.value)} inputMode="numeric" />
              ) : (
                <div className="rounded-lg bg-secondary-50 p-3">
                  <div className="grid grid-cols-3 gap-2 text-center">
                    <div>
                      <p className="text-xs text-secondary-500">On hand</p>
                      <p className="text-lg font-semibold tabular-nums">{product.stock_qty}</p>
                    </div>
                    <div>
                      <p className="text-xs text-secondary-500">Held</p>
                      <p className="text-lg font-semibold tabular-nums">{product.held ?? 0}</p>
                    </div>
                    <div>
                      <p className="text-xs text-secondary-500">Available</p>
                      <p className="text-lg font-semibold tabular-nums">{product.available ?? product.availability?.qty_available ?? product.stock_qty - (product.held ?? 0)}</p>
                    </div>
                  </div>
                  <div className="mt-3 flex gap-2">
                    {canUpdate(SHOP_MODULE) && (
                      <Button size="sm" variant="outline" onClick={() => setStockTarget(productTarget)}>
                        Adjust stock
                      </Button>
                    )}
                    <Button size="sm" variant="ghost" leftIcon={<History className="h-4 w-4" />} onClick={() => setHistoryTarget(productTarget)}>
                      History
                    </Button>
                  </div>
                </div>
              )}
              <div className="grid grid-cols-2 gap-3">
                <Input label="Low-stock at" id="p-low" value={basics.low_stock_threshold} onChange={(e) => set('low_stock_threshold', e.target.value)} inputMode="numeric" />
                <Input label="Lead time (days)" id="p-lead" value={basics.lead_time_days} onChange={(e) => set('lead_time_days', e.target.value)} inputMode="numeric" />
              </div>
              <CheckboxField
                label="Allow backorder"
                description="Orderable when out of stock; shows the lead time."
                checked={basics.allow_backorder}
                onChange={(v) => set('allow_backorder', v)}
              />
            </div>
          </Card>

          <Card>
            <h2 className="mb-4 text-base font-semibold text-secondary-900">Merchandising</h2>
            <div className="space-y-4">
              <CheckboxField label="Featured" description="Shown on the shop home page." checked={basics.is_featured} onChange={(v) => set('is_featured', v)} />
              <Input label="Sort order" id="p-sort" value={basics.sort_order} onChange={(e) => set('sort_order', e.target.value)} inputMode="numeric" />
              {attrError && <p className="text-xs text-error-600">Attributes JSON is invalid.</p>}
              {!isNew && product.status === 'active' && (
                <p className="flex items-center gap-1 text-xs text-secondary-500">
                  <ExternalLink className="h-3.5 w-3.5" /> Live at /p/{product.slug}
                </p>
              )}
            </div>
          </Card>
        </div>
      </div>

      {/* Sticky save bar */}
      {canSave && (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t border-secondary-200 bg-surface/95 px-4 py-3 backdrop-blur lg:left-auto lg:right-0 lg:w-auto lg:rounded-tl-xl lg:border-l print:hidden">
          <div className="flex items-center justify-end gap-3">
            <span className="hidden text-sm text-secondary-500 sm:inline">
              {groups.length} groups · {groups.reduce((s, g) => s + g.options.length, 0)} options · {rules.length} rules
            </span>
            <Button leftIcon={<Save className="h-4 w-4" />} onClick={save} isLoading={saving}>
              {isNew ? 'Create product' : 'Save changes'}
            </Button>
          </div>
        </div>
      )}

      <ConfirmDialog
        isOpen={archiveOpen}
        onClose={() => setArchiveOpen(false)}
        onConfirm={archive}
        title="Delete product"
        message="Products referenced by carts, quotes or orders are archived instead of deleted. Continue?"
        confirmText="Delete / archive"
        variant="danger"
        isLoading={archiving}
      />
      <StockAdjustModal target={stockTarget} onClose={() => setStockTarget(null)} onDone={() => onReload?.()} />
      <MovementsDrawer target={historyTarget} onClose={() => setHistoryTarget(null)} />
    </div>
  );
}

export default ProductEditor;
