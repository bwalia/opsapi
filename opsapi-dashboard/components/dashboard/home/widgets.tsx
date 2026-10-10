/**
 * Home dashboard widgets. Each workspace gets a layout:
 *   1. settings.dashboard_widgets (an array of widget ids) when the workspace set one, else
 *   2. the default for its business_type (LAYOUTS), else the general layout.
 * A widget only shows when the person can read its module (their role), so one layout serves
 * owners and members alike. Later: a per-person layout picked on day one (same ids).
 */
import type { BusinessType } from '@/types';

export const BUSINESS_TYPES: { value: '' | BusinessType; label: string }[] = [
  { value: '', label: 'General' },
  { value: 'ecommerce', label: 'E-commerce / online shop' },
  { value: 'property_portfolio_manager', label: 'Property portfolio manager (deals, renovations)' },
  { value: 'field_service', label: 'Field service' },
  { value: 'professional_services', label: 'Professional services' },
  { value: 'healthcare', label: 'Healthcare' },
  { value: 'care_home', label: 'Care home' },
  { value: 'accounting', label: 'Accounting / bookkeeping' },
];

/** Where a widget's numbers come from: one fetch per source, only when a visible widget needs it. */
export type WidgetSource = 'core' | 'property';
export type WidgetSize = 'stat' | 'half' | 'full';

export interface WidgetDef {
  label: string;
  /** Permission module the person needs (read). */
  module: string;
  source?: WidgetSource;
  size: WidgetSize;
}

/** Every widget the home page knows. Rendering lives in HomeDashboard. */
export const WIDGET_IDS = [
  // Shop / core
  'users', 'orders', 'products', 'stores', 'revenue', 'orders_chart', 'health', 'recent_orders',
  // Property portfolio
  'pd_active_deals', 'pd_due_today', 'pd_overdue', 'pd_hot_leads_count', 'pd_money_at_risk', 'pd_renovations',
  'pd_approvals', 'pd_hot_leads', 'pd_due_soon', 'pd_deals_at_risk',
] as const;
export type WidgetId = (typeof WIDGET_IDS)[number];

export const WIDGETS: Record<WidgetId, WidgetDef> = {
  users: { label: 'Total users', module: 'users', source: 'core', size: 'stat' },
  orders: { label: 'Total orders', module: 'orders', source: 'core', size: 'stat' },
  products: { label: 'Total products', module: 'products', source: 'core', size: 'stat' },
  stores: { label: 'Total stores', module: 'stores', source: 'core', size: 'stat' },
  revenue: { label: 'Total revenue', module: 'orders', source: 'core', size: 'stat' },
  orders_chart: { label: 'Revenue by month', module: 'orders', source: 'core', size: 'half' },
  health: { label: 'System health', module: 'dashboard', size: 'half' },
  recent_orders: { label: 'Recent orders', module: 'orders', source: 'core', size: 'full' },
  pd_active_deals: { label: 'Active deals', module: 'property_deals_deals', source: 'property', size: 'stat' },
  pd_due_today: { label: 'Tasks due today', module: 'property_deals_tasks', source: 'property', size: 'stat' },
  pd_overdue: { label: 'Overdue tasks', module: 'property_deals_tasks', source: 'property', size: 'stat' },
  pd_hot_leads_count: { label: 'Hot leads to call', module: 'property_deals_tasks', source: 'property', size: 'stat' },
  pd_money_at_risk: { label: 'Money at risk', module: 'property_deals_deals', source: 'property', size: 'stat' },
  pd_renovations: { label: 'Active renovations', module: 'property_deals_deals', source: 'property', size: 'stat' },
  pd_approvals: { label: 'Approvals waiting', module: 'property_deals_approvals', source: 'property', size: 'stat' },
  pd_hot_leads: { label: 'Hot leads — call now', module: 'property_deals_tasks', size: 'full' },
  pd_due_soon: { label: 'Due this week', module: 'property_deals_tasks', size: 'full' },
  pd_deals_at_risk: { label: 'Deals at risk', module: 'property_deals_deals', source: 'property', size: 'full' },
};

export const LAYOUTS: Record<'general' | BusinessType, WidgetId[]> = {
  general: ['users', 'orders', 'products', 'stores', 'revenue', 'orders_chart', 'health', 'recent_orders'],
  ecommerce: ['users', 'orders', 'products', 'stores', 'revenue', 'orders_chart', 'health', 'recent_orders'],
  property_portfolio_manager: [
    'pd_active_deals', 'pd_due_today', 'pd_overdue', 'pd_hot_leads_count', 'pd_money_at_risk', 'pd_renovations',
    'pd_approvals', 'pd_hot_leads', 'pd_due_soon', 'pd_deals_at_risk', 'recent_orders',
  ],
  // Until these have their own widgets they start from the general layout.
  field_service: ['users', 'orders', 'revenue', 'health'],
  professional_services: ['users', 'orders', 'revenue', 'orders_chart', 'health'],
  healthcare: ['users', 'health'],
  care_home: ['users', 'health'],
  accounting: ['users', 'revenue', 'orders_chart', 'health'],
};

/** The widget ids for a workspace, in order. Unknown ids in settings are dropped. */
export function resolveLayout(businessType?: string | null, settings?: Record<string, unknown> | null): WidgetId[] {
  const custom = settings?.dashboard_widgets;
  if (Array.isArray(custom)) {
    const ids = custom.filter((x): x is WidgetId => typeof x === 'string' && (WIDGET_IDS as readonly string[]).includes(x));
    if (ids.length > 0) return ids;
  }
  const key = (businessType || 'general') as keyof typeof LAYOUTS;
  return LAYOUTS[key] || LAYOUTS.general;
}
