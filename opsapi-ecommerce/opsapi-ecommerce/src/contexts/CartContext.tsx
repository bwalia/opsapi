'use client';
import { createContext, useContext, useState, useEffect, ReactNode } from 'react';
import api from '@/lib/api';

interface CartItem {
  product_uuid: string;
  variant_uuid?: string;
  name: string;
  variant_title?: string;
  price: number;
  quantity: number;
}

interface CartContextType {
  cart: Record<string, CartItem>;
  total: number;
  itemCount: number;
  loading: boolean;
  addToCart: (productUuid: string, quantity?: number, variantUuid?: string) => Promise<void>;
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
      
      // Use localStorage for cart with safe parsing
      let cartData: Record<string, CartItem> = {};
      try {
        const cartString = localStorage.getItem('cart');
        if (cartString) {
          const parsed = JSON.parse(cartString);
          cartData = typeof parsed === 'object' && parsed !== null ? parsed : {};
        }
      } catch (parseError) {
        console.error('Failed to parse cart data:', parseError);
        localStorage.removeItem('cart'); // Clear corrupted data
      }
      
      let totalAmount = 0;
      let count = 0;
      
      Object.values(cartData).forEach((item: any) => {
        if (item && typeof item === 'object' && 
            typeof item.price === 'number' && 
            typeof item.quantity === 'number' && 
            item.price > 0 && item.quantity > 0) {
          totalAmount += item.price * item.quantity;
          count += item.quantity;
        }
      });
      
      setCart(cartData);
      setTotal(totalAmount);
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

  const addToCart = async (productUuid: string, quantity: number = 1, variantUuid?: string) => {
    if (!productUuid || quantity <= 0) {
      throw new Error('Invalid product or quantity');
    }
    
    try {
      setLoading(true);
      
      // Get product details
      const product = await api.getProduct(productUuid);
      if (!product || !product.name) {
        throw new Error('Product not found or invalid');
      }
      
      // Get current cart from localStorage safely
      let currentCart: Record<string, CartItem> = {};
      try {
        const cartString = localStorage.getItem('cart');
        if (cartString) {
          const parsed = JSON.parse(cartString);
          currentCart = typeof parsed === 'object' && parsed !== null ? parsed : {};
        }
      } catch {
        currentCart = {};
      }
      
      // Create cart key
      const cartKey = variantUuid ? `${productUuid}_${variantUuid}` : productUuid;
      
      // Get variant details if needed
      let itemPrice = typeof product.price === 'number' ? product.price : 0;
      let variantTitle: string | undefined = undefined;
      
      if (variantUuid) {
        try {
          const variants = await api.getVariants(productUuid);
          if (Array.isArray(variants)) {
            const variant = variants.find((v: any) => v?.uuid === variantUuid);
            if (variant) {
              itemPrice = typeof variant.price === 'number' ? variant.price : itemPrice;
              variantTitle = variant.title || undefined;
            }
          }
        } catch (variantError) {
          console.error('Failed to load variant details:', variantError);
        }
      }
      
      // Add/update item
      if (currentCart[cartKey] && typeof currentCart[cartKey] === 'object') {
        currentCart[cartKey].quantity = (currentCart[cartKey].quantity || 0) + quantity;
      } else {
        currentCart[cartKey] = {
          product_uuid: productUuid,
          variant_uuid: variantUuid || undefined,
          name: product.name,
          variant_title: variantTitle,
          price: itemPrice,
          quantity: quantity
        };
      }
      
      // Save to localStorage safely
      try {
        localStorage.setItem('cart', JSON.stringify(currentCart));
      } catch (storageError) {
        console.error('Failed to save cart to localStorage:', storageError);
        throw new Error('Failed to save cart');
      }
      
      await refreshCart();
    } catch (error) {
      console.error('Failed to add to cart:', error);
      throw error;
    } finally {
      setLoading(false);
    }
  };

  const removeFromCart = async (productUuid: string) => {
    if (!productUuid) {
      throw new Error('Invalid product UUID');
    }
    
    try {
      setLoading(true);
      
      let currentCart: Record<string, CartItem> = {};
      try {
        const cartString = localStorage.getItem('cart');
        if (cartString) {
          const parsed = JSON.parse(cartString);
          currentCart = typeof parsed === 'object' && parsed !== null ? parsed : {};
        }
      } catch {
        currentCart = {};
      }
      
      // Remove all variants of this product
      Object.keys(currentCart).forEach(key => {
        if (key === productUuid || key.startsWith(`${productUuid}_`)) {
          delete currentCart[key];
        }
      });
      
      try {
        localStorage.setItem('cart', JSON.stringify(currentCart));
      } catch (storageError) {
        console.error('Failed to save cart after removal:', storageError);
      }
      
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
      try {
        localStorage.removeItem('cart');
      } catch (storageError) {
        console.error('Failed to clear cart from localStorage:', storageError);
      }
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
