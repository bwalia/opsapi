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

// Create from timesheet payload. Only the timesheet is required — the backend
// derives the customer, line items, and rate (per-entry → timesheet → hourly_rate).
export interface TimesheetInvoicePayload {
  timesheet_uuid: string;
  hourly_rate?: number;
  due_date?: string;
  currency?: string;
}

// One un-invoiced billable entry in a customer-billing preview.
export interface CustomerBillableEntry {
  entry_id: number;
  timesheet_uuid: string;
  entry_date: string;
  description?: string;
  task_reference?: string;
  project_reference?: string;
  hours: number;
  rate: number;
  amount: number;
  has_rate: boolean;
}

// Preview of a customer's un-invoiced work over a period (read-only).
export interface CustomerBillablePreview {
  customer: { uuid: string; name?: string | null; email?: string | null };
  period: { from?: string | null; to?: string | null };
  currency: string;
  entries: CustomerBillableEntry[];
  totals: { count: number; total_hours: number; total_amount: number; missing_rate: boolean };
}

// Payload to generate one invoice from a customer's approved timesheets.
export interface CustomerInvoicePayload {
  customer_uuid: string;
  period_start?: string;
  period_end?: string;
  hourly_rate?: number;
  due_date?: string;
  currency?: string;
}

// Map a backend invoice (total_amount / tax_amount / line_items[].line_total) onto
// the frontend Invoice shape (total / tax_total / items[].total) the pages expect.
function normalizeInvoice(raw: Record<string, unknown> | null | undefined): Invoice {
  const r = (raw ?? {}) as Record<string, unknown>;
  const num = (v: unknown) => Number(v ?? 0) || 0;
  const rawItems = Array.isArray(r.line_items)
    ? (r.line_items as Record<string, unknown>[])
    : Array.isArray(r.items)
      ? (r.items as Record<string, unknown>[])
      : [];
  return {
    ...(r as unknown as Invoice),
    uuid: (r.uuid ?? r.id) as string,
    subtotal: num(r.subtotal),
    tax_total: num(r.tax_amount ?? r.tax_total),
    total: num(r.total_amount ?? r.total),
    amount_paid: num(r.amount_paid),
    balance_due: num(r.balance_due),
    items: rawItems.map((li) => ({
      ...(li as unknown as InvoiceLineItem),
      uuid: (li.uuid ?? li.id) as string,
      quantity: num(li.quantity),
      unit_price: num(li.unit_price),
      tax_rate: num(li.tax_rate),
      tax_amount: num(li.tax_amount),
      total: num(li.line_total ?? li.total),
    })),
    payments: Array.isArray(r.payments) ? (r.payments as InvoicePayment[]) : [],
  };
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

    // Backend shape: { success, data: [...], meta: { total, page, perPage, totalPages } }
    // Pagination lives in `meta`, not at the top level.
    const body = response.data ?? {};
    const list = Array.isArray(body.data) ? body.data : [];
    const meta = body.meta ?? {};
    const page = meta.page ?? params.page ?? 1;
    const totalPages = meta.totalPages ?? 0;

    return {
      data: list.map(normalizeInvoice),
      total: meta.total ?? list.length,
      page,
      per_page: meta.perPage ?? params.perPage ?? 10,
      total_pages: totalPages,
      has_next: page < totalPages,
      has_prev: page > 1,
    };
  },

  /**
   * Get single invoice with full details
   */
  async getInvoice(uuid: string): Promise<Invoice> {
    const response = await apiClient.get(`/api/v2/invoices/${uuid}`);
    return normalizeInvoice(response.data?.data ?? response.data);
  },

  /**
   * Create a new invoice
   */
  async createInvoice(data: InvoicePayload): Promise<Invoice> {
    const response = await apiClient.post('/api/v2/invoices', toFormData(data as unknown as Record<string, unknown>));
    return normalizeInvoice(response.data?.data ?? response.data);
  },

  /**
   * Update an existing invoice
   */
  async updateInvoice(uuid: string, data: Partial<InvoicePayload>): Promise<Invoice> {
    const response = await apiClient.put(`/api/v2/invoices/${uuid}`, toFormData(data as unknown as Record<string, unknown>));
    return normalizeInvoice(response.data?.data ?? response.data);
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
    const r = (response.data?.data ?? response.data ?? {}) as Record<string, unknown>;
    const num = (v: unknown) => Number(v ?? 0) || 0;
    const byStatus = Array.isArray(r.by_status) ? (r.by_status as Record<string, unknown>[]) : [];
    const count = (s: string) => byStatus.filter((b) => b.status === s).reduce((a, b) => a + num(b.count), 0);
    return {
      total_invoiced: num(r.total_invoiced),
      total_paid: num(r.total_paid),
      total_outstanding: num(r.total_outstanding),
      total_overdue: num(r.total_overdue),
      invoice_count: byStatus.reduce((a, b) => a + num(b.count), 0),
      paid_count: count('paid'),
      outstanding_count: count('sent'),
      overdue_count: num(r.overdue_count),
    };
  },

  /**
   * Preview a customer's un-invoiced billable work over a period (read-only).
   */
  async getCustomerBillable(
    customerUuid: string,
    from?: string,
    to?: string,
    hourlyRate?: number
  ): Promise<CustomerBillablePreview> {
    const params: Record<string, string | number> = { customer_uuid: customerUuid };
    if (from) params.from = from;
    if (to) params.to = to;
    if (hourlyRate != null) params.hourly_rate = hourlyRate;
    const response = await apiClient.get('/api/v2/invoices/customer-billable', { params });
    return response.data?.data ?? response.data;
  },

  /**
   * Generate one invoice from a customer's approved timesheets over a period.
   */
  async createFromCustomer(data: CustomerInvoicePayload): Promise<Invoice> {
    const response = await apiClient.post(
      '/api/v2/invoices/from-customer',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return normalizeInvoice(response.data?.data ?? response.data);
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
    return normalizeInvoice(response.data?.data ?? response.data);
  },
};

export default invoicesService;
