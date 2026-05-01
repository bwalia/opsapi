import apiClient, { toFormData } from '@/lib/api-client';

// Invoice status type
export type InvoiceStatus = 'draft' | 'sent' | 'paid' | 'partially_paid' | 'overdue' | 'cancelled' | 'void';

// Invoice filters for server-side filtering
export interface InvoiceFilters {
  page?: number;
  perPage?: number;
  status?: InvoiceStatus | 'all';
  search?: string;
  dateFrom?: string;
  dateTo?: string;
  orderBy?: 'created_at' | 'updated_at' | 'invoice_number' | 'total' | 'due_date' | 'issue_date';
  orderDir?: 'asc' | 'desc';
}

// Line item
export interface InvoiceLineItem {
  uuid: string;
  invoice_uuid: string;
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate?: number;
  tax_amount?: number;
  total: number;
  created_at: string;
  updated_at: string;
}

// Payment
export interface InvoicePayment {
  uuid: string;
  invoice_uuid: string;
  amount: number;
  payment_method: string;
  payment_date: string;
  reference?: string;
  notes?: string;
  created_at: string;
}

// Invoice
export interface Invoice {
  uuid: string;
  invoice_number: string;
  status: InvoiceStatus;
  customer_name: string;
  customer_email?: string;
  issue_date: string;
  due_date: string;
  currency: string;
  subtotal: number;
  tax_total: number;
  total: number;
  amount_paid: number;
  balance_due: number;
  notes?: string;
  payment_terms_days?: number;
  items?: InvoiceLineItem[];
  payments?: InvoicePayment[];
  created_at: string;
  updated_at: string;
}

// Paginated response from API
export interface InvoicesResponse {
  data: Invoice[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
  has_next: boolean;
  has_prev: boolean;
}

// Dashboard statistics
export interface InvoiceDashboardStats {
  total_invoiced: number;
  total_paid: number;
  total_outstanding: number;
  total_overdue: number;
  invoice_count: number;
  paid_count: number;
  outstanding_count: number;
  overdue_count: number;
}

// Tax rate
export interface TaxRate {
  uuid: string;
  name: string;
  rate: number;
  is_default?: boolean;
}

// Create/update invoice payload
export interface InvoicePayload {
  customer_name: string;
  customer_email?: string;
  issue_date: string;
  due_date: string;
  currency?: string;
  notes?: string;
  payment_terms_days?: number;
}

// Line item payload
export interface LineItemPayload {
  description: string;
  quantity: number;
  unit_price: number;
  tax_rate?: number;
}

// Payment payload
export interface PaymentPayload {
  amount: number;
  payment_method: string;
  payment_date: string;
  reference?: string;
  notes?: string;
}

// Create from timesheet payload
export interface TimesheetInvoicePayload {
  timesheet_uuid: string;
  customer_name: string;
  customer_email?: string;
  hourly_rate: number;
  due_date: string;
  currency?: string;
  notes?: string;
}

export const invoicesService = {
  /**
   * Get invoices with server-side pagination and filtering
   */
  async getInvoices(params: InvoiceFilters = {}): Promise<InvoicesResponse> {
    const queryParams: Record<string, string | number> = {};

    // Pagination
    if (params.page) queryParams.page = params.page;
    if (params.perPage) queryParams.per_page = params.perPage;

    // Filters
    if (params.status && params.status !== 'all') queryParams.status = params.status;
    if (params.search) queryParams.search = params.search;
    if (params.dateFrom) queryParams.date_from = params.dateFrom;
    if (params.dateTo) queryParams.date_to = params.dateTo;

    // Sorting
    if (params.orderBy) queryParams.order_by = params.orderBy;
    if (params.orderDir) queryParams.order_dir = params.orderDir;

    const response = await apiClient.get('/api/v2/invoices', { params: queryParams });

    const data = Array.isArray(response.data?.data) ? response.data.data : [];

    return {
      data,
      total: response.data?.total || 0,
      page: response.data?.page || params.page || 1,
      per_page: response.data?.per_page || params.perPage || 10,
      total_pages: response.data?.total_pages || 0,
      has_next: response.data?.has_next || false,
      has_prev: response.data?.has_prev || false,
    };
  },

  /**
   * Get single invoice with full details
   */
  async getInvoice(uuid: string): Promise<Invoice> {
    const response = await apiClient.get(`/api/v2/invoices/${uuid}`);
    return response.data;
  },

  /**
   * Create a new invoice
   */
  async createInvoice(data: InvoicePayload): Promise<Invoice> {
    const response = await apiClient.post('/api/v2/invoices', toFormData(data as unknown as Record<string, unknown>));
    return response.data;
  },

  /**
   * Update an existing invoice
   */
  async updateInvoice(uuid: string, data: Partial<InvoicePayload>): Promise<Invoice> {
    const response = await apiClient.put(`/api/v2/invoices/${uuid}`, toFormData(data as unknown as Record<string, unknown>));
    return response.data;
  },

  /**
   * Delete an invoice
   */
  async deleteInvoice(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/invoices/${uuid}`);
  },

  /**
   * Send an invoice to the customer
   */
  async sendInvoice(uuid: string): Promise<{ message: string }> {
    const response = await apiClient.post(`/api/v2/invoices/${uuid}/send`);
    return response.data;
  },

  /**
   * Void an invoice
   */
  async voidInvoice(uuid: string): Promise<{ message: string }> {
    const response = await apiClient.post(`/api/v2/invoices/${uuid}/void`);
    return response.data;
  },

  /**
   * Add a line item to an invoice
   */
  async addLineItem(uuid: string, data: LineItemPayload): Promise<InvoiceLineItem> {
    const response = await apiClient.post(
      `/api/v2/invoices/${uuid}/items`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Update a line item
   */
  async updateLineItem(itemUuid: string, data: Partial<LineItemPayload>): Promise<InvoiceLineItem> {
    const response = await apiClient.put(
      `/api/v2/invoices/items/${itemUuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Delete a line item
   */
  async deleteLineItem(itemUuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/invoices/items/${itemUuid}`);
  },

  /**
   * Record a payment against an invoice
   */
  async recordPayment(uuid: string, data: PaymentPayload): Promise<InvoicePayment> {
    const response = await apiClient.post(
      `/api/v2/invoices/${uuid}/payments`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Get payments for an invoice
   */
  async getPayments(uuid: string): Promise<InvoicePayment[]> {
    const response = await apiClient.get(`/api/v2/invoices/${uuid}/payments`);
    return response.data?.data || [];
  },

  /**
   * Get dashboard statistics
   */
  async getDashboardStats(): Promise<InvoiceDashboardStats> {
    const response = await apiClient.get('/api/v2/invoices/dashboard/stats');
    return response.data;
  },

  /**
   * Get available tax rates
   */
  async getTaxRates(): Promise<TaxRate[]> {
    const response = await apiClient.get('/api/v2/invoices/tax-rates');
    return response.data?.data || [];
  },

  /**
   * Create an invoice from a timesheet
   */
  async createFromTimesheet(data: TimesheetInvoicePayload): Promise<Invoice> {
    const response = await apiClient.post(
      '/api/v2/invoices/from-timesheet',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data;
  },
};

export default invoicesService;
