'use client';

import React, { useMemo, useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Users, ShoppingCart, Package, Store, DollarSign, Handshake, CalendarClock, AlertTriangle, Flame, PoundSterling, Hammer, Inbox } from 'lucide-react';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useMenu } from '@/hooks';
import { StatsCard, RecentOrdersTable, OrdersChart, HealthStatus } from '@/components/dashboard';
import { PendingInvitationsBanner } from '@/components/namespace/invitations';
import { Stagger, RevealItem } from '@/components/motion/Reveal';
import { dashboardService } from '@/services';
import { formatCurrency } from '@/lib/utils';
import { useDataFetch } from '@/hooks';
import { useNamespace } from '@/contexts/NamespaceContext';
import { resolveLayout, WIDGETS, type WidgetId } from '@/components/dashboard/home/widgets';
import { fetchPropertySummary, propertyStat, DealsAtRisk, type PropertySummary } from '@/components/dashboard/home/PropertyWidgets';
import HotLeads from '@/components/property-deals/HotLeads';
import DueSoon from '@/components/property-deals/DueSoon';
import type { DashboardStats, HealthStatus as HealthStatusType, NamespaceModule } from '@/types';

// Static icons - defined outside component to prevent recreation
const STAT_ICONS = {
  users: <Users className="w-6 h-6" />,
  orders: <ShoppingCart className="w-6 h-6" />,
  products: <Package className="w-6 h-6" />,
  stores: <Store className="w-6 h-6" />,
  revenue: <DollarSign className="w-6 h-6" />,
  pd_active_deals: <Handshake className="w-6 h-6" />,
  pd_due_today: <CalendarClock className="w-6 h-6" />,
  pd_overdue: <AlertTriangle className="w-6 h-6" />,
  pd_hot_leads_count: <Flame className="w-6 h-6" />,
  pd_money_at_risk: <PoundSterling className="w-6 h-6" />,
  pd_renovations: <Hammer className="w-6 h-6" />,
  pd_approvals: <Inbox className="w-6 h-6" />,
} as Record<string, React.ReactNode>;

// One fetch per data source, only for the sources the visible widgets need.
const fetchDashboardData = async (needs: { core: boolean; property: boolean; health: boolean }) => {
  const [stats, health, property] = await Promise.all([
    needs.core ? dashboardService.getDashboardStats() : Promise.resolve(null),
    needs.health ? dashboardService.getHealthStatus(true) : Promise.resolve(null),
    needs.property ? fetchPropertySummary() : Promise.resolve(undefined),
  ]);
  return { stats, health, property };
};

export default function DashboardPage() {
  const router = useRouter();
  const { isLoading: permsLoading, landingPath, canRead } = usePermissions();
  const { currentNamespace } = useNamespace();
  const { isHydrated: menuHydrated, isLoading: menuLoading } = useMenu();

  // Post-login landing is DATA-DRIVEN: each namespace role carries a
  // `landing_path` (configured per tenant when the role is created/edited), so a
  // field-service / hospital / e-commerce / any namespace routes its own roles
  // with zero hardcoding here. No landing_path (or it points at this page) =>
  // the user stays on the default dashboard.
  const menuReady = menuHydrated && !menuLoading;
  const shouldRedirect = !!landingPath && landingPath !== '/dashboard';

  useEffect(() => {
    if (permsLoading || !menuReady) return;
    if (shouldRedirect && landingPath) {
      router.replace(landingPath);
    }
  }, [permsLoading, menuReady, shouldRedirect, landingPath, router]);

  // The workspace's widgets (business type default or its own list), minus what this person can't read.
  const widgets = useMemo<WidgetId[]>(() => {
    if (permsLoading) return [];
    const settings = (currentNamespace?.settings || null) as Record<string, unknown> | null;
    return resolveLayout(currentNamespace?.business_type, settings).filter((id) =>
      canRead(WIDGETS[id].module as NamespaceModule));
  }, [currentNamespace?.business_type, currentNamespace?.settings, canRead, permsLoading]);
  const needs = useMemo(() => ({
    core: widgets.some((id) => WIDGETS[id].source === 'core'),
    property: widgets.some((id) => WIDGETS[id].source === 'property'),
    health: widgets.includes('health'),
  }), [widgets]);
  const needsKey = `${needs.core}|${needs.property}|${needs.health}`;

  const fetcher = useCallback(() => fetchDashboardData(needs), [needs]);
  const { data, isLoading, refetch } = useDataFetch<{
    stats: DashboardStats | null;
    health: HealthStatusType | null;
    property?: PropertySummary;
  }>(fetcher, [needsKey]);

  // Memoize stats and health data extraction
  const stats = useMemo(() => data?.stats ?? null, [data?.stats]);
  const health = useMemo(() => data?.health ?? null, [data?.health]);
  const property = data?.property;

  const CORE_STATS: Record<string, { value: string | number }> = useMemo(() => ({
    users: { value: stats?.totalUsers || 0 },
    orders: { value: stats?.totalOrders || 0 },
    products: { value: stats?.totalProducts || 0 },
    stores: { value: stats?.totalStores || 0 },
    revenue: { value: formatCurrency(stats?.totalRevenue || 0) },
  }), [stats]);

  const statsCards = useMemo(
    () => widgets.filter((id) => WIDGETS[id].size === 'stat').map((id) => {
      const p = id.startsWith('pd_') ? propertyStat(id, property) : { ...CORE_STATS[id], description: undefined };
      return { id, title: WIDGETS[id].label, value: p.value, icon: STAT_ICONS[id], description: p.description };
    }),
    [widgets, property, CORE_STATS]
  );

  // Memoize chart data
  const chartData = useMemo(() => stats?.revenueByMonth || [], [stats?.revenueByMonth]);

  // Memoize recent orders
  const recentOrders = useMemo(() => stats?.recentOrders || [], [stats?.recentOrders]);

  // Memoize refresh handler to prevent inline function recreation
  // Redirecting field-service users away — don't flash the e-commerce dashboard
  // while we wait for the menu to tell us the tenant's shape.
  const redirecting = permsLoading || !menuReady || shouldRedirect;

  const handleRefresh = useCallback(() => {
    refetch();
  }, [refetch]);

  if (redirecting) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-6 h-6 animate-spin" />
      </div>
    );
  }

  return (
    <Stagger className="space-y-5 sm:space-y-6">
      {/* Pending Invitations Banner */}
      <PendingInvitationsBanner />

      {/* Hero header — brand gradient welcome */}
      <RevealItem>
        <div className="relative overflow-hidden rounded-2xl gradient-primary text-white p-6 sm:p-8 shadow-lg shadow-primary-500/20">
          <div className="pointer-events-none absolute -top-16 -right-10 w-72 h-72 rounded-full bg-white/10 blur-3xl" />
          <div className="pointer-events-none absolute -bottom-24 -left-12 w-72 h-72 rounded-full bg-black/10 blur-3xl" />
          <div className="relative flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
            <div>
              <h1 className="text-3xl sm:text-4xl font-extrabold tracking-tight">Welcome back 👋</h1>
              <p className="text-white/85 mt-2 text-base max-w-xl">
                Here&apos;s what&apos;s happening with your business today.
              </p>
            </div>
            <div className="flex items-center gap-2 text-xs sm:text-sm">
              <span className="inline-flex items-center gap-2 rounded-full bg-white/15 backdrop-blur-sm px-3 py-1.5 font-semibold ring-1 ring-white/20">
                <span className="w-2 h-2 rounded-full bg-emerald-300 animate-pulse" />
                {health?.status === 'healthy' ? 'All systems operational' : 'Live overview'}
              </span>
            </div>
          </div>
        </div>
      </RevealItem>

      {/* Stats Cards — responsive grid, each card staggers in */}
      <Stagger
        className={`grid grid-cols-2 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 ${statsCards.length > 5 ? 'xl:grid-cols-4 2xl:grid-cols-7' : 'xl:grid-cols-5'} gap-3 sm:gap-4 lg:gap-6`}
        gap={0.06}
      >
        {statsCards.map((card) => (
          <RevealItem key={card.id}>
            <StatsCard
              title={card.title}
              value={card.value}
              icon={card.icon}
              description={card.description}
              isLoading={isLoading}
            />
          </RevealItem>
        ))}
      </Stagger>

      {/* Panels, in the layout's order. Chart + health share a row when both are shown. */}
      {(widgets.includes('orders_chart') || widgets.includes('health')) && (
        <RevealItem>
          <div className="grid grid-cols-1 xl:grid-cols-3 gap-4 sm:gap-6 xl:h-[480px]">
            {widgets.includes('orders_chart') && (
              <div className={`${widgets.includes('health') ? 'xl:col-span-2' : 'xl:col-span-3'} order-2 xl:order-1 min-h-0`}>
                <OrdersChart data={chartData} isLoading={isLoading} />
              </div>
            )}
            {widgets.includes('health') && (
              <div className={`${widgets.includes('orders_chart') ? '' : 'xl:col-span-3'} order-1 xl:order-2 min-h-0`}>
                <HealthStatus health={health} isLoading={isLoading} onRefresh={handleRefresh} />
              </div>
            )}
          </div>
        </RevealItem>
      )}

      {widgets.filter((id) => WIDGETS[id].size === 'full').map((id) => (
        <RevealItem key={id}>
          {id === 'recent_orders' && <RecentOrdersTable orders={recentOrders} isLoading={isLoading} />}
          {id === 'pd_hot_leads' && <HotLeads />}
          {id === 'pd_due_soon' && <DueSoon />}
          {id === 'pd_deals_at_risk' && <DealsAtRisk summary={property} />}
        </RevealItem>
      ))}
    </Stagger>
  );
}
