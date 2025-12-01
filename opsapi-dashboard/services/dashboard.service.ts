import apiClient from '@/lib/api-client';
import type { DashboardStats, HealthStatus, Order } from '@/types';

export const dashboardService = {
  /**
   * Get dashboard statistics
   */
  async getDashboardStats(): Promise<DashboardStats> {
    try {
      const [usersRes, ordersRes, productsRes, storesRes] = await Promise.all([
        apiClient.get('/api/v2/users', { params: { limit: 1 } }),
        apiClient.get('/api/v2/orders', { params: { limit: 10 } }),
        apiClient.get('/api/v2/products', { params: { limit: 1 } }),
        apiClient.get('/api/v2/stores', { params: { limit: 1 } }),
      ]);

      // Handle different response structures from API
      const recentOrders: Order[] = Array.isArray(ordersRes.data)
        ? ordersRes.data
        : ordersRes.data?.data || [];
      const totalRevenue = recentOrders.reduce((sum, order) => sum + (Number(order.total) || 0), 0);

      // Generate mock revenue by month data (until API provides this)
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];
      const revenueByMonth = months.map((month) => ({
        month,
        revenue: Math.floor(Math.random() * 50000) + 10000,
      }));

      return {
        totalUsers: usersRes.data?.total || usersRes.data?.length || 0,
        totalOrders: ordersRes.data?.total || ordersRes.data?.length || 0,
        totalProducts: productsRes.data?.total || productsRes.data?.length || 0,
        totalStores: storesRes.data?.total || storesRes.data?.length || 0,
        totalRevenue,
        recentOrders,
        ordersByStatus: [],
        revenueByMonth,
      };
    } catch (error) {
      console.error('Failed to fetch dashboard stats:', error);
      return {
        totalUsers: 0,
        totalOrders: 0,
        totalProducts: 0,
        totalStores: 0,
        totalRevenue: 0,
        recentOrders: [],
        ordersByStatus: [],
        revenueByMonth: [],
      };
    }
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
