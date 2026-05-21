import apiClient from '@/lib/api-client';
import type { DashboardStats, HealthStatus, Order, HealthCheck } from '@/types';

export const dashboardService = {
  /**
   * Get dashboard statistics
   * Uses health endpoint for counts and orders endpoint for recent orders
   */
  async getDashboardStats(): Promise<DashboardStats> {
    // Use allSettled, NOT all: orders/products are ecommerce-only endpoints and
    // 500/404 on projects that don't enable that feature (e.g. tax_copilot).
    // With Promise.all, the first rejection short-circuits and the remaining
    // rejected promises become *unhandled* rejections (surfaced by the Next.js
    // dev overlay). allSettled handles every outcome, so a missing endpoint
    // just degrades that stat to 0 instead of breaking the whole dashboard.
    const [healthSettled, ordersSettled, productsSettled] = await Promise.allSettled([
      apiClient.get('/health', { params: { detailed: 'true' } }),
      apiClient.get('/api/v2/orders', { params: { limit: 10 } }),
      apiClient.get('/api/v2/products', { params: { limit: 1 } }),
    ]);

    const healthRes = healthSettled.status === 'fulfilled' ? healthSettled.value : null;
    const ordersRes = ordersSettled.status === 'fulfilled' ? ordersSettled.value : null;
    const productsRes = productsSettled.status === 'fulfilled' ? productsSettled.value : null;

    // Extract database stats from health check (the always-available endpoint)
    const healthData = (healthRes?.data ?? {}) as HealthStatus;
    const databaseCheck = healthData.checks?.find(
      (c: HealthCheck) => c.name === 'database'
    );
    const dbDetails = databaseCheck?.details;

    // Handle different response structures; default to empty when unavailable.
    const recentOrders: Order[] = Array.isArray(ordersRes?.data)
      ? ordersRes!.data
      : ordersRes?.data?.data || [];
    const totalRevenue = recentOrders.reduce(
      (sum, order) => sum + (Number(order.total) || 0),
      0
    );

    // Generate mock revenue by month data (until API provides this)
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];
    const revenueByMonth = months.map((month) => ({
      month,
      revenue: Math.floor(Math.random() * 50000) + 10000,
    }));

    return {
      totalUsers: dbDetails?.total_users || 0,
      totalOrders: dbDetails?.total_orders || ordersRes?.data?.total || 0,
      totalProducts: productsRes?.data?.total || productsRes?.data?.length || 0,
      totalStores: dbDetails?.total_stores || 0,
      totalRevenue,
      recentOrders,
      ordersByStatus: [],
      revenueByMonth,
    };
  },

  /**
   * Get API health status
   */
  async getHealthStatus(detailed: boolean = false): Promise<HealthStatus> {
    try {
      const endpoint = detailed ? '/health?detailed=true' : '/health';
      const response = await apiClient.get(endpoint);
      return response.data;
    } catch {
      return {
        status: 'unhealthy',
        timestamp: Date.now(),
      };
    }
  },
};

export default dashboardService;
