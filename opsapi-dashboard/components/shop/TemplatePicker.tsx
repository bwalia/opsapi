'use client';

/**
 * Choose which message template a send window drafts with. Options come from the draft itself
 * (`templates`: the built-in wording plus this workspace's active templates for the kind, without those
 * written for another supplier); value "builtin" = the built-in wording. Templates are managed under
 * Shop → Templates.
 */
import React from 'react';
import Link from 'next/link';
import { Select } from '@/components/ui';
import type { ShopMessageTemplate } from '@/types/shop';

export const templateValue = (t?: { uuid: string | null } | null) => (t ? t.uuid ?? 'builtin' : '');

export function TemplatePicker({ id, templates, value, onChange, disabled }: {
  id: string;
  templates: ShopMessageTemplate[] | undefined;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  if (!templates || templates.length === 0) return null;
  return (
    <div>
      <Select label="Template" id={id} value={value} onChange={(e) => onChange(e.target.value)} disabled={disabled}>
        {templates.map((t) => (
          <option key={t.uuid ?? 'builtin'} value={t.uuid ?? 'builtin'}>
            {t.name}
            {t.supplier_name ? ` (for ${t.supplier_name})` : ''}
            {t.is_default ? ' · default' : ''}
          </option>
        ))}
      </Select>
      <p className="mt-1 text-xs text-secondary-500">
        Write your own wording under <Link href="/dashboard/shop/templates" className="font-medium text-primary-600 hover:underline">Shop → Templates</Link>.
      </p>
    </div>
  );
}
