/**
 * Conditional logic ("show this question only if …"), the same rules the
 * server applies in lapis/lib/forms/fields.lua (Fields.visible). A rule refers
 * to an answer field above the question, so visibility is worked out top to
 * bottom; a hidden question's answer isn't sent and it isn't required.
 */

import type { FieldType, FormField, LogicOp, LogicRule } from '@/services/forms.service';

function ruleOk(r: LogicRule, answers: Record<string, unknown>): boolean {
  const v = answers[r.field];
  const present = !(v === undefined || v === null || v === '' || (Array.isArray(v) && v.length === 0));
  if (r.op === 'filled') return present;
  if (r.op === 'empty') return !present;
  if (!present) return r.op === 'neq' || r.op === 'not_in';
  if (r.op === 'contains') {
    if (Array.isArray(v)) return v.includes(r.value as string);
    return String(v).toLowerCase().includes(String(r.value).toLowerCase());
  }
  if (r.op === 'in' || r.op === 'not_in') {
    const vals = Array.isArray(v) ? v : [v];
    const list = Array.isArray(r.value) ? r.value : [];
    const hit = vals.some((x) => list.includes(x as string));
    return (r.op === 'in') === hit;
  }
  if (r.op === 'gt' || r.op === 'lt') {
    if (typeof r.value === 'number') {
      const a = Number(v);
      if (Number.isNaN(a)) return false;
      return r.op === 'gt' ? a > r.value : a < r.value;
    }
    const a = String(v);
    return r.op === 'gt' ? a > String(r.value) : a < String(r.value);
  }
  let same: boolean;
  if (Array.isArray(v)) same = v.includes(r.value as string);
  else if (typeof r.value === 'number') same = Number(v) === r.value;
  else if (typeof r.value === 'boolean') same = v === r.value;
  else same = v === r.value;
  return (r.op === 'eq') === same;
}

export function isVisible(field: FormField, answers: Record<string, unknown>): boolean {
  const rules = field.logic?.rules;
  if (!rules || rules.length === 0) return true;
  const any = field.logic?.match === 'any';
  for (const r of rules) {
    const ok = ruleOk(r, answers);
    if (any && ok) return true;
    if (!any && !ok) return false;
  }
  return !any;
}

/** Keys of the fields shown for these answers (top to bottom, like the server). */
export function visibleKeys(fields: FormField[], answers: Record<string, unknown>): Set<string> {
  const shown = new Set<string>();
  const seen: Record<string, unknown> = {};
  fields.forEach((f, i) => {
    const id = f.key || `idx-${i}`;
    if (isVisible(f, seen)) {
      shown.add(id);
      if (f.key && answers[f.key] !== undefined) seen[f.key] = answers[f.key];
    }
  });
  return shown;
}

/** The answers the server should get: those of visible input fields only. */
export function visibleAnswers(fields: FormField[], answers: Record<string, unknown>): Record<string, unknown> {
  const shown = visibleKeys(fields, answers);
  const out: Record<string, unknown> = {};
  for (const f of fields) if (f.key && shown.has(f.key) && answers[f.key] !== undefined) out[f.key] = answers[f.key];
  return out;
}

const CHOICE: FieldType[] = ['single_select', 'radio', 'multi_select'];
const NUMERIC: FieldType[] = ['number', 'rating'];

/** The conditions that make sense for a question of this type (builder). */
export function opsFor(type: FieldType): { op: LogicOp; label: string }[] {
  const base: { op: LogicOp; label: string }[] = [];
  if (CHOICE.includes(type)) {
    base.push({ op: 'eq', label: type === 'multi_select' ? 'includes' : 'is' }, { op: 'neq', label: type === 'multi_select' ? "doesn't include" : 'is not' },
      { op: 'in', label: 'is any of' }, { op: 'not_in', label: 'is none of' });
  } else if (type === 'boolean' || type === 'consent') {
    base.push({ op: 'eq', label: 'is' });
  } else if (NUMERIC.includes(type) || type === 'date') {
    base.push({ op: 'eq', label: 'is' }, { op: 'neq', label: 'is not' }, { op: 'gt', label: type === 'date' ? 'is after' : 'is more than' },
      { op: 'lt', label: type === 'date' ? 'is before' : 'is less than' });
  } else {
    base.push({ op: 'eq', label: 'is' }, { op: 'neq', label: 'is not' }, { op: 'contains', label: 'contains' });
  }
  base.push({ op: 'filled', label: 'is answered' }, { op: 'empty', label: 'is not answered' });
  return base;
}
