'use client';

import { createContext, useContext } from 'react';
import type { SupplierMe } from '@/services/supplier-portal.service';

/** Who is signed in to the supplier portal (GET /supplier-portal/me), set by app/supplier/layout.tsx. */
export const SupplierPortalContext = createContext<SupplierMe | null>(null);

export function useSupplierMe(): SupplierMe | null {
  return useContext(SupplierPortalContext);
}
