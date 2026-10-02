'use client';

import React from 'react';
import { ProtectedPage } from '@/components/permissions';
import { ProductEditor } from '@/components/shop/ProductEditor';

export default function NewShopProductPage() {
  return (
    <ProtectedPage module="shop" action="create" title="New Product">
      <ProductEditor />
    </ProtectedPage>
  );
}
