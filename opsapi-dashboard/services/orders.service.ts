import apiClient, { toFormData } from '@/lib/api-client';
import type { Order, OrderStatus, PaymentStatus } from '@/types';

// Order filters for server-side filtering
export interface OrderFilters {
  page?: number;
  perPage?: number;
  status?: OrderStatus | 'all';
  paymentStatus?: PaymentStatus | 'all';
  fulfillmentStatus?: string;
  storeUuid?: string;
  search?: string;
  dateFrom?: string;
  dateTo?: string;
  orderBy?: 'created_at' | 'updated_at' | 'order_number' | 'total_amount' | 'status';
  orderDir?: 'asc' | 'desc';
}

// Paginated response from API
export interface OrdersResponse {
  data: Order[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
  user_role?: string;
}

// Order statistics
export interface OrderStats {
  total_orders: number;
  pending_orders: number;
  processing_orders: number;
  delivered_orders: number;
  cancelled_orders: number;
  total_revenue: number;
  pending_revenue: number;
}

// Store option for filter dropdown
export interface StoreOption {
  uuid: string;
  name: string;
  owner_name?: string;
}

export const ordersService = {
  /**
   * Get orders with server-side pagination, filtering, and role-based access
   */
  async getOrders(params: OrderFilters = {}): Promise<OrdersResponse> {
    const queryParams: Record<string, string | number> = {};

    // Pagination
    if (params.page) queryParams.page = params.page;
    if (params.perPage) queryParams.per_page = params.perPage;

    // Filters
    if (params.status && params.status !== 'all') queryParams.status = params.status;
    if (params.paymentStatus && params.paymentStatus !== 'all') queryParams.payment_status = params.paymentStatus;
    if (params.fulfillmentStatus && params.fulfillmentStatus !== 'all') queryParams.fulfillment_status = params.fulfillmentStatus;
    if (params.storeUuid && params.storeUuid !== 'all') queryParams.store_uuid = params.storeUuid;
    if (params.search) queryParams.search = params.search;
    if (params.dateFrom) queryParams.date_from = params.dateFrom;
    if (params.dateTo) queryParams.date_to = params.dateTo;

    // Sorting
    if (params.orderBy) queryParams.order_by = params.orderBy;
    if (params.orderDir) queryParams.order_dir = params.orderDir;

    const response = await apiClient.get('/api/v2/orders', { params: queryParams });

    // Ensure data is always an array
    const data = Array.isArray(response.data?.data) ? response.data.data : [];

    return {
      data,
      total: response.data?.total || 0,
      page: response.data?.page || params.page || 1,
      per_page: response.data?.per_page || params.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
      user_role: response.data?.user_role,
    };
  },

  /**
   * Get single order with full details
   */
  async getOrder(uuid: string): Promise<Order> {
    const response = await apiClient.get(`/api/v2/orders/${uuid}`);
    return response.data;
  },

  /**
   * Update order status with optional notes
   */
  async updateOrderStatus(
    uuid: string,
    status: OrderStatus,
    options?: { financialStatus?: string; fulfillmentStatus?: string; notes?: string }
  ): Promise<{ message: string; order: Order }> {
    const payload: Record<string, string> = { status };
    if (options?.financialStatus) payload.financial_status = options.financialStatus;
    if (options?.fulfillmentStatus) payload.fulfillment_status = options.fulfillmentStatus;
    if (options?.notes) payload.notes = options.notes;

    const response = await apiClient.put(`/api/v2/orders/${uuid}/status`, payload, {
      headers: { 'Content-Type': 'application/json' }
    });
    return response.data;
  },

  /**
   * Get order statistics (role-aware)
   */
  async getOrderStats(): Promise<OrderStats> {
    const response = await apiClient.get('/api/v2/orders/stats');
    return response.data;
  },

  /**
   * Get available stores for filter dropdown
   */
  async getStores(): Promise<StoreOption[]> {
    const response = await apiClient.get('/api/v2/orders/stores');
    return response.data?.data || [];
  },

  /**
   * Delete order (admin only)
   */
  async deleteOrder(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/orders/${uuid}`);
  },

  /**
   * Update order details
   */
  async updateOrder(uuid: string, data: Partial<Order>): Promise<Order> {
    const response = await apiClient.put(`/api/v2/orders/${uuid}`, toFormData(data as Record<string, unknown>));
    return response.data;
  },
};

export default ordersService;
