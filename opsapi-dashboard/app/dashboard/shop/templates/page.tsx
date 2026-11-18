'use client';

/**
 * Shop → Templates: pre-written supplier messages for each use case, with {{placeholders}} filled in when a
 * message is drafted (rules: lapis/lib/message-templates.lua).
 *  - Price request (quote → Email supplier) and Stock enquiry (product → Ask suppliers) never name the customer:
 *    customer placeholders are refused for them.
 *  - Supplier introduction (quote → Introduce to supplier) may use the customer's details.
 * A template can be for one supplier (picked automatically when that supplier is chosen) and one per kind can be
 * the default; with none, the built-in wording is used.
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Copy, FileText, Pencil, Plus, Star, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { ShopLoading } from '@/components/shop/shared';
import { CheckboxField } from '@/components/shop/editor-fields';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import {
  SHOP_TEMPLATE_KINDS,
  type ShopMessageTemplate,
  type ShopSupplier,
  type ShopTemplateKind,
  type ShopTemplatePlaceholders,
} from '@/types/shop';

const MODULE = 'shop';

/** Example values for the preview. */
const SAMPLE: Record<string, string> = {
  'supplier.name': 'Boston Limited',
  'supplier.contact': 'Sam',
  'sender.name': 'Alex Smith',
  'sender.email': 'alex@example.com',
  company: 'Workstation',
  date: '18 November 2026',
  'deal.code': 'WS-AB12-CD34',
  lines: '1. 1 x AI Tower (Threadripper PRO)\n   - 1 x Threadripper PRO 9975WX\n   - 2 x RTX PRO 6000 Blackwell\n2. 2 x 32" 4K monitor',
  product: 'Juno Neptune 18"',
  qty: '2',
  'product.code': 'NEP18-5080',
  'product.mpn': 'JN18-U9-5080',
  note: '   - RTX 5090\n   - 64 GB RAM',
  'customer.name': 'Ada Lovelace',
  'customer.company': 'Analytical Engines Ltd',
  'customer.email': 'ada@example.com',
  'customer.phone': '020 7946 0000',
  'customer.contact': 'Ada Lovelace · ada@example.com · 020 7946 0000',
};

const PH = /{{\s*([\w.]+?)\s*}}/g;

/** Same rules as the server's render: fill in, drop a line whose placeholders are all empty. */
function preview(text: string, values: Record<string, string>) {
  return text
    .split('\n')
    .flatMap((line) => {
      const names = [...line.matchAll(PH)].map((m) => m[1]);
      const filled = line.replace(PH, (_, n: string) => values[n] ?? '');
      const allEmpty = names.length > 0 && names.every((n) => !values[n]);
      const rest = line.replace(PH, '').trim();
      return allEmpty && (!/\w/.test(rest) || rest.endsWith(':')) ? [] : [filled];
    })
    .join('\n');
}

/** Client-side mirror of the server's validate(): the first problem, or null. */
function problem(kind: ShopTemplateKind, subject: string, body: string, allowed: Set<string>): string | null {
  if (!subject.trim()) return 'Write a subject';
  if (!body.trim()) return 'Write the message';
  for (const m of `${subject}\n${body}`.matchAll(PH)) {
    const n = m[1];
    if (!allowed.has(n)) {
      return n.startsWith('customer.') && kind !== 'supplier_intro'
        ? `{{${n}}} is only allowed in a supplier introduction: suppliers must not see who the customer is`
        : `{{${n}}} isn't a placeholder this kind of message can use`;
    }
  }
  const open = (subject + body).split('{{').length - 1;
  const close = (subject + body).split('}}').length - 1;
  return open === close ? null : 'A placeholder is missing a {{ or }}';
}

interface Form {
  uuid: string | null;
  kind: ShopTemplateKind;
  name: string;
  subject: string;
  body: string;
  supplier_uuid: string;
  is_default: boolean;
  is_active: boolean;
}

function Editor({ form, setForm, meta, suppliers, onClose, onSaved }: {
  form: Form;
  setForm: (f: Form) => void;
  meta: ShopTemplatePlaceholders[];
  suppliers: ShopSupplier[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [saving, setSaving] = useState(false);
  const bodyRef = useRef<HTMLTextAreaElement>(null);
  const kindMeta = meta.find((m) => m.kind === form.kind);
  const allowed = useMemo(() => new Set((kindMeta?.placeholders ?? []).map((p) => p.name)), [kindMeta]);
  const err = problem(form.kind, form.subject, form.body, allowed);

  const insert = (name: string) => {
    const el = bodyRef.current;
    const token = `{{${name}}}`;
    if (!el) { setForm({ ...form, body: form.body + token }); return; }
    const { selectionStart: a, selectionEnd: b } = el;
    const body = form.body.slice(0, a) + token + form.body.slice(b);
    setForm({ ...form, body });
    requestAnimationFrame(() => { el.focus(); el.setSelectionRange(a + token.length, a + token.length); });
  };

  const save = async () => {
    if (err || !form.name.trim()) return;
    setSaving(true);
    const body = {
      kind: form.kind, name: form.name.trim(), subject: form.subject, body: form.body,
      supplier_uuid: form.supplier_uuid || null, is_default: form.is_default, is_active: form.is_active,
    };
    try {
      if (form.uuid) await shopService.updateMessageTemplate(form.uuid, body);
      else await shopService.createMessageTemplate(body);
      toast.success('Template saved');
      onSaved();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save the template'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen
      onClose={() => !saving && onClose()}
      size="2xl"
      title={form.uuid ? 'Edit template' : 'New template'}
      description={SHOP_TEMPLATE_KINDS.find((k) => k.kind === form.kind)?.help}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={save} isLoading={saving} disabled={!!err || !form.name.trim()}>Save template</Button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Select label="Used for" id="tpl-kind" value={form.kind} disabled={!!form.uuid}
            onChange={(e) => {
              const kind = e.target.value as ShopTemplateKind;
              const b = meta.find((m) => m.kind === kind)?.builtin;
              setForm({ ...form, kind, subject: b?.subject ?? form.subject, body: b?.body ?? form.body });
            }}>
            {SHOP_TEMPLATE_KINDS.map((k) => <option key={k.kind} value={k.kind}>{k.label}</option>)}
          </Select>
          <Input label="Name" id="tpl-name" value={form.name} maxLength={160} placeholder="e.g. Introduction to Boston"
            onChange={(e) => setForm({ ...form, name: e.target.value })} />
        </div>
        <Select label="Only for this supplier (optional)" id="tpl-supplier" value={form.supplier_uuid}
          onChange={(e) => setForm({ ...form, supplier_uuid: e.target.value })}>
          <option value="">Any supplier</option>
          {suppliers.map((s) => <option key={s.uuid} value={s.uuid}>{s.name}</option>)}
        </Select>
        <Input label="Subject" id="tpl-subject" value={form.subject} maxLength={200} onChange={(e) => setForm({ ...form, subject: e.target.value })} />
        <div>
          <Textarea ref={bodyRef} label="Message" id="tpl-body" rows={12} value={form.body} maxLength={8000}
            onChange={(e) => setForm({ ...form, body: e.target.value })} />
          <div className="mt-2 flex flex-wrap gap-1.5" aria-label="Insert a placeholder">
            {(kindMeta?.placeholders ?? []).map((p) => (
              <button key={p.name} type="button" title={p.description} onClick={() => insert(p.name)}
                className={`rounded-full border px-2 py-0.5 font-mono text-xs ${p.name.startsWith('customer.') ? 'border-warning-300 bg-warning-50 text-warning-800' : 'border-secondary-200 bg-secondary-50 text-secondary-700'} hover:border-primary-400`}>
                {`{{${p.name}}}`}
              </button>
            ))}
          </div>
          <p className="mt-1 text-xs text-secondary-500">Click a placeholder to insert it. A line whose placeholders are all empty is left out.</p>
        </div>
        {err && <p className="text-sm text-error-600" role="alert">{err}</p>}
        <div className="grid gap-3 sm:grid-cols-2">
          <CheckboxField label="Default for this kind" description="Used when no supplier-specific template applies."
            checked={form.is_default} onChange={(v) => setForm({ ...form, is_default: v, is_active: v ? true : form.is_active })} />
          <CheckboxField label="Active" description="Inactive templates aren't offered when sending."
            checked={form.is_active} onChange={(v) => setForm({ ...form, is_active: v, is_default: v ? form.is_default : false })} />
        </div>
        <div>
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">Preview with example details</p>
          <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
            <p className="mb-2 font-medium text-secondary-900">{preview(form.subject, SAMPLE)}</p>
            <pre className="whitespace-pre-wrap font-sans text-secondary-800">{preview(form.body, SAMPLE)}</pre>
          </div>
        </div>
      </div>
    </Modal>
  );
}

function TemplatesPage() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [rows, setRows] = useState<ShopMessageTemplate[] | null>(null);
  const [meta, setMeta] = useState<ShopTemplatePlaceholders[]>([]);
  const [suppliers, setSuppliers] = useState<ShopSupplier[]>([]);
  const [form, setForm] = useState<Form | null>(null);

  const load = useCallback(() => {
    Promise.all([shopService.getMessageTemplates(), shopService.getTemplatePlaceholders(), shopService.getSuppliers()])
      .then(([t, m, s]) => { setRows(t); setMeta(m); setSuppliers([...s].sort((a, b) => a.name.localeCompare(b.name))); })
      .catch((e) => { setRows([]); toast.error(extractApiError(e, 'Could not load templates')); });
  }, []);
  useEffect(() => { load(); }, [load]);

  const startFrom = (t: ShopMessageTemplate | null, kind: ShopTemplateKind, copy = false) => {
    const b = meta.find((m) => m.kind === kind)?.builtin;
    const src = t ?? b;
    setForm({
      uuid: t && !copy ? t.uuid : null, kind,
      name: t && !copy ? t.name : copy && src ? `${src.name.replace(' (built-in)', '')} (copy)` : '',
      subject: src?.subject ?? '', body: src?.body ?? '',
      supplier_uuid: t && !copy ? t.supplier_uuid ?? '' : '', is_default: t && !copy ? t.is_default : false,
      is_active: t && !copy ? t.is_active : true,
    });
  };

  const remove = async (t: ShopMessageTemplate) => {
    if (!t.uuid || !window.confirm(`Delete "${t.name}"?`)) return;
    try { await shopService.deleteMessageTemplate(t.uuid); load(); } catch (e) { toast.error(extractApiError(e, 'Could not delete it')); }
  };

  if (!rows) return <ShopLoading label="Loading templates…" />;

  return (
    <div className="space-y-6">
      <PageHeader title="Templates" description="Pre-written messages to suppliers, with details filled in for you when you send."
        actions={canCreate(MODULE) ? <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => startFrom(null, 'supplier_intro', true)}>New template</Button> : undefined} />
      {SHOP_TEMPLATE_KINDS.map((k) => {
        const mine = rows.filter((r) => r.kind === k.kind);
        const builtin = meta.find((m) => m.kind === k.kind)?.builtin;
        return (
          <Card key={k.kind}>
            <div className="mb-3 flex items-start justify-between gap-3">
              <div>
                <h2 className="text-base font-semibold text-secondary-900">{k.label}</h2>
                <p className="text-sm text-secondary-500">{k.help}</p>
              </div>
              {canCreate(MODULE) && (
                <Button size="sm" variant="outline" leftIcon={<Plus className="h-4 w-4" />} onClick={() => startFrom(null, k.kind, true)}>New</Button>
              )}
            </div>
            <ul className="divide-y divide-secondary-100">
              {mine.map((t) => (
                <li key={t.uuid} className="flex items-center justify-between gap-3 py-2.5">
                  <div className="min-w-0">
                    <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                      <FileText className="h-4 w-4 text-secondary-400" aria-hidden="true" />{t.name}
                      {t.is_default && <Badge variant="success" size="sm"><Star className="mr-1 inline h-3 w-3" />Default</Badge>}
                      {t.supplier_name && <Badge variant="info" size="sm">For {t.supplier_name}</Badge>}
                      {!t.is_active && <Badge variant="default" size="sm">Inactive</Badge>}
                    </p>
                    <p className="truncate text-xs text-secondary-500">{t.subject}</p>
                  </div>
                  <div className="flex shrink-0 gap-1">
                    {canUpdate(MODULE) && <Button size="sm" variant="ghost" aria-label="Edit" onClick={() => startFrom(t, k.kind)}><Pencil className="h-4 w-4" /></Button>}
                    {canCreate(MODULE) && <Button size="sm" variant="ghost" aria-label="Copy" onClick={() => startFrom(t, k.kind, true)}><Copy className="h-4 w-4" /></Button>}
                    {canDelete(MODULE) && <Button size="sm" variant="ghost" aria-label="Delete" onClick={() => remove(t)}><Trash2 className="h-4 w-4" /></Button>}
                  </div>
                </li>
              ))}
              {builtin && (
                <li className="flex items-center justify-between gap-3 py-2.5">
                  <div className="min-w-0">
                    <p className="flex items-center gap-2 font-medium text-secondary-700">
                      <FileText className="h-4 w-4 text-secondary-400" aria-hidden="true" />{builtin.name}
                      {!mine.some((t) => t.is_default) && <Badge variant="default" size="sm">In use</Badge>}
                    </p>
                    <p className="truncate text-xs text-secondary-500">{builtin.subject}</p>
                  </div>
                  {canCreate(MODULE) && (
                    <Button size="sm" variant="ghost" leftIcon={<Copy className="h-4 w-4" />} onClick={() => startFrom(null, k.kind, true)}>Copy to edit</Button>
                  )}
                </li>
              )}
            </ul>
          </Card>
        );
      })}
      {form && <Editor form={form} setForm={setForm} meta={meta} suppliers={suppliers} onClose={() => setForm(null)}
        onSaved={() => { setForm(null); load(); }} />}
    </div>
  );
}

export default function ShopTemplatesPage() {
  return (
    <ProtectedPage module="shop" title="Shop Templates">
      <TemplatesPage />
    </ProtectedPage>
  );
}
