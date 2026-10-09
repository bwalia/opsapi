/**
 * The field-type registry the builder uses (palette, defaults, which settings
 * each type has). It mirrors lapis/lib/forms/fields.lua: adding a type there
 * means adding it here and rendering it in FormRenderer.
 */

import {
  AlignLeft, AtSign, CalendarDays, CircleDot, Clock, EyeOff, Hash, Heading, Link2, ListChecks,
  ListFilter, MapPin, Phone, Pilcrow, ShieldCheck, Star, ToggleLeft, Type, UserRound,
  type LucideIcon,
} from 'lucide-react';
import type { FieldType, FormField, MapsTo } from '@/services/forms.service';

export interface FieldTypeDef {
  type: FieldType;
  label: string;
  icon: LucideIcon;
  group: 'Text' | 'Choice' | 'Contact' | 'Other' | 'Layout';
  /** Takes an answer (heading/paragraph don't). */
  input: boolean;
  hasOptions?: boolean;
  hasPlaceholder?: boolean;
  /** maps_to targets this type can feed (copied onto created records). */
  maps?: MapsTo[];
  defaults: () => Partial<FormField>;
}

export const FIELD_TYPES: FieldTypeDef[] = [
  { type: 'short_text', label: 'Short text', icon: Type, group: 'Text', input: true, hasPlaceholder: true,
    maps: ['phone', 'company', 'job_title', 'address', 'notes'], defaults: () => ({ label: 'Short answer' }) },
  { type: 'long_text', label: 'Paragraph', icon: AlignLeft, group: 'Text', input: true, hasPlaceholder: true,
    maps: ['address', 'notes'], defaults: () => ({ label: 'Long answer' }) },
  { type: 'number', label: 'Number', icon: Hash, group: 'Text', input: true, hasPlaceholder: true,
    defaults: () => ({ label: 'Number' }) },
  { type: 'date', label: 'Date', icon: CalendarDays, group: 'Text', input: true, defaults: () => ({ label: 'Date' }) },
  { type: 'time', label: 'Time', icon: Clock, group: 'Text', input: true, defaults: () => ({ label: 'Time' }) },
  { type: 'single_select', label: 'Dropdown', icon: ListFilter, group: 'Choice', input: true, hasOptions: true,
    defaults: () => ({ label: 'Choose one', options: opts('Option 1', 'Option 2') }) },
  { type: 'radio', label: 'Single choice', icon: CircleDot, group: 'Choice', input: true, hasOptions: true,
    defaults: () => ({ label: 'Pick one', options: opts('Option 1', 'Option 2') }) },
  { type: 'multi_select', label: 'Checkboxes', icon: ListChecks, group: 'Choice', input: true, hasOptions: true,
    defaults: () => ({ label: 'Pick any', options: opts('Option 1', 'Option 2') }) },
  { type: 'boolean', label: 'Yes / No', icon: ToggleLeft, group: 'Choice', input: true,
    maps: ['marketing_consent'], defaults: () => ({ label: 'Yes or no?' }) },
  { type: 'rating', label: 'Rating', icon: Star, group: 'Choice', input: true, defaults: () => ({ label: 'Rate us', scale: 5 }) },
  { type: 'name', label: 'Name', icon: UserRound, group: 'Contact', input: true, defaults: () => ({ label: 'Name' }) },
  { type: 'email', label: 'Email', icon: AtSign, group: 'Contact', input: true, hasPlaceholder: true,
    defaults: () => ({ label: 'Email' }) },
  { type: 'phone', label: 'Phone', icon: Phone, group: 'Contact', input: true, hasPlaceholder: true, maps: ['phone'],
    defaults: () => ({ label: 'Phone' }) },
  { type: 'address', label: 'Address', icon: MapPin, group: 'Contact', input: true, maps: ['address'],
    defaults: () => ({ label: 'Address' }) },
  { type: 'url', label: 'Website', icon: Link2, group: 'Contact', input: true, hasPlaceholder: true,
    defaults: () => ({ label: 'Website' }) },
  { type: 'consent', label: 'Consent', icon: ShieldCheck, group: 'Other', input: true, maps: ['marketing_consent'],
    defaults: () => ({ label: 'Consent', text: 'I agree to the privacy policy.', required: true }) },
  { type: 'hidden', label: 'Hidden (from link)', icon: EyeOff, group: 'Other', input: true,
    defaults: () => ({ label: 'Campaign', param: 'utm_campaign' }) },
  { type: 'heading', label: 'Heading', icon: Heading, group: 'Layout', input: false,
    defaults: () => ({ label: 'Section title' }) },
  { type: 'paragraph', label: 'Text block', icon: Pilcrow, group: 'Layout', input: false,
    defaults: () => ({ label: '', text: 'Some text for the people filling in the form.' }) },
];

function opts(...labels: string[]) {
  return labels.map((label, i) => ({ value: `option_${i + 1}`, label }));
}

export const FIELD_TYPE_BY_NAME: Record<string, FieldTypeDef> = Object.fromEntries(
  FIELD_TYPES.map((d) => [d.type, d])
);

export const MAPS_TO_LABEL: Record<MapsTo, string> = {
  phone: 'Phone',
  company: 'Company',
  job_title: 'Job title',
  address: 'Address',
  notes: 'Notes',
  marketing_consent: 'Marketing consent',
};

export const TARGET_LABEL: Record<string, string> = {
  customer: 'Customer',
  lead: 'Lead',
  user: 'Invitation',
};

/** An answer key from a label: what the server would generate (^[a-z][a-z0-9_]*$, max 40). */
export function keyFromLabel(label: string, taken: Set<string>): string {
  let base = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
  if (!/^[a-z]/.test(base)) base = `f_${base}`;
  base = base.slice(0, 40).replace(/_+$/, '') || 'field';
  let key = base;
  for (let n = 2; taken.has(key); n++) key = `${base.slice(0, 36)}_${n}`;
  return key;
}

/** A new field of `type` with a key not in `taken`. */
export function newField(type: FieldType, taken: Set<string>): FormField {
  const def = FIELD_TYPE_BY_NAME[type];
  const field = { type, label: def.label, ...def.defaults() } as FormField;
  field.key = keyFromLabel(field.label || type, taken);
  return field;
}
