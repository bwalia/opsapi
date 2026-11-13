/**
 * Getting paid: the workspace's bank accounts and other payment methods (RBAC `namespace`;
 * anyone with namespace, invoices or shop read access can list them).
 */
import apiClient from '@/lib/api-client';
import type { PaymentMethodKind, PaymentMethodPublic } from '@/lib/payment-methods';

export interface PaymentMethod extends PaymentMethodPublic {
  uuid: string;
  kind: PaymentMethodKind;
  is_default: boolean;
  show_on_documents: boolean;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export type PaymentMethodInput = Partial<Omit<PaymentMethod, 'uuid' | 'created_at' | 'updated_at'>>;

const data = <T>(res: { data: { data: T } }): T => res.data.data;
const enc = encodeURIComponent;
/** These routes read a JSON body (apiClient defaults to form encoding). */
const JSON_HDR = { headers: { 'Content-Type': 'application/json' } };

export const paymentMethodsService = {
  list: async (includeInactive = false) =>
    data<PaymentMethod[]>(
      await apiClient.get('/api/v2/namespace/payment-methods', { params: includeInactive ? { include_inactive: 'true' } : {} })
    ),
  create: async (input: PaymentMethodInput) =>
    data<PaymentMethod>(await apiClient.post('/api/v2/namespace/payment-methods', input, JSON_HDR)),
  update: async (uuid: string, input: PaymentMethodInput) =>
    data<PaymentMethod>(await apiClient.put(`/api/v2/namespace/payment-methods/${enc(uuid)}`, input, JSON_HDR)),
  remove: async (uuid: string) =>
    data<{ deleted?: boolean; deactivated?: boolean }>(await apiClient.delete(`/api/v2/namespace/payment-methods/${enc(uuid)}`)),
};
