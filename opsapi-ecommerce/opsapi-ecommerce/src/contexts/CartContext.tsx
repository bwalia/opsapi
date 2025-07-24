'use client';
import { createContext, useContext, useState, useEffect, ReactNode } from 'react';
import api from '@/lib/api';

interface CartItem {
  product_uuid: string;
  name: string;
  price: number;
  quantity: number;
}

interface CartContextType {
  cart: Record<string, CartItem>;
  total: number;
  itemCount: number;
  loading: boolean;
  addToCart: (productUuid: string, quantity?: number) => Promise<void>;
  removeFromCart: (productUuid: string) => Promise<void>;
  clearCart: () => Promise<void>;
  refreshCart: () => Promise<void>;
}

const CartContext = createContext<CartContextType | undefined>(undefined);

export function CartProvider({ children }: { children: ReactNode }) {
  const [cart, setCart] = useState<Record<string, CartItem>>({});
  const [total, setTotal] = useState(0);
  const [itemCount, setItemCount] = useState(0);
  const [loading, setLoading] = useState(false);

  const refreshCart = async () => {
    try {
      setLoading(true);
      const response = await api.getCart();
      setCart(response?.cart || {});
      setTotal(response?.total || 0);
      
      // Calculate item count
      const count = Object.values(response?.cart || {}).reduce(
        (sum: number, item: any) => sum + (item?.quantity || 0), 
        0
      );
      setItemCount(count);
    } catch (error) {
      console.error('Failed to load cart:', error);
      setCart({});
      setTotal(0);
      setItemCount(0);
    } finally {
      setLoading(false);
    }
  };

  const addToCart = async (productUuid: string, quantity: number = 1) => {
    try {
      setLoading(true);
      await api.addToCart({ product_uuid: productUuid, quantity });
      await refreshCart();
    } catch (error) {
      console.error('Failed to add to cart:', error);
      throw error;
    } finally {
      setLoading(false);
    }
  };

  const removeFromCart = async (productUuid: string) => {
    try {
      setLoading(true);
      await api.removeFromCart(productUuid);
      await refreshCart();
    } catch (error) {
      console.error('Failed to remove from cart:', error);
      throw error;
    } finally {
      setLoading(false);
    }
  };

  const clearCart = async () => {
    try {
      setLoading(true);
      await api.clearCart();
      setCart({});
      setTotal(0);
      setItemCount(0);
    } catch (error) {
      console.error('Failed to clear cart:', error);
      throw error;
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    refreshCart();
  }, []);

  return (
    <CartContext.Provider value={{
      cart,
      total,
      itemCount,
      loading,
      addToCart,
      removeFromCart,
      clearCart,
      refreshCart
    }}>
      {children}
    </CartContext.Provider>
  );
}

export function useCart() {
  const context = useContext(CartContext);
  if (context === undefined) {
    throw new Error('useCart must be used within a CartProvider');
  }
  return context;
}
