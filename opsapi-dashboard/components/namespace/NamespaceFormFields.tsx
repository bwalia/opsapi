'use client';

import React from 'react';
import { Settings, Image as ImageIcon, Globe, Building2, Link2 } from 'lucide-react';
import { Card, Input } from '@/components/ui';

/** The editable fields common to namespace Settings and the admin Edit page. */
export interface NamespaceFieldValues {
  name: string;
  description: string;
  domain: string;
  logo_url: string;
  banner_url: string;
}

interface Props {
  values: NamespaceFieldValues;
  onChange: (name: keyof NamespaceFieldValues, value: string) => void;
  /** Read-only slug — set at creation, never editable. */
  slug: string;
  disabled?: boolean;
}

/** A titled section card with an accent icon chip. */
function Section({
  icon,
  tint,
  title,
  subtitle,
  children,
}: {
  icon: React.ReactNode;
  tint: string;
  title: string;
  subtitle: string;
  children: React.ReactNode;
}) {
  return (
    <Card className="p-6">
      <div className="flex items-center gap-3 mb-6">
        <div className={`w-10 h-10 rounded-lg flex items-center justify-center ${tint}`}>{icon}</div>
        <div>
          <h2 className="text-base font-semibold text-secondary-900">{title}</h2>
          <p className="text-sm text-secondary-500">{subtitle}</p>
        </div>
      </div>
      {children}
    </Card>
  );
}

function FieldLabel({ children, required }: { children: React.ReactNode; required?: boolean }) {
  return (
    <label className="block text-sm font-medium text-secondary-700 mb-1.5">
      {children}
      {required && <span className="text-error-500"> *</span>}
    </label>
  );
}

export default function NamespaceFormFields({ values, onChange, slug, disabled }: Props) {
  return (
    <div className="space-y-6">
      <Section
        icon={<Settings className="w-5 h-5 text-primary-600" />}
        tint="bg-primary-100"
        title="General"
        subtitle="Basic namespace information"
      >
        <div className="space-y-4">
          <div>
            <FieldLabel required>Namespace Name</FieldLabel>
            <Input
              name="name"
              value={values.name}
              onChange={(e) => onChange('name', e.target.value)}
              placeholder="My Company"
              disabled={disabled}
              required
            />
          </div>

          <div>
            <FieldLabel>Slug</FieldLabel>
            <Input value={slug} disabled className="bg-secondary-50 font-mono text-secondary-500" />
            <p className="text-xs text-secondary-500 mt-1">The slug is permanent — it can’t be changed after creation.</p>
          </div>

          <div>
            <FieldLabel>Description</FieldLabel>
            <textarea
              name="description"
              value={values.description}
              onChange={(e) => onChange('description', e.target.value)}
              placeholder="A brief description of this namespace…"
              rows={3}
              disabled={disabled}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none disabled:bg-secondary-50 disabled:text-secondary-400"
            />
          </div>
        </div>
      </Section>

      <Section
        icon={<ImageIcon className="w-5 h-5 text-warning-600" />}
        tint="bg-warning-100"
        title="Branding"
        subtitle="Logo and banner shown across the namespace"
      >
        <div className="grid gap-5 sm:grid-cols-[auto,1fr] sm:items-start">
          {/* Live preview */}
          <div className="flex sm:flex-col items-center gap-3">
            <div className="w-20 h-20 rounded-xl border border-secondary-200 bg-secondary-50 overflow-hidden flex items-center justify-center shrink-0">
              {values.logo_url ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={values.logo_url}
                  alt="Logo preview"
                  className="w-full h-full object-cover"
                  onError={(e) => ((e.currentTarget.style.display = 'none'))}
                />
              ) : (
                <Building2 className="w-7 h-7 text-secondary-300" />
              )}
            </div>
            <span className="text-xs text-secondary-400">Logo preview</span>
          </div>

          <div className="space-y-4">
            <div>
              <FieldLabel>Logo URL</FieldLabel>
              <Input
                name="logo_url"
                value={values.logo_url}
                onChange={(e) => onChange('logo_url', e.target.value)}
                placeholder="https://example.com/logo.png"
                leftIcon={<Link2 className="w-4 h-4" />}
                disabled={disabled}
              />
            </div>
            <div>
              <FieldLabel>Banner URL</FieldLabel>
              <Input
                name="banner_url"
                value={values.banner_url}
                onChange={(e) => onChange('banner_url', e.target.value)}
                placeholder="https://example.com/banner.png"
                leftIcon={<Link2 className="w-4 h-4" />}
                disabled={disabled}
              />
            </div>
          </div>
        </div>
      </Section>

      <Section
        icon={<Globe className="w-5 h-5 text-success-600" />}
        tint="bg-success-100"
        title="Custom Domain"
        subtitle="Serve this namespace on your own domain"
      >
        <div>
          <FieldLabel>Domain</FieldLabel>
          <Input
            name="domain"
            value={values.domain}
            onChange={(e) => onChange('domain', e.target.value)}
            placeholder="app.mycompany.com"
            leftIcon={<Globe className="w-4 h-4" />}
            disabled={disabled}
          />
          <p className="text-xs text-secondary-500 mt-1">Point your domain’s DNS (CNAME) to our servers to activate it.</p>
        </div>
      </Section>
    </div>
  );
}
