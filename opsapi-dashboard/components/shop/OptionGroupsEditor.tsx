'use client';

import React, { useState } from 'react';
import { ChevronDown, ChevronRight, Plus, Trash2, Boxes } from 'lucide-react';
import { Badge, Button, Input, Select } from '@/components/ui';
import { cn } from '@/lib/utils';
import { codify, formatMoney, minorToPounds, normalizeCode, poundsToMinor, typingCode } from '@/lib/shop';
import type { ShopOption, ShopOptionGroup, ShopProductListItem, ShopSelectionMode } from '@/types/shop';
import {
  CheckboxField,
  IconButton,
  JsonObjectField,
  ReorderButtons,
  moveItem,
  newKey,
  parseJsonObject,
  prettyJson,
} from './editor-fields';

// ============================================================
// Form model
// ============================================================

export interface OptionForm {
  key: string;
  uuid?: string;
  code: string;
  name: string;
  description: string;
  price_delta: string; // pounds
  stock_qty: string; // '' = untracked
  /** '' = none; '<id>' or 'uuid:<uuid>' when the API omits numeric ids. */
  component_product: string;
  max_qty: string;
  is_default: boolean;
  is_active: boolean;
  attributes: string; // JSON text
}

export interface GroupForm {
  key: string;
  uuid?: string;
  code: string;
  name: string;
  description: string;
  selection: ShopSelectionMode;
  required: boolean;
  min_qty: string;
  max_qty: string;
  options: OptionForm[];
}

export const STANDARD_GROUP_CODES = [
  'cpu',
  'gpu',
  'memory',
  'boot_drive',
  'data_drive',
  'psu',
  'network',
  'os',
  'warranty',
  'accessories',
];

export function optionToForm(o: ShopOption): OptionForm {
  return {
    key: newKey(),
    uuid: o.uuid,
    code: o.code,
    name: o.name,
    description: o.description ?? '',
    price_delta: minorToPounds(o.price_delta_minor ?? 0),
    stock_qty: o.stock_qty === null || o.stock_qty === undefined ? '' : String(o.stock_qty),
    // Backend returns the link as `component_product: {uuid, name, sku}`.
    component_product: o.component_product?.uuid
      ? `uuid:${o.component_product.uuid}`
      : o.component_product_uuid
        ? `uuid:${o.component_product_uuid}`
        : o.component_product_id
          ? String(o.component_product_id)
          : '',
    max_qty: String(o.max_qty ?? 1),
    is_default: !!o.is_default,
    is_active: o.is_active !== false,
    attributes: prettyJson(o.attributes),
  };
}

export function groupToForm(g: ShopOptionGroup): GroupForm {
  return {
    key: newKey(),
    uuid: g.uuid,
    code: g.code,
    name: g.name,
    description: g.description ?? '',
    selection: g.selection === 'multi' ? 'multi' : 'single',
    required: !!g.required,
    min_qty: String(g.min_qty ?? 0),
    max_qty: String(g.max_qty ?? 1),
    options: [...(g.options ?? [])].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0)).map(optionToForm),
  };
}

const emptyOption = (): OptionForm => ({
  key: newKey(),
  code: '',
  name: '',
  description: '',
  price_delta: '0.00',
  stock_qty: '',
  component_product: '',
  max_qty: '1',
  is_default: false,
  is_active: true,
  attributes: '',
});

const emptyGroup = (): GroupForm => ({
  key: newKey(),
  code: '',
  name: '',
  description: '',
  selection: 'single',
  required: false,
  min_qty: '0',
  max_qty: '1',
  options: [],
});

const componentValue = (p: Pick<ShopProductListItem, 'id' | 'uuid'>): string =>
  p.id !== undefined && p.id !== null ? String(p.id) : `uuid:${p.uuid}`;

const toInt = (s: string, fallback: number): number => {
  const n = parseInt(s, 10);
  return Number.isFinite(n) ? n : fallback;
};

/** Validate + convert to the API document. Returns errors (empty when OK). */
export function groupsToPayload(groups: GroupForm[]): { groups: Omit<ShopOptionGroup, 'id' | 'uuid'>[]; errors: string[] } {
  const errors: string[] = [];
  const groupCodes = new Set<string>();
  const out = groups.map((g, gi) => {
    const gLabel = g.name || g.code || `Group ${gi + 1}`;
    if (!g.code.trim()) errors.push(`${gLabel}: code is required`);
    if (!g.name.trim()) errors.push(`${gLabel}: name is required`);
    if (groupCodes.has(g.code.trim())) errors.push(`Duplicate group code "${g.code}"`);
    groupCodes.add(g.code.trim());
    const optCodes = new Set<string>();
    const options = g.options.map((o, oi) => {
      const oLabel = `${gLabel} › ${o.name || o.code || `option ${oi + 1}`}`;
      if (!o.code.trim()) errors.push(`${oLabel}: code is required`);
      if (!o.name.trim()) errors.push(`${oLabel}: name is required`);
      if (optCodes.has(o.code.trim())) errors.push(`${gLabel}: duplicate option code "${o.code}"`);
      optCodes.add(o.code.trim());
      const delta = poundsToMinor(o.price_delta);
      if (delta === null && o.price_delta.trim() !== '') errors.push(`${oLabel}: invalid price delta`);
      const [attrs, attrErr] = parseJsonObject(o.attributes);
      if (attrErr) errors.push(`${oLabel}: attributes — ${attrErr}`);
      const stock = o.stock_qty.trim() === '' ? null : toInt(o.stock_qty, 0);
      return {
        ...(o.uuid ? { uuid: o.uuid } : {}),
        code: o.code.trim(),
        name: o.name.trim(),
        description: o.description.trim() || null,
        price_delta_minor: delta ?? 0,
        component_product_id:
          o.component_product && !o.component_product.startsWith('uuid:') ? Number(o.component_product) : null,
        component_product_uuid: o.component_product.startsWith('uuid:') ? o.component_product.slice(5) : null,
        stock_qty: o.component_product ? null : stock,
        max_qty: Math.max(1, toInt(o.max_qty, 1)),
        is_default: o.is_default,
        is_active: o.is_active,
        sort_order: oi,
        attributes: attrs ?? {},
      } as ShopOption;
    });
    if (g.selection === 'single' && g.options.filter((o) => o.is_default && o.is_active).length > 1) {
      errors.push(`${gLabel}: single-select group can only have one default option`);
    }
    const min = toInt(g.min_qty, 0);
    const max = toInt(g.max_qty, 1);
    if (max < min) errors.push(`${gLabel}: max qty must be ≥ min qty`);
    return {
      code: g.code.trim(),
      name: g.name.trim(),
      description: g.description.trim() || null,
      selection: g.selection,
      required: g.required,
      min_qty: min,
      max_qty: max,
      sort_order: gi,
      options,
    };
  });
  return { groups: out, errors };
}

// ============================================================
// Editor
// ============================================================

export function OptionGroupsEditor({
  groups,
  onChange,
  componentProducts,
}: {
  groups: GroupForm[];
  onChange: (g: GroupForm[]) => void;
  /** Products that can back an option's stock (component_product_id). */
  componentProducts: ShopProductListItem[];
}) {
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  const updateGroup = (i: number, patch: Partial<GroupForm>) => onChange(groups.map((g, j) => (j === i ? { ...g, ...patch } : g)));
  const updateOption = (gi: number, oi: number, patch: Partial<OptionForm>) =>
    updateGroup(gi, { options: groups[gi].options.map((o, j) => (j === oi ? { ...o, ...patch } : o)) });

  const setDefault = (gi: number, oi: number, v: boolean) => {
    const g = groups[gi];
    updateGroup(gi, {
      options: g.options.map((o, j) =>
        j === oi ? { ...o, is_default: v } : g.selection === 'single' && v ? { ...o, is_default: false } : o
      ),
    });
  };

  return (
    <div className="space-y-4">
      {groups.length === 0 && (
        <div className="rounded-lg border border-dashed border-secondary-300 p-6 text-center text-sm text-secondary-500">
          No option groups. Configurable products need at least one group (e.g. cpu, gpu, memory, psu).
        </div>
      )}

      {groups.map((g, gi) => {
        const isCollapsed = collapsed[g.key];
        return (
          <div key={g.key} className="rounded-xl border border-secondary-200 bg-surface">
            {/* Group header */}
            <div className="flex items-center gap-2 border-b border-secondary-200 bg-secondary-50 px-4 py-2.5 rounded-t-xl">
              <IconButton label={isCollapsed ? 'Expand group' : 'Collapse group'} onClick={() => setCollapsed((c) => ({ ...c, [g.key]: !c[g.key] }))}>
                {isCollapsed ? <ChevronRight className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
              </IconButton>
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium text-secondary-900">
                  {g.name || <span className="text-secondary-400">Untitled group</span>}
                  {g.code && <span className="ml-2 font-mono text-xs text-secondary-500">{g.code}</span>}
                </p>
              </div>
              <Badge size="sm" variant="default">{g.options.length} options</Badge>
              {g.required && <Badge size="sm" variant="info">Required</Badge>}
              <ReorderButtons index={gi} count={groups.length} onMove={(d) => onChange(moveItem(groups, gi, d))} />
              <IconButton label="Remove group" danger onClick={() => onChange(groups.filter((_, j) => j !== gi))}>
                <Trash2 className="h-4 w-4" />
              </IconButton>
            </div>

            {!isCollapsed && (
              <div className="space-y-4 p-4">
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  <Input
                    label="Name"
                    id={`g-${g.key}-name`}
                    value={g.name}
                    onChange={(e) => updateGroup(gi, { name: e.target.value })}
                    onBlur={() => !g.code && g.name && updateGroup(gi, { code: codify(g.name) })}
                  />
                  <div>
                    <Input
                      label="Code"
                      id={`g-${g.key}-code`}
                      value={g.code}
                      onChange={(e) => updateGroup(gi, { code: typingCode(e.target.value) })}
                      onBlur={() => g.code && updateGroup(gi, { code: normalizeCode(g.code) })}
                      list="shop-group-codes"
                      className="font-mono"
                    />
                  </div>
                  <Select
                    label="Selection"
                    id={`g-${g.key}-sel`}
                    value={g.selection}
                    onChange={(e) => updateGroup(gi, { selection: e.target.value as ShopSelectionMode })}
                  >
                    <option value="single">Single (radio)</option>
                    <option value="multi">Multi (qty steppers)</option>
                  </Select>
                  <div className="grid grid-cols-2 gap-2">
                    <Input label="Min qty" id={`g-${g.key}-min`} value={g.min_qty} onChange={(e) => updateGroup(gi, { min_qty: e.target.value })} inputMode="numeric" />
                    <Input label="Max qty" id={`g-${g.key}-max`} value={g.max_qty} onChange={(e) => updateGroup(gi, { max_qty: e.target.value })} inputMode="numeric" />
                  </div>
                </div>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
                  <Input label="Description" id={`g-${g.key}-desc`} value={g.description} onChange={(e) => updateGroup(gi, { description: e.target.value })} />
                  <div className="pb-2.5">
                    <CheckboxField label="Required" checked={g.required} onChange={(v) => updateGroup(gi, { required: v })} />
                  </div>
                </div>

                {/* Options */}
                <div className="space-y-3">
                  {g.options.map((o, oi) => (
                    <OptionRow
                      key={o.key}
                      option={o}
                      index={oi}
                      count={g.options.length}
                      componentProducts={componentProducts}
                      onChange={(patch) => updateOption(gi, oi, patch)}
                      onDefault={(v) => setDefault(gi, oi, v)}
                      onMove={(d) => updateGroup(gi, { options: moveItem(g.options, oi, d) })}
                      onRemove={() => updateGroup(gi, { options: g.options.filter((_, j) => j !== oi) })}
                    />
                  ))}
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    leftIcon={<Plus className="h-4 w-4" />}
                    onClick={() => updateGroup(gi, { options: [...g.options, emptyOption()] })}
                  >
                    Add option
                  </Button>
                </div>
              </div>
            )}
          </div>
        );
      })}

      <datalist id="shop-group-codes">
        {STANDARD_GROUP_CODES.map((c) => (
          <option key={c} value={c} />
        ))}
      </datalist>

      <Button type="button" variant="outline" size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => onChange([...groups, emptyGroup()])}>
        Add option group
      </Button>
    </div>
  );
}

function OptionRow({
  option: o,
  index,
  count,
  componentProducts,
  onChange,
  onDefault,
  onMove,
  onRemove,
}: {
  option: OptionForm;
  index: number;
  count: number;
  componentProducts: ShopProductListItem[];
  onChange: (patch: Partial<OptionForm>) => void;
  onDefault: (v: boolean) => void;
  onMove: (d: -1 | 1) => void;
  onRemove: () => void;
}) {
  const [showMore, setShowMore] = useState(false);
  const delta = poundsToMinor(o.price_delta);
  const [, attrErr] = parseJsonObject(o.attributes);
  const component = componentProducts.find((p) => componentValue(p) === o.component_product);
  return (
    <div className={cn('rounded-lg border p-3', o.is_active ? 'border-secondary-200' : 'border-dashed border-secondary-300 opacity-70')}>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-12 md:items-end">
        <div className="md:col-span-3">
          <Input
            label="Option name"
            id={`o-${o.key}-name`}
            value={o.name}
            onChange={(e) => onChange({ name: e.target.value })}
            onBlur={() => !o.code && o.name && onChange({ code: codify(o.name) })}
          />
        </div>
        <div className="md:col-span-2">
          <Input label="Code" id={`o-${o.key}-code`} value={o.code} onChange={(e) => onChange({ code: typingCode(e.target.value) })}
            onBlur={() => o.code && onChange({ code: normalizeCode(o.code) })} className="font-mono" />
        </div>
        <div className="md:col-span-2">
          <Input
            label="Price Δ (£ ex VAT)"
            id={`o-${o.key}-price`}
            value={o.price_delta}
            onChange={(e) => onChange({ price_delta: e.target.value })}
            onBlur={() => delta !== null && onChange({ price_delta: minorToPounds(delta) })}
            inputMode="decimal"
            error={delta === null && o.price_delta.trim() !== '' ? 'Invalid' : undefined}
          />
        </div>
        <div className="md:col-span-2">
          <Input
            label="Stock"
            id={`o-${o.key}-stock`}
            value={component ? '' : o.stock_qty}
            onChange={(e) => onChange({ stock_qty: e.target.value.replace(/[^\d-]/g, '') })}
            inputMode="numeric"
            placeholder={component ? 'from component' : 'untracked'}
            disabled={!!component}
          />
        </div>
        <div className="md:col-span-1">
          <Input label="Max qty" id={`o-${o.key}-maxq`} value={o.max_qty} onChange={(e) => onChange({ max_qty: e.target.value })} inputMode="numeric" />
        </div>
        <div className="flex items-center justify-end gap-0.5 md:col-span-2 md:pb-1.5">
          <ReorderButtons index={index} count={count} onMove={onMove} />
          <IconButton label="Remove option" danger onClick={onRemove}>
            <Trash2 className="h-4 w-4" />
          </IconButton>
        </div>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2">
        <CheckboxField label="Default" checked={o.is_default} onChange={onDefault} />
        <CheckboxField label="Active" checked={o.is_active} onChange={(v) => onChange({ is_active: v })} />
        {delta !== null && delta !== 0 && (
          <span className="text-xs text-secondary-500">
            {delta > 0 ? '+' : ''}
            {formatMoney(delta)} ex VAT
          </span>
        )}
        {component && (
          <span className="inline-flex items-center gap-1 text-xs text-secondary-500">
            <Boxes className="h-3.5 w-3.5" /> Stock from {component.name}
          </span>
        )}
        {attrErr && <span className="text-xs text-error-600">Attributes JSON invalid</span>}
        <button type="button" onClick={() => setShowMore((s) => !s)} className="ml-auto text-xs font-medium text-primary-600 hover:underline">
          {showMore ? 'Hide details' : 'Description, attributes, component…'}
        </button>
      </div>

      {showMore && (
        <div className="mt-3 grid grid-cols-1 gap-3 border-t border-secondary-100 pt-3 md:grid-cols-2">
          <div className="space-y-3">
            <Input label="Description" id={`o-${o.key}-desc`} value={o.description} onChange={(e) => onChange({ description: e.target.value })} />
            <Select
              label="Component product (stock source)"
              id={`o-${o.key}-comp`}
              value={o.component_product}
              onChange={(e) => onChange({ component_product: e.target.value })}
              helperText="When set, stock is taken from that product instead of this option."
            >
              <option value="">— None —</option>
              {componentProducts.map((p) => (
                <option key={p.uuid} value={componentValue(p)}>
                  {p.name} ({p.sku})
                </option>
              ))}
            </Select>
          </div>
          <JsonObjectField
            label="Attributes (JSON)"
            value={o.attributes}
            onChange={(v) => onChange({ attributes: v })}
            rows={5}
            placeholder={'{\n  "watts": 600,\n  "slots": 2,\n  "vram_gb": 96\n}'}
            helperText="Used by rules: watts, slots, psu_watts, memory_type, capacity_gb, socket…"
          />
        </div>
      )}
    </div>
  );
}
