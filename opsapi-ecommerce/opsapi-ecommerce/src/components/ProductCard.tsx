import { useState } from 'react';
import { useCart } from '@/contexts/CartContext';

interface Product {
  uuid: string;
  name: string;
  description: string;
  price: number;
  inventory_quantity: number;
  images?: string[];
}

interface ProductCardProps {
  product: Product;
  onAddToCart?: () => void;
}

export default function ProductCard({ product, onAddToCart }: ProductCardProps) {
  const [quantity, setQuantity] = useState(1);
  const { addToCart, loading } = useCart();

  const handleAddToCart = async () => {
    if (!product.uuid) {
      alert('Invalid product');
      return;
    }
    
    try {
      await addToCart(product.uuid, quantity);
      onAddToCart?.();
      
      // Show success message
      const successMsg = document.createElement('div');
      successMsg.className = 'fixed top-4 right-4 bg-green-500 text-white px-4 py-2 rounded z-50';
      successMsg.textContent = 'Added to cart successfully!';
      document.body.appendChild(successMsg);
      setTimeout(() => {
        if (document.body.contains(successMsg)) {
          document.body.removeChild(successMsg);
        }
      }, 3000);
    } catch (error: any) {
      console.error('Failed to add to cart:', error);
      alert(error.message || 'Failed to add to cart');
    }
  };

  return (
    <div className="border rounded-lg p-4 shadow-sm hover:shadow-md transition-shadow">
      <div className="aspect-square bg-gray-200 rounded-md mb-4 flex items-center justify-center">
        {product.images?.[0] ? (
          <img 
            src={product.images[0]} 
            alt={product.name}
            className="w-full h-full object-cover rounded-md"
          />
        ) : (
          <span className="text-gray-400">No Image</span>
        )}
      </div>
      
      <h3 className="font-semibold text-lg mb-2">{product.name}</h3>
      <p className="text-gray-600 text-sm mb-3 line-clamp-2">{product.description}</p>
      
      <div className="flex items-center justify-between mb-3">
        <span className="text-xl font-bold text-green-600">
          ${product.price.toFixed(2)}
        </span>
        <span className="text-sm text-gray-500">
          Stock: {product.inventory_quantity}
        </span>
      </div>

      <div className="flex items-center gap-2">
        <select 
          value={quantity} 
          onChange={(e) => setQuantity(Number(e.target.value))}
          className="border rounded px-2 py-1 text-sm"
          disabled={product.inventory_quantity === 0}
        >
          {Array.from({ length: Math.min(10, product.inventory_quantity) }, (_, i) => (
            <option key={i + 1} value={i + 1}>{i + 1}</option>
          ))}
        </select>
        
        <button
          onClick={handleAddToCart}
          disabled={loading || product.inventory_quantity === 0}
          className="flex-1 bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed text-sm"
        >
          {loading ? 'Adding...' : product.inventory_quantity === 0 ? 'Out of Stock' : 'Add to Cart'}
        </button>
      </div>
    </div>
  );
}