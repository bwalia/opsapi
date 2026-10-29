'use client';

import React, { useMemo, useState } from 'react';
import Link from 'next/link';
import {
  LayoutGrid, Search, Loader2, ArrowUpRight, BookOpen, Puzzle,
  Building2, ShoppingCart, Truck, MessageSquare, Kanban, Heart, Bell, Star, Menu, KeyRound,
  Server, Landmark, Calculator, Contact, Clock, FileText, BookOpenCheck, GraduationCap,
  Newspaper, Wrench, Cpu, CreditCard, ClipboardList, Briefcase, Palette, type LucideIcon,
} from 'lucide-react';
import { Card, Badge, Input } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { useDataFetch, useMenu } from '@/hooks';
import { systemService, type AppFeature } from '@/services';
import { cn, snakeToTitle } from '@/lib/utils';

// Display details for the built-in features (helper/project-config.lua FEATURES).
// Plugins and anything new fall back to the feature code and its modules.
const FEATURE_META: Record<string, { name: string; blurb: string; icon: LucideIcon; href?: string }> = {
  core: { name: 'Core platform', blurb: 'Sign-in, workspaces, users, roles, employees, webhooks and activity.', icon: Building2, href: '/dashboard/users' },
  ecommerce: { name: 'E-commerce', blurb: 'Stores, products, orders and customers.', icon: ShoppingCart, href: '/dashboard/stores' },
  delivery: { name: 'Delivery', blurb: 'Delivery partners and order dispatch.', icon: Truck },
  chat: { name: 'Chat', blurb: 'Channels and direct messages for the team.', icon: MessageSquare, href: '/dashboard/chat' },
  kanban: { name: 'Projects (Kanban)', blurb: 'Boards, tasks and sprints.', icon: Kanban, href: '/dashboard/projects' },
  hospital: { name: 'Hospital & care', blurb: 'Hospitals, patients, appointments and records.', icon: Heart, href: '/dashboard/hospitals' },
  notifications: { name: 'Notifications', blurb: 'In-app, web push and mobile push notifications.', icon: Bell },
  reviews: { name: 'Reviews', blurb: 'Product and store reviews.', icon: Star },
  menu: { name: 'Navigation', blurb: 'The backend-driven sidebar, set per workspace.', icon: Menu },
  vault: { name: 'Secret vault', blurb: 'Encrypted secrets for your workspace.', icon: KeyRound },
  services: { name: 'Services & domains', blurb: 'Deploy services through GitHub workflows; manage domains and DNS.', icon: Server, href: '/dashboard/services' },
  bank_transactions: { name: 'Bank transactions', blurb: 'Bank transaction tracking used by tax and accounting.', icon: Landmark },
  tax_copilot: { name: 'Tax Copilot', blurb: 'UK self assessment: statements, categorising and filing with HMRC.', icon: Calculator, href: '/dashboard/tax' },
  crm: { name: 'CRM', blurb: 'Accounts, contacts, deals and pipelines.', icon: Contact, href: '/dashboard/crm' },
  timesheets: { name: 'Timesheets', blurb: 'Log time and approve timesheets.', icon: Clock, href: '/dashboard/timesheets' },
  invoicing: { name: 'Invoicing', blurb: 'Invoices, payments, tax rates and purchase orders.', icon: FileText, href: '/dashboard/invoices' },
  accounting: { name: 'Accounting', blurb: 'Bookkeeping, bank reconciliation, expenses and VAT returns.', icon: BookOpenCheck, href: '/dashboard/accounting' },
  academy: { name: 'Academy', blurb: 'Courses and lessons.', icon: GraduationCap, href: '/dashboard/academy' },
  cms: { name: 'CMS', blurb: 'Website pages and blog.', icon: Newspaper, href: '/dashboard/cms' },
  field_service: { name: 'Field service', blurb: 'Jobs, site visits, assets, contracts and quotes.', icon: Wrench, href: '/dashboard/field-service' },
  shop: { name: 'Shop', blurb: 'Hardware catalogue, carts, quotes and checkout.', icon: Cpu, href: '/dashboard/shop' },
  billing: { name: 'Billing', blurb: 'Plans, subscriptions, entitlements and licences.', icon: CreditCard, href: '/dashboard/billing' },
  forms: { name: 'Forms', blurb: 'Build forms, share a link and collect responses.', icon: ClipboardList, href: '/dashboard/forms' },
  ats: { name: 'Hiring', blurb: 'Jobs, candidates and AI first-round interviews.', icon: Briefcase, href: '/dashboard/ats' },
  themes: { name: 'Themes', blurb: 'Workspace themes for your public sites.', icon: Palette, href: '/dashboard/themes' },
};

type Filter = 'all' | 'deployed' | 'not_deployed';

export default function AppsPage() {
  const { data: info, isLoading, error } = useDataFetch(systemService.getInfo, []);
  const { allMenu } = useMenu();
  const [filter, setFilter] = useState<Filter>('all');
  const [query, setQuery] = useState('');

  // Module -> the sidebar page this user can open for it.
  const menuPathByModule = useMemo(() => {
    const map: Record<string, string> = {};
    for (const item of allMenu) {
      if (item.module && !map[String(item.module)]) map[String(item.module)] = item.path;
    }
    return map;
  }, [allMenu]);

  const apps = useMemo(() => {
    const list = info?.apps ?? [];
    const q = query.trim().toLowerCase();
    return list
      .filter((a) => filter === 'all' || (filter === 'deployed') === a.enabled)
      .filter((a) => {
        if (!q) return true;
        const meta = FEATURE_META[a.feature];
        const text = [a.feature, meta?.name, meta?.blurb, ...a.modules.map((m) => `${m.name} ${m.description ?? ''}`)]
          .join(' ').toLowerCase();
        return text.includes(q);
      })
      // Deployed first, then by name
      .sort((a, b) => Number(b.enabled) - Number(a.enabled) || displayName(a).localeCompare(displayName(b)));
  }, [info, filter, query]);

  const deployedCount = info?.apps?.filter((a) => a.enabled).length ?? 0;

  return (
    <div className="space-y-6">
      <PageHeader
        icon={<LayoutGrid className="h-6 w-6" />}
        title="Apps"
        description={
          info
            ? `Every module in OpsAPI. This server runs ${deployedCount} of ${info.apps?.length ?? 0} (PROJECT_CODE: ${info.project_code}).`
            : 'Every module in OpsAPI, and which ones this server runs.'
        }
        actions={
          <Link href="/docs" className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-200 px-3 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
            <BookOpen className="h-4 w-4" /> API docs
          </Link>
        }
      />

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="inline-flex rounded-lg border border-secondary-200 p-1">
          {(['all', 'deployed', 'not_deployed'] as Filter[]).map((f) => (
            <button
              key={f}
              type="button"
              onClick={() => setFilter(f)}
              className={cn(
                'rounded-md px-3 py-1.5 text-sm font-medium',
                filter === f ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-50'
              )}
            >
              {f === 'all' ? 'All' : f === 'deployed' ? 'Deployed' : 'Not deployed'}
            </button>
          ))}
        </div>
        <div className="relative w-full sm:w-72">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" />
          <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search apps and modules" className="pl-9" />
        </div>
      </div>

      {isLoading ? (
        <div className="flex justify-center py-16"><Loader2 className="h-8 w-8 animate-spin text-primary-500" /></div>
      ) : error ? (
        <Card><p className="text-sm text-error-600">Couldn&apos;t load the app list: {error.message}</p></Card>
      ) : !info?.apps ? (
        <Card><p className="text-sm text-secondary-600">This API is older than the app catalog. Update it to see the list.</p></Card>
      ) : apps.length === 0 ? (
        <Card><p className="text-sm text-secondary-600">No apps match.</p></Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {apps.map((app) => (
            <AppTile key={app.feature} app={app} href={hrefFor(app, menuPathByModule)} />
          ))}
        </div>
      )}
    </div>
  );
}

function displayName(app: AppFeature): string {
  return FEATURE_META[app.feature]?.name ?? snakeToTitle(app.feature);
}

function hrefFor(app: AppFeature, menuPathByModule: Record<string, string>): string | undefined {
  if (!app.enabled) return undefined;
  for (const m of app.modules) {
    if (menuPathByModule[m.machine_name]) return menuPathByModule[m.machine_name];
  }
  return FEATURE_META[app.feature]?.href;
}

function AppTile({ app, href }: { app: AppFeature; href?: string }) {
  const meta = FEATURE_META[app.feature];
  const Icon = meta?.icon ?? (app.plugin ? Puzzle : LayoutGrid);
  const blurb = meta?.blurb ?? app.modules[0]?.description ?? '';

  return (
    <Card padding="none" className={cn('flex flex-col p-5', !app.enabled && 'opacity-70')}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className={cn(
            'flex h-10 w-10 shrink-0 items-center justify-center rounded-lg',
            app.enabled ? 'bg-primary-500/10 text-primary-500' : 'bg-secondary-100 text-secondary-400'
          )}>
            <Icon className="h-5 w-5" />
          </span>
          <div>
            <h3 className="font-semibold text-secondary-900">{displayName(app)}</h3>
            <p className="font-mono text-xs text-secondary-400">{app.feature}</p>
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <Badge variant={app.enabled ? 'success' : 'secondary'}>{app.enabled ? 'Deployed' : 'Not deployed'}</Badge>
          {app.plugin && <Badge variant="info">Plugin</Badge>}
        </div>
      </div>

      {blurb && <p className="mt-3 text-sm text-secondary-600">{blurb}</p>}

      {app.modules.length > 0 ? (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {app.modules.map((m) => (
            <span key={m.machine_name} title={m.description} className="rounded-md bg-secondary-100 px-2 py-0.5 text-xs text-secondary-600">
              {m.name}
            </span>
          ))}
        </div>
      ) : (
        <p className="mt-3 text-xs text-secondary-400">Platform service: no pages of its own.</p>
      )}

      <div className="mt-auto pt-4">
        {href ? (
          <Link href={href} className="inline-flex items-center gap-1 text-sm font-medium text-primary-600 hover:text-primary-700">
            Open <ArrowUpRight className="h-4 w-4" />
          </Link>
        ) : !app.enabled ? (
          <p className="text-xs text-secondary-400">Add it to this server&apos;s PROJECT_CODE to use it.</p>
        ) : null}
      </div>
    </Card>
  );
}
