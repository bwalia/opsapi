'use client';
import { useState, useEffect } from 'react';
import ProductCard from '@/components/ProductCard';
import api from '@/lib/api';

interface Product {
  uuid: string;
  name: string;
  description: string;
  price: number;
  inventory_quantity: number;
  images?: string[];
}

export default function Home() {
  const [products, setProducts] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    loadProducts();
  }, []);

  const loadProducts = async () => {
    try {
      setLoading(true);
      setError('');
      const response = await api.getProducts({ page: 1, perPage: 20 });
      
      // Handle different response structures
      if (response && Array.isArray(response.data)) {
        setProducts(response.data);
      } else if (response && Array.isArray(response)) {
        setProducts(response);
      } else {
        setProducts([]);
      }
    } catch (err: any) {
      console.error('Failed to load products:', err);
      setError(err.message || 'Failed to load products');
      setProducts([]);
    } finally {
      setLoading(false);
    }
  };

  const handleAddToCart = () => {
    console.log('Product added to cart');
  };

  if (loading) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center">Loading products...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center text-red-600">Error: {error}</div>
      </div>
    );
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-4">Featured Products</h1>
        <p className="text-gray-600">Discover amazing products from our multi-tenant marketplace</p>
      </div>

      {!products || products.length === 0 ? (
        <div className="text-center py-12">
          <div className="max-w-md mx-auto">
            <div className="text-6xl mb-4">🛍️</div>
            <h2 className="text-xl font-semibold text-gray-700 mb-2">No Products Yet</h2>
            <p className="text-gray-500 mb-4">Be the first to add products to our marketplace!</p>
            <p className="text-sm text-gray-400">Sellers can register and create stores to start selling.</p>
          </div>
        </div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-6">
          {products.map((product) => (
            <ProductCard
              key={product.uuid}
              product={product}
              onAddToCart={handleAddToCart}
            />
          ))}
        </div>
      )}
    </div>
  );
}