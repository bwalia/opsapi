import apiClient, { toFormData } from '@/lib/api-client';
import type { Order, PaginatedResponse, PaginationParams, OrderStatus, PaymentStatus } from '@/types';

export interface OrderFilters extends PaginationParams {
  status?: OrderStatus;
  paymentStatus?: PaymentStatus;
  storeUuid?: string;
  customerUuid?: string;
}

export const ordersService = {
  async getOrders(params: OrderFilters = {}): Promise<PaginatedResponse<Order>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.status) queryParams.status = params.status;
    if (params.paymentStatus) queryParams.payment_status = params.paymentStatus;
    if (params.storeUuid) queryParams.store_uuid = params.storeUuid;

    const response = await apiClient.get('/api/v2/orders', { params: queryParams });

    // Handle API response - could be array or { data, total }
    const orders = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || orders.length;

    return {
      data: orders,
      total,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil(total / (params.perPage || 10)),
    };
  },

  async getOrder(uuid: string): Promise<Order> {
    const response = await apiClient.get(`/api/v2/orders/${uuid}`);
    return response.data;
  },

  async updateOrderStatus(uuid: string, status: OrderStatus): Promise<Order> {
    const response = await apiClient.put(
      `/api/v2/orders/${uuid}/status`,
      toFormData({ status })
    );
    return response.data;
  },

  async deleteOrder(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/orders/${uuid}`);
  },
};

export default ordersService;
