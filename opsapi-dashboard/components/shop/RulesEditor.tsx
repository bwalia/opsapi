'use client';

import React from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { Badge, Button, Input, Select } from '@/components/ui';
import { cn } from '@/lib/utils';
import { SHOP_RULE_KINDS, type ShopRule, type ShopRuleKind } from '@/types/shop';
import { CheckboxField, IconButton, ReorderButtons, moveItem, newKey } from './editor-fields';
import type { GroupForm } from './OptionGroupsEditor';

type Params = Record<string, unknown>;

export interface RuleForm {
  key: string;
  /** Existing rule uuid — sent back so the server updates in place instead of insert + deactivate. */
  uuid?: string;
  kind: ShopRuleKind;
  params: Params;
  message: string;
  is_active: boolean;
}

export const RULE_KIND_INFO: Record<ShopRuleKind, { label: string; help: string }> = {
  requires: {
    label: 'Requires',
    help: 'If an option is selected, another group must use one of the listed options.',
  },
  excludes: {
    label: 'Excludes',
    help: 'Two options cannot be selected together.',
  },
  power: {
    label: 'Power budget',
    help: 'Σ(watts × qty over groups) + base watts ≤ selected PSU watts × headroom.',
  },
  max_total: {
    label: 'Max total',
    help: 'Σ(attr × qty) in a group ≤ product.attributes[limit attr] (e.g. GPU slots).',
  },
  attr_match: {
    label: 'Attribute match',
    help: 'Every selected option in a group must have attr equal to the product attribute (e.g. memory type).',
  },
};

export function defaultParams(kind: ShopRuleKind): Params {
  switch (kind) {
    case 'requires':
      return { if: '', then_group: '', one_of: [] };
    case 'excludes':
      return { a: '', b: '' };
    case 'power':
      return { budget_from: 'psu', budget_attr: 'psu_watts', sum_attr: 'watts', groups: ['cpu', 'gpu'], base_watts: 250, headroom: 0.9 };
    case 'max_total':
      return { group: 'gpu', attr: 'slots', limit_attr: 'gpu_slots' };
    case 'attr_match':
      return { group: 'memory', attr: 'memory_type', equals_product_attr: 'memory_type' };
  }
}

export function ruleToForm(r: ShopRule): RuleForm {
  const kind = (SHOP_RULE_KINDS as readonly string[]).includes(r.kind) ? r.kind : 'requires';
  return {
    key: newKey(),
    uuid: r.uuid,
    kind,
    params: { ...defaultParams(kind), ...((r.params as Params) ?? {}) },
    message: r.message ?? '',
    is_active: r.is_active !== false,
  };
}

const str = (v: unknown): string => (typeof v === 'string' ? v : v === undefined || v === null ? '' : String(v));
const arr = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : []);

/** Validate + convert. Group/option references are checked against the current groups. */
export function rulesToPayload(rules: RuleForm[], groups: GroupForm[]): { rules: Omit<ShopRule, 'id'>[]; errors: string[] } {
  const errors: string[] = [];
  const groupCodes = new Set(groups.map((g) => g.code));
  const optRefs = new Set(groups.flatMap((g) => g.options.map((o) => `${g.code}.${o.code}`)));
  const checkGroup = (label: string, code: string) => {
    if (!code) errors.push(`${label}: group is required`);
    else if (!groupCodes.has(code)) errors.push(`${label}: unknown group "${code}"`);
  };
  const checkRef = (label: string, ref: string) => {
    if (!ref) errors.push(`${label}: option is required`);
    else if (!optRefs.has(ref)) errors.push(`${label}: unknown option "${ref}"`);
  };

  const out = rules.map((r, i) => {
    const label = `Rule ${i + 1} (${RULE_KIND_INFO[r.kind].label})`;
    const p = r.params;
    let params: Params;
    switch (r.kind) {
      case 'requires':
        checkRef(label, str(p.if));
        checkGroup(label, str(p.then_group));
        if (!arr(p.one_of).length) errors.push(`${label}: pick at least one allowed option`);
        params = { if: str(p.if), then_group: str(p.then_group), one_of: arr(p.one_of) };
        break;
      case 'excludes':
        checkRef(label, str(p.a));
        checkRef(label, str(p.b));
        params = { a: str(p.a), b: str(p.b) };
        break;
      case 'power': {
        checkGroup(label, str(p.budget_from));
        if (!arr(p.groups).length) errors.push(`${label}: pick at least one group to sum`);
        const base = Number(p.base_watts);
        const head = Number(p.headroom);
        if (!Number.isFinite(base) || base < 0) errors.push(`${label}: base watts must be ≥ 0`);
        if (!Number.isFinite(head) || head <= 0 || head > 1) errors.push(`${label}: headroom must be between 0 and 1`);
        params = {
          budget_from: str(p.budget_from),
          budget_attr: str(p.budget_attr) || 'psu_watts',
          sum_attr: str(p.sum_attr) || 'watts',
          groups: arr(p.groups),
          base_watts: base,
          headroom: head,
        };
        break;
      }
      case 'max_total': {
        checkGroup(label, str(p.group));
        const limit = str(p.limit).trim();
        if (!str(p.attr)) errors.push(`${label}: option attr is required`);
        if (!str(p.limit_attr) && !limit) errors.push(`${label}: product limit attr or a fixed limit is required`);
        if (limit && !Number.isFinite(Number(limit))) errors.push(`${label}: fixed limit must be a number`);
        if (str(p.when_attr) && str(p.when_equals) === '') errors.push(`${label}: "only count when" needs a value`);
        params = {
          group: str(p.group),
          attr: str(p.attr),
          limit_attr: str(p.limit_attr) || undefined,
          limit: limit ? Number(limit) : undefined,
          when_attr: str(p.when_attr) || undefined,
          when_equals: str(p.when_attr) ? p.when_equals : undefined,
        };
        break;
      }
      case 'attr_match':
        checkGroup(label, str(p.group));
        if (!str(p.attr) || (!str(p.equals_product_attr) && str(p.equals) === ''))
          errors.push(`${label}: attr and product attr (or a fixed value) are required`);
        params = { group: str(p.group), attr: str(p.attr), equals_product_attr: str(p.equals_product_attr) || undefined };
        break;
    }
    // Keep params this form doesn't model (engine extensions such as attr_match
    // `equals`) so a save never silently changes rule semantics. Form-managed
    // keys win; undefined ones are dropped (JSON.stringify omits them).
    params = { ...p, ...params };
    if (!r.message.trim()) errors.push(`${label}: message is required (shown to customers)`);
    return { ...(r.uuid ? { uuid: r.uuid } : {}), kind: r.kind, params, message: r.message.trim(), is_active: r.is_active, sort_order: (i + 1) * 10 };
  });
  return { rules: out, errors };
}

// ============================================================
// Editor
// ============================================================

export function RulesEditor({
  rules,
  onChange,
  groups,
}: {
  rules: RuleForm[];
  onChange: (r: RuleForm[]) => void;
  groups: GroupForm[];
}) {
  const update = (i: number, patch: Partial<RuleForm>) => onChange(rules.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const setParam = (i: number, k: string, v: unknown) => update(i, { params: { ...rules[i].params, [k]: v } });
  const validGroups = groups.filter((g) => g.code);

  return (
    <div className="space-y-4">
      {rules.length === 0 && (
        <div className="rounded-lg border border-dashed border-secondary-300 p-6 text-center text-sm text-secondary-500">
          No compatibility rules.
        </div>
      )}
      {rules.map((r, i) => (
        <div key={r.key} className={cn('rounded-xl border p-4', r.is_active ? 'border-secondary-200' : 'border-dashed border-secondary-300 opacity-70')}>
          <div className="mb-3 flex flex-wrap items-center gap-3">
            <div className="w-48">
              <Select
                aria-label="Rule kind"
                id={`r-${r.key}-kind`}
                value={r.kind}
                onChange={(e) => {
                  const kind = e.target.value as ShopRuleKind;
                  update(i, { kind, params: defaultParams(kind) });
                }}
              >
                {SHOP_RULE_KINDS.map((k) => (
                  <option key={k} value={k}>{RULE_KIND_INFO[k].label}</option>
                ))}
              </Select>
            </div>
            <p className="min-w-0 flex-1 text-xs text-secondary-500">{RULE_KIND_INFO[r.kind].help}</p>
            {!r.is_active && <Badge size="sm" variant="secondary">Inactive</Badge>}
            <div className="flex items-center">
              <ReorderButtons index={i} count={rules.length} onMove={(d) => onChange(moveItem(rules, i, d))} />
              <IconButton label="Remove rule" danger onClick={() => onChange(rules.filter((_, j) => j !== i))}>
                <Trash2 className="h-4 w-4" />
              </IconButton>
            </div>
          </div>

          <RuleParamsForm rule={r} groups={validGroups} setParam={(k, v) => setParam(i, k, v)} />

          <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
            <Input
              label="Message (shown when violated)"
              id={`r-${r.key}-msg`}
              value={r.message}
              onChange={(e) => update(i, { message: e.target.value })}
              placeholder="e.g. More than 2 GPUs requires Max-Q editions"
            />
            <div className="pb-2.5">
              <CheckboxField label="Active" checked={r.is_active} onChange={(v) => update(i, { is_active: v })} />
            </div>
          </div>
        </div>
      ))}
      <Button
        type="button"
        variant="outline"
        size="sm"
        leftIcon={<Plus className="h-4 w-4" />}
        onClick={() => onChange([...rules, { key: newKey(), kind: 'power', params: defaultParams('power'), message: '', is_active: true }])}
      >
        Add rule
      </Button>
    </div>
  );
}

function GroupSelect({
  label,
  id,
  value,
  groups,
  onChange,
}: {
  label: string;
  id: string;
  value: string;
  groups: GroupForm[];
  onChange: (v: string) => void;
}) {
  const known = groups.some((g) => g.code === value);
  return (
    <Select label={label} id={id} value={value} onChange={(e) => onChange(e.target.value)} error={!!value && !known}>
      <option value="">— Select group —</option>
      {!known && value && <option value={value}>{value} (unknown)</option>}
      {groups.map((g) => (
        <option key={g.key} value={g.code}>{g.name || g.code} ({g.code})</option>
      ))}
    </Select>
  );
}

function OptionRefSelect({
  label,
  id,
  value,
  groups,
  onChange,
}: {
  label: string;
  id: string;
  value: string;
  groups: GroupForm[];
  onChange: (v: string) => void;
}) {
  const refs = groups.flatMap((g) => g.options.filter((o) => o.code).map((o) => ({ ref: `${g.code}.${o.code}`, g, o })));
  const known = refs.some((x) => x.ref === value);
  return (
    <Select label={label} id={id} value={value} onChange={(e) => onChange(e.target.value)} error={!!value && !known}>
      <option value="">— Select option —</option>
      {!known && value && <option value={value}>{value} (unknown)</option>}
      {groups.map((g) => (
        <optgroup key={g.key} label={g.name || g.code}>
          {g.options
            .filter((o) => o.code)
            .map((o) => (
              <option key={o.key} value={`${g.code}.${o.code}`}>{o.name || o.code}</option>
            ))}
        </optgroup>
      ))}
    </Select>
  );
}

function GroupChecklist({
  label,
  value,
  groups,
  onChange,
}: {
  label: string;
  value: string[];
  groups: GroupForm[];
  onChange: (v: string[]) => void;
}) {
  return (
    <fieldset>
      <legend className="mb-1.5 block text-sm font-medium text-secondary-700">{label}</legend>
      <div className="flex flex-wrap gap-x-4 gap-y-1.5">
        {groups.length === 0 && <span className="text-xs text-secondary-500">Add option groups first.</span>}
        {groups.map((g) => (
          <CheckboxField
            key={g.key}
            label={g.code}
            checked={value.includes(g.code)}
            onChange={(on) => onChange(on ? [...value, g.code] : value.filter((c) => c !== g.code))}
          />
        ))}
      </div>
    </fieldset>
  );
}

function RuleParamsForm({
  rule,
  groups,
  setParam,
}: {
  rule: RuleForm;
  groups: GroupForm[];
  setParam: (k: string, v: unknown) => void;
}) {
  const p = rule.params;
  const id = (k: string) => `r-${rule.key}-${k}`;
  switch (rule.kind) {
    case 'requires': {
      const thenGroup = groups.find((g) => g.code === str(p.then_group));
      const oneOf = arr(p.one_of);
      return (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          <OptionRefSelect label="If option selected" id={id('if')} value={str(p.if)} groups={groups} onChange={(v) => setParam('if', v)} />
          <GroupSelect
            label="Then group"
            id={id('then')}
            value={str(p.then_group)}
            groups={groups}
            onChange={(v) => {
              setParam('then_group', v);
            }}
          />
          <fieldset>
            <legend className="mb-1.5 block text-sm font-medium text-secondary-700">Must be one of</legend>
            {!thenGroup ? (
              <p className="text-xs text-secondary-500">Choose the “then” group first.</p>
            ) : (
              <div className="flex flex-col gap-1.5">
                {thenGroup.options
                  .filter((o) => o.code)
                  .map((o) => (
                    <CheckboxField
                      key={o.key}
                      label={o.name || o.code}
                      checked={oneOf.includes(o.code)}
                      onChange={(on) => setParam('one_of', on ? [...oneOf, o.code] : oneOf.filter((c) => c !== o.code))}
                    />
                  ))}
              </div>
            )}
          </fieldset>
        </div>
      );
    }
    case 'excludes':
      return (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <OptionRefSelect label="Option A" id={id('a')} value={str(p.a)} groups={groups} onChange={(v) => setParam('a', v)} />
          <OptionRefSelect label="Option B" id={id('b')} value={str(p.b)} groups={groups} onChange={(v) => setParam('b', v)} />
        </div>
      );
    case 'power':
      return (
        <div className="space-y-3">
          <div className="grid grid-cols-1 gap-3 md:grid-cols-5">
            <GroupSelect label="Budget from group" id={id('bf')} value={str(p.budget_from)} groups={groups} onChange={(v) => setParam('budget_from', v)} />
            <Input label="Budget attr" id={id('ba')} value={str(p.budget_attr)} onChange={(e) => setParam('budget_attr', e.target.value)} className="font-mono" />
            <Input label="Sum attr" id={id('sa')} value={str(p.sum_attr)} onChange={(e) => setParam('sum_attr', e.target.value)} className="font-mono" />
            <Input label="Base watts" id={id('bw')} value={str(p.base_watts)} onChange={(e) => setParam('base_watts', e.target.value)} inputMode="numeric" />
            <Input label="Headroom (0–1)" id={id('hr')} value={str(p.headroom)} onChange={(e) => setParam('headroom', e.target.value)} inputMode="decimal" />
          </div>
          <GroupChecklist label="Groups to sum" value={arr(p.groups)} groups={groups} onChange={(v) => setParam('groups', v)} />
        </div>
      );
    case 'max_total':
      return (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          <GroupSelect label="Group" id={id('g')} value={str(p.group)} groups={groups} onChange={(v) => setParam('group', v)} />
          <Input label="Option attr" id={id('a')} value={str(p.attr)} onChange={(e) => setParam('attr', e.target.value)} className="font-mono" helperText="e.g. slots" />
          <Input label="Product limit attr" id={id('l')} value={str(p.limit_attr)} onChange={(e) => setParam('limit_attr', e.target.value)} className="font-mono" helperText="e.g. gpu_slots" />
          <Input label="Fixed limit (optional)" id={id('lim')} value={str(p.limit)} onChange={(e) => setParam('limit', e.target.value)} inputMode="numeric" helperText="Used when no product limit attr" />
          <Input label="Only count when attr (optional)" id={id('wa')} value={str(p.when_attr)} onChange={(e) => setParam('when_attr', e.target.value)} className="font-mono" helperText="e.g. cooling" />
          <Input label="…equals" id={id('we')} value={str(p.when_equals)} onChange={(e) => setParam('when_equals', e.target.value)} className="font-mono" helperText="e.g. flow-through" />
        </div>
      );
    case 'attr_match':
      return (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          <GroupSelect label="Group" id={id('g')} value={str(p.group)} groups={groups} onChange={(v) => setParam('group', v)} />
          <Input label="Option attr" id={id('a')} value={str(p.attr)} onChange={(e) => setParam('attr', e.target.value)} className="font-mono" helperText="e.g. memory_type" />
          <Input
            label="Equals product attr"
            id={id('e')}
            value={str(p.equals_product_attr)}
            onChange={(e) => setParam('equals_product_attr', e.target.value)}
            className="font-mono"
            helperText="e.g. memory_type"
          />
        </div>
      );
  }
}
