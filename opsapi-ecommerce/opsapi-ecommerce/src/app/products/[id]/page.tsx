"use client";
import { useState, useEffect } from "react";
import { useParams, useRouter } from "next/navigation";
import { useCart } from "@/contexts/CartContext";
import api from "@/lib/api";
import { Product, ProductVariant } from "@/types";

export default function ProductDetails() {
  const [product, setProduct] = useState<Product | null>(null);
  const [variants, setVariants] = useState<ProductVariant[]>([]);
  const [selectedVariant, setSelectedVariant] = useState<string>("");
  const [quantity, setQuantity] = useState(1);
  const [selectedImage, setSelectedImage] = useState(0);
  const [loading, setLoading] = useState(true);
  const [currentPrice, setCurrentPrice] = useState(0);
  const [currentStock, setCurrentStock] = useState(0);

  const { addToCart, loading: cartLoading } = useCart();
  const params = useParams();
  const router = useRouter();
  const productId = params.id as string;

  useEffect(() => {
    loadProduct();
  }, [productId]);

  const loadProduct = async () => {
    if (!productId) {
      router.push("/");
      return;
    }
    
    try {
      setLoading(true);
      const productResponse = await api.getProduct(productId);
      
      if (!productResponse) {
        router.push("/");
        return;
      }
      
      setProduct(productResponse);
      setCurrentPrice(typeof productResponse.price === 'number' ? productResponse.price : 0);
      setCurrentStock(typeof productResponse.inventory_quantity === 'number' ? productResponse.inventory_quantity : 0);
      
      // Load variants separately to avoid blocking product display
      try {
        const variantsResponse = await api.getVariants(productId);
        setVariants(Array.isArray(variantsResponse) ? variantsResponse : []);
      } catch (variantError) {
        console.error("Failed to load variants:", variantError);
        setVariants([]);
      }
    } catch (error) {
      console.error("Failed to load product:", error);
      router.push("/");
    } finally {
      setLoading(false);
    }
  };

  const handleVariantChange = (variantUuid: string) => {
    setSelectedVariant(variantUuid);
    setQuantity(1);
    
    if (variantUuid && product && variants.length > 0) {
      const variant = variants.find(v => v.uuid === variantUuid);
      if (variant) {
        setCurrentPrice(typeof variant.price === 'number' ? variant.price : product.price);
        setCurrentStock(typeof variant.inventory_quantity === 'number' ? variant.inventory_quantity : 0);
      }
    } else if (product) {
      setCurrentPrice(typeof product.price === 'number' ? product.price : 0);
      setCurrentStock(typeof product.inventory_quantity === 'number' ? product.inventory_quantity : 0);
    }
  };

  const handleAddToCart = async () => {
    if (!product?.uuid) {
      alert("Invalid product");
      return;
    }
    
    if (currentStock <= 0) {
      alert("Product is out of stock");
      return;
    }
    
    if (quantity <= 0 || quantity > currentStock) {
      alert(`Please select a valid quantity (1-${currentStock})`);
      return;
    }
    
    try {
      await addToCart(product.uuid, quantity, selectedVariant || undefined);
      alert("Added to cart successfully!");
    } catch (error: any) {
      console.error("Failed to add to cart:", error);
      alert(error?.message || "Failed to add to cart");
    }
  };

  if (loading) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center">Loading product...</div>
      </div>
    );
  }

  if (!product) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center">Product not found</div>
      </div>
    );
  }

  const getProductImages = () => {
    try {
      if (!product?.images || product.images === '') return [];
      const parsed = JSON.parse(product.images);
      return Array.isArray(parsed) ? parsed.filter(img => typeof img === 'string' && img.trim()) : [];
    } catch {
      return [];
    }
  };
  
  const images = getProductImages();

  return (
    <div className="container mx-auto px-4 py-8">
      <button
        onClick={() => router.back()}
        className="text-blue-600 hover:text-blue-800 mb-6"
      >
        ← Back
      </button>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        {/* Product Images */}
        <div>
          <div className="aspect-square bg-gray-200 rounded-lg mb-4 overflow-hidden">
            {images.length > 0 ? (
              <img
                src={images[selectedImage]}
                alt={product.name}
                className="w-full h-full object-cover"
              />
            ) : (
              <div className="w-full h-full flex items-center justify-center text-gray-400">
                No Image Available
              </div>
            )}
          </div>
          
          {images.length > 1 && (
            <div className="grid grid-cols-4 gap-2">
              {images.map((img: string, index: number) => (
                <button
                  key={index}
                  onClick={() => setSelectedImage(index)}
                  className={`aspect-square rounded border-2 overflow-hidden ${
                    selectedImage === index ? "border-blue-500" : "border-gray-200"
                  }`}
                >
                  <img src={img} alt={`${product.name} ${index + 1}`} className="w-full h-full object-cover" />
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Product Info */}
        <div>
          <h1 className="text-3xl font-bold mb-4">{product.name}</h1>
          
          <div className="mb-6">
            <span className="text-3xl font-bold text-green-600">
              ${currentPrice.toFixed(2)}
            </span>
            {product.price !== currentPrice && (
              <span className="text-lg text-gray-500 line-through ml-2">
                ${product.price.toFixed(2)}
              </span>
            )}
          </div>

          <div className="mb-6">
            <p className="text-gray-600 leading-relaxed">{product.description}</p>
          </div>

          {/* Product Details */}
          <div className="mb-6 space-y-2">
            <div className="flex justify-between">
              <span className="font-medium">SKU:</span>
              <span>{product.sku || "N/A"}</span>
            </div>
            <div className="flex justify-between">
              <span className="font-medium">Stock:</span>
              <span className={currentStock > 0 ? "text-green-600" : "text-red-600"}>
                {currentStock > 0 ? `${currentStock} available` : "Out of stock"}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="font-medium">Status:</span>
              <span className={`px-2 py-1 rounded text-xs ${
                product.is_active ? "bg-green-100 text-green-800" : "bg-gray-100 text-gray-800"
              }`}>
                {product.is_active ? "Active" : "Inactive"}
              </span>
            </div>
          </div>

          {/* Variants */}
          {variants.length > 0 && (
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Select Option:
              </label>
              <select
                value={selectedVariant}
                onChange={(e) => handleVariantChange(e.target.value)}
                className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                <option value="">Default</option>
                {variants.filter(v => v.is_active).map((variant) => (
                  <option key={variant.uuid} value={variant.uuid}>
                    {variant.title} 
                    {variant.price && variant.price !== product.price && 
                      ` (+$${(variant.price - product.price).toFixed(2)})`
                    }
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Quantity and Add to Cart */}
          <div className="flex items-center gap-4 mb-6">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Quantity:
              </label>
              <select
                value={quantity}
                onChange={(e) => setQuantity(Number(e.target.value))}
                className="px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
                disabled={currentStock === 0}
              >
                {Array.from({ length: Math.min(10, currentStock) }, (_, i) => (
                  <option key={i + 1} value={i + 1}>{i + 1}</option>
                ))}
              </select>
            </div>
            
            <div className="flex-1">
              <button
                onClick={handleAddToCart}
                disabled={cartLoading || currentStock === 0}
                className="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed font-medium"
              >
                {cartLoading ? "Adding..." : currentStock === 0 ? "Out of Stock" : "Add to Cart"}
              </button>
            </div>
          </div>

          {/* Additional Info */}
          <div className="border-t pt-6">
            <h3 className="font-semibold mb-2">Product Information</h3>
            <div className="text-sm text-gray-600 space-y-1">
              <p>• Free shipping on orders over $50</p>
              <p>• 30-day return policy</p>
              <p>• Secure payment processing</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}