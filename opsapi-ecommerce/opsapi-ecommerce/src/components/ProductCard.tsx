import { useState, useEffect } from 'react';
import Link from 'next/link';
import { useCart } from '@/contexts/CartContext';
import api from '@/lib/api';
import { ProductVariant } from '@/types';

interface ProductCardProduct {
  uuid: string;
  name: string;
  description?: string;
  price: number;
  inventory_quantity: number;
  images?: string | string[];
  variants?: ProductVariant[];
}

interface ProductCardProps {
  product: ProductCardProduct;
  onAddToCart?: () => void;
  showVariants?: boolean;
}

export default function ProductCard({ product, onAddToCart, showVariants = true }: ProductCardProps) {
  const [quantity, setQuantity] = useState(1);
  const [selectedVariant, setSelectedVariant] = useState<string>('');
  const [variants, setVariants] = useState<ProductVariant[]>([]);
  const [currentPrice, setCurrentPrice] = useState(product.price);
  const [currentStock, setCurrentStock] = useState(product.inventory_quantity);
  const { addToCart, loading } = useCart();

  useEffect(() => {
    if (showVariants) {
      loadVariants();
    }
  }, [product.uuid, showVariants]);

  const loadVariants = async () => {
    if (!showVariants || !product?.uuid) return;
    
    try {
      const response = await api.getVariants(product.uuid);
      const variantData = Array.isArray(response) ? response : [];
      setVariants(variantData);
    } catch (error) {
      console.error('Failed to load variants:', error);
      setVariants([]);
    }
  };

  const handleVariantChange = (variantUuid: string) => {
    setSelectedVariant(variantUuid);
    setQuantity(1);
    
    if (variantUuid && variants.length > 0) {
      const variant = variants.find(v => v.uuid === variantUuid);
      if (variant) {
        setCurrentPrice(typeof variant.price === 'number' ? variant.price : product.price);
        setCurrentStock(typeof variant.inventory_quantity === 'number' ? variant.inventory_quantity : 0);
      }
    } else {
      setCurrentPrice(typeof product.price === 'number' ? product.price : 0);
      setCurrentStock(typeof product.inventory_quantity === 'number' ? product.inventory_quantity : 0);
    }
  };

  const handleAddToCart = async () => {
    if (!product?.uuid) {
      alert('Invalid product');
      return;
    }
    
    if (currentStock <= 0) {
      alert('Product is out of stock');
      return;
    }
    
    try {
      await addToCart(product.uuid, quantity, selectedVariant || undefined);
      onAddToCart?.();
      
      // Show success message
      const successMsg = document.createElement('div');
      successMsg.className = 'fixed top-4 right-4 bg-green-500 text-white px-4 py-2 rounded z-50';
      successMsg.textContent = 'Added to cart successfully!';
      document.body.appendChild(successMsg);
      setTimeout(() => {
        try {
          if (document.body.contains(successMsg)) {
            document.body.removeChild(successMsg);
          }
        } catch {}
      }, 3000);
    } catch (error: any) {
      console.error('Failed to add to cart:', error);
      alert(error?.message || 'Failed to add to cart');
    }
  };

  const getProductImages = () => {
    try {
      if (!product.images) return [];
      
      // If images is already an array, return it
      if (Array.isArray(product.images)) {
        return product.images.filter(img => typeof img === 'string' && img.trim());
      }
      
      // If images is a string, try to parse as JSON
      if (typeof product.images === 'string') {
        if (product.images === '') return [];
        const parsed = JSON.parse(product.images);
        return Array.isArray(parsed) ? parsed.filter(img => typeof img === 'string' && img.trim()) : [];
      }
      
      return [];
    } catch {
      return [];
    }
  };
  
  const images = getProductImages();

  return (
    <div className="border rounded-lg p-4 shadow-sm hover:shadow-md transition-shadow">
      <Link href={`/products/${product.uuid}`}>
        <div className="aspect-square bg-gray-200 rounded-md mb-4 flex items-center justify-center cursor-pointer">
          {images.length > 0 ? (
            <img 
              src={images[0]} 
              alt={product.name}
              className="w-full h-full object-cover rounded-md"
              onError={(e) => {
                const target = e.target as HTMLImageElement;
                target.style.display = 'none';
                const parent = target.parentElement;
                if (parent) {
                  parent.innerHTML = '<span class="text-gray-400">Image Error</span>';
                }
              }}
            />
          ) : (
            <span className="text-gray-400">No Image</span>
          )}
        </div>
      </Link>
      
      <Link href={`/products/${product.uuid}`}>
        <h3 className="font-semibold text-lg mb-2 hover:text-blue-600 cursor-pointer">{product.name}</h3>
      </Link>
      <p className="text-gray-600 text-sm mb-3 line-clamp-2">{product.description || ''}</p>
      
      <div className="flex items-center justify-between mb-3">
        <span className="text-xl font-bold text-green-600">
          ${currentPrice.toFixed(2)}
        </span>
        <span className="text-sm text-gray-500">
          Stock: {currentStock}
        </span>
      </div>

      {/* Variant Selection */}
      {showVariants && variants.length > 0 && (
        <div className="mb-3">
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Options:
          </label>
          <select
            value={selectedVariant}
            onChange={(e) => handleVariantChange(e.target.value)}
            className="w-full border rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          >
            <option value="">Select variant...</option>
            {variants.filter(v => v.is_active).map((variant) => (
              <option key={variant.uuid} value={variant.uuid}>
                {variant.title} {variant.price && variant.price !== product.price && `(+$${(variant.price - product.price).toFixed(2)})`}
              </option>
            ))}
          </select>
        </div>
      )}

      <div className="flex items-center gap-2">
        <select 
          value={quantity} 
          onChange={(e) => setQuantity(Number(e.target.value))}
          className="border rounded px-2 py-1 text-sm"
          disabled={currentStock === 0}
        >
          {Array.from({ length: Math.min(10, currentStock) }, (_, i) => (
            <option key={i + 1} value={i + 1}>{i + 1}</option>
          ))}
        </select>
        
        <button
          onClick={handleAddToCart}
          disabled={loading || currentStock === 0}
          className="flex-1 bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed text-sm"
        >
          {loading ? 'Adding...' : currentStock === 0 ? 'Out of Stock' : 'Add to Cart'}
        </button>
      </div>
    </div>
  );
}