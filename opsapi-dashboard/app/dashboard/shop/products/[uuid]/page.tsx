'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { ProtectedPage } from '@/components/permissions';
import { ProductEditor } from '@/components/shop/ProductEditor';
import { ShopError, ShopLoading } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import type { ShopProduct } from '@/types/shop';

function EditProduct() {
  const params = useParams();
  const uuid = String(params?.uuid ?? '');
  const [product, setProduct] = useState<ShopProduct | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getProduct(uuid)
      .then((p) => {
        if (!active) return;
        setProduct(p);
        setError(null);
      })
      .catch((err) => active && setError(extractApiError(err, 'Failed to load product')));
    return () => {
      active = false;
    };
  }, [uuid, version]);

  if (error) return <ShopError message={error} onRetry={reload} />;
  if (!product) return <ShopLoading label="Loading product…" />;
  return <ProductEditor product={product} onReload={reload} />;
}

export default function EditShopProductPage() {
  return (
    <ProtectedPage module="shop" title="Shop Product">
      <EditProduct />
    </ProtectedPage>
  );
}
