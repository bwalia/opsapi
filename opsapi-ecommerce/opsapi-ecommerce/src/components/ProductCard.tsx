import { useState, useEffect } from "react";
import Link from "next/link";
import { useCart } from "@/contexts/CartContext";
import api from "@/lib/api";
import { ProductVariant } from "@/types";

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

export default function ProductCard({
  product,
  onAddToCart,
  showVariants = true,
}: ProductCardProps) {
  const [quantity, setQuantity] = useState(1);
  const [selectedVariant, setSelectedVariant] = useState<string>("");
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
      console.error("Failed to load variants:", error);
      setVariants([]);
    }
  };

  const handleVariantChange = (variantUuid: string) => {
    setSelectedVariant(variantUuid);
    setQuantity(1);

    if (variantUuid && variants.length > 0) {
      const variant = variants.find((v) => v.uuid === variantUuid);
      if (variant) {
        setCurrentPrice(
          typeof variant.price === "number" ? variant.price : product.price
        );
        setCurrentStock(
          typeof variant.inventory_quantity === "number"
            ? variant.inventory_quantity
            : 0
        );
      }
    } else {
      setCurrentPrice(typeof product.price === "number" ? product.price : 0);
      setCurrentStock(
        typeof product.inventory_quantity === "number"
          ? product.inventory_quantity
          : 0
      );
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

    try {
      await addToCart(product.uuid, quantity, selectedVariant || undefined);
      onAddToCart?.();

      // Show success message
      const successMsg = document.createElement("div");
      successMsg.className =
        "fixed top-4 right-4 bg-green-500 text-white px-4 py-2 rounded z-50";
      successMsg.textContent = "Added to cart successfully!";
      document.body.appendChild(successMsg);
      setTimeout(() => {
        try {
          if (document.body.contains(successMsg)) {
            document.body.removeChild(successMsg);
          }
        } catch {}
      }, 3000);
    } catch (error: any) {
      console.error("Failed to add to cart:", error);
      alert(error?.message || "Failed to add to cart");
    }
  };

  const getProductImages = () => {
    try {
      if (!product.images) return [];

      // If images is already an array, return it
      if (Array.isArray(product.images)) {
        return product.images.filter(
          (img) => typeof img === "string" && img.trim()
        );
      }

      // If images is a string, try to parse as JSON
      if (typeof product.images === "string") {
        if (product.images === "") return [];
        const parsed = JSON.parse(product.images);
        return Array.isArray(parsed)
          ? parsed.filter((img) => typeof img === "string" && img.trim())
          : [];
      }

      return [];
    } catch {
      return [];
    }
  };

  const images = getProductImages();

  return (
    <div className="card group hover:shadow-lg transition-all duration-300">
      <Link href={`/products/${product.uuid}`}>
        <div className="aspect-[20/14] bg-gray-100 rounded-lg mb-4 overflow-hidden cursor-pointer p-2">
          {images.length > 0 ? (
            <img
              src={images[0]}
              alt={product.name}
              className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
              onError={(e) => {
                const target = e.target as HTMLImageElement;
                target.style.display = "none";
                const parent = target.parentElement;
                if (parent) {
                  parent.innerHTML =
                    '<div class="w-full h-full flex items-center justify-center text-gray-400"><svg class="icon-xl" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"></path></svg></div>';
                }
              }}
            />
          ) : (
            <div className="w-full h-full flex items-center justify-center text-gray-400">
              <svg
                className="icon-xl"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
            </div>
          )}
        </div>
      </Link>

      <div className="space-y-3 p-5">
        <Link href={`/products/${product.uuid}`}>
          <h3 className="font-semibold text-lg text-gray-900 hover:text-[#fe004d] cursor-pointer transition-colors line-clamp-2">
            {product.name}
          </h3>
        </Link>

        <p className="text-gray-600 text-sm line-clamp-2">
          {product.description || ""}
        </p>

        <div className="flex items-center justify-between">
          <span className="text-2xl font-bold text-[#fe004d]">
            ${currentPrice.toFixed(2)}
          </span>
          <span
            className={`text-sm px-2 py-1 rounded-full ${
              currentStock > 0
                ? "bg-green-100 text-green-800"
                : "bg-red-100 text-red-800"
            }`}
          >
            {currentStock > 0 ? `${currentStock} in stock` : "Out of stock"}
          </span>
        </div>

        {/* Variant Selection */}
        {showVariants && variants.length > 0 && (
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Options:
            </label>
            <select
              value={selectedVariant}
              onChange={(e) => handleVariantChange(e.target.value)}
              className="input-field text-sm"
            >
              <option value="">Select variant...</option>
              {variants
                .filter((v) => v.is_active)
                .map((variant) => (
                  <option key={variant.uuid} value={variant.uuid}>
                    {variant.title}{" "}
                    {variant.price &&
                      variant.price !== product.price &&
                      `(+$${(variant.price - product.price).toFixed(2)})`}
                  </option>
                ))}
            </select>
          </div>
        )}

        <div className="space-y-3">
          {/* Quantity Selector */}
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-gray-700">Quantity:</span>
            <div className="flex items-center border border-gray-200 rounded-lg">
              <button
                type="button"
                onClick={() => setQuantity(Math.max(1, quantity - 1))}
                disabled={quantity <= 1 || currentStock === 0}
                className="p-2 hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                <svg
                  className="w-4 h-4"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M20 12H4"
                  />
                </svg>
              </button>
              <input
                type="number"
                min="1"
                max={currentStock}
                value={quantity}
                onChange={(e) => {
                  const value = parseInt(e.target.value) || 1;
                  setQuantity(Math.min(Math.max(1, value), currentStock));
                }}
                className="w-16 text-center border-0 focus:outline-none focus:ring-0 text-sm font-medium"
                disabled={currentStock === 0}
              />
              <button
                type="button"
                onClick={() =>
                  setQuantity(Math.min(currentStock, quantity + 1))
                }
                disabled={quantity >= currentStock || currentStock === 0}
                className="p-2 hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                <svg
                  className="w-4 h-4"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M12 6v6m0 0v6m0-6h6m-6 0H6"
                  />
                </svg>
              </button>
            </div>
          </div>

          <button
            onClick={handleAddToCart}
            disabled={loading || currentStock === 0}
            className="w-full btn-primary text-sm disabled:bg-gray-300 disabled:cursor-not-allowed"
          >
            {loading
              ? "Adding..."
              : currentStock === 0
              ? "Out of Stock"
              : "Add to Cart"}
          </button>
        </div>
      </div>
    </div>
  );
}
