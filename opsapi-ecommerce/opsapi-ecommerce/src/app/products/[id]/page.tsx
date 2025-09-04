"use client";
import { useState, useEffect } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
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
      setCurrentPrice(
        typeof productResponse.price === "number" ? productResponse.price : 0
      );
      setCurrentStock(
        typeof productResponse.inventory_quantity === "number"
          ? productResponse.inventory_quantity
          : 0
      );

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
    } else if (product) {
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
      if (!product?.images || product.images.length === 0) return [];
      // If images is already an array, return it directly
      if (Array.isArray(product.images)) {
        return product.images.filter(
          (img) => typeof img === "string" && img.trim()
        );
      }
      // If images is a string, try to parse it as JSON
      const parsed = JSON.parse(product.images as string);
      return Array.isArray(parsed)
        ? parsed.filter((img) => typeof img === "string" && img.trim())
        : [];
    } catch {
      return [];
    }
  };

  const images = getProductImages();

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Breadcrumb */}
      <div className="bg-white border-b">
        <div className="container py-4">
          <nav className="flex items-center space-x-2 text-sm">
            <Link href="/" className="text-gray-500 hover:text-[#fe004d]">
              Home
            </Link>
            <span className="text-gray-300">/</span>
            <span className="text-gray-900 font-medium">{product.name}</span>
          </nav>
        </div>
      </div>

      <div className="py-6 px-4">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12">
          {/* Product Images */}
          <div className="space-y-4">
            <div className="aspect-square bg-white rounded-2xl overflow-hidden shadow-sm border">
              {images.length > 0 ? (
                <img
                  src={images[selectedImage]}
                  alt={product.name}
                  className="w-full h-full object-cover hover:scale-105 transition-transform duration-500"
                  onError={(e) => {
                    const target = e.target as HTMLImageElement;
                    target.src =
                      "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNDAwIiBoZWlnaHQ9IjQwMCIgdmlld0JveD0iMCAwIDQwMCA0MDAiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxyZWN0IHdpZHRoPSI0MDAiIGhlaWdodD0iNDAwIiBmaWxsPSIjRjNGNEY2Ii8+CjxwYXRoIGQ9Ik0yMDAgMzAwQzE2Ni42NjcgMjY2LjY2NyAxNjYuNjY3IDIwMC4wMDEgMjAwIDE2NkMyMzMuMzMzIDIwMC4wMDEgMjMzLjMzMyAyNjYuNjY3IDIwMCAzMDBaIiBmaWxsPSIjOUNBM0FGIi8+Cjwvc3ZnPg==";
                  }}
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center bg-gray-100">
                  <div className="text-center">
                    <svg
                      className="w-16 h-16 text-gray-400 mx-auto mb-4"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={1.5}
                        d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
                      />
                    </svg>
                    <p className="text-gray-500">No image available</p>
                  </div>
                </div>
              )}
            </div>

            {images.length > 1 && (
              <div className="grid grid-cols-4 gap-3">
                {images.map((img: string, index: number) => (
                  <button
                    key={index}
                    onClick={() => setSelectedImage(index)}
                    className={`aspect-square rounded-lg overflow-hidden border-2 transition-all ${
                      selectedImage === index
                        ? "border-[#fe004d] ring-2 ring-[#fe004d]/20"
                        : "border-gray-200 hover:border-gray-300"
                    }`}
                  >
                    <img
                      src={img}
                      alt={`${product.name} ${index + 1}`}
                      className="w-full h-full object-cover"
                    />
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Product Info */}
          <div className="space-y-6">
            <div>
              <h1 className="heading-2 text-gray-900 mb-2">{product.name}</h1>
              <div className="flex items-center space-x-4">
                <div className="flex items-baseline space-x-2">
                  <span className="text-3xl font-bold text-[#fe004d]">
                    ${currentPrice.toFixed(2)}
                  </span>
                  {product.price !== currentPrice && (
                    <span className="text-lg text-gray-500 line-through">
                      ${product.price.toFixed(2)}
                    </span>
                  )}
                </div>
                <span
                  className={`badge ${
                    currentStock > 0 ? "badge-success" : "badge-error"
                  }`}
                >
                  {currentStock > 0
                    ? `${currentStock} in stock`
                    : "Out of stock"}
                </span>
              </div>
            </div>

            {product.description && (
              <div>
                <p className="text-gray-600 leading-relaxed text-lg">
                  {product.description}
                </p>
              </div>
            )}

            {/* Product Details */}
            <div className="bg-gray-50 rounded-xl p-6">
              <h3 className="font-semibold text-gray-900 mb-4">
                Product Details
              </h3>
              <div className="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <span className="text-gray-500">SKU</span>
                  <p className="font-medium">{product.sku || "N/A"}</p>
                </div>
                <div>
                  <span className="text-gray-500">Availability</span>
                  <p
                    className={`font-medium ${
                      currentStock > 0 ? "text-green-600" : "text-red-600"
                    }`}
                  >
                    {currentStock > 0
                      ? `${currentStock} available`
                      : "Out of stock"}
                  </p>
                </div>
                <div>
                  <span className="text-gray-500">Status</span>
                  <span
                    className={`badge ${
                      product.is_active ? "badge-success" : "badge-gray"
                    }`}
                  >
                    {product.is_active ? "Active" : "Inactive"}
                  </span>
                </div>
              </div>
            </div>

            {/* Variants */}
            {variants.length > 0 && (
              <div>
                <label className="block text-sm font-medium text-gray-900 mb-3">
                  Select Variant
                </label>
                <select
                  value={selectedVariant}
                  onChange={(e) => handleVariantChange(e.target.value)}
                  className="input"
                >
                  <option value="">Choose an option</option>
                  {variants
                    .filter((v) => v.is_active)
                    .map((variant) => (
                      <option key={variant.uuid} value={variant.uuid}>
                        {variant.title}
                        {variant.price &&
                          variant.price !== product.price &&
                          ` ($${(variant.price - product.price).toFixed(2)})`}
                      </option>
                    ))}
                </select>
              </div>
            )}

            {/* Quantity and Add to Cart */}
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-900 mb-3">
                  Quantity
                </label>
                <div className="flex items-center border border-gray-200 rounded-lg w-32">
                  <button
                    type="button"
                    onClick={() => setQuantity(Math.max(1, quantity - 1))}
                    disabled={quantity <= 1 || currentStock === 0}
                    className="p-3 hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
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
                    className="flex-1 text-center border-0 focus:outline-none focus:ring-0 text-sm font-medium py-3"
                    disabled={currentStock === 0}
                  />
                  <button
                    type="button"
                    onClick={() =>
                      setQuantity(Math.min(currentStock, quantity + 1))
                    }
                    disabled={quantity >= currentStock || currentStock === 0}
                    className="p-3 hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
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

              <div className="flex space-x-4">
                <button
                  onClick={handleAddToCart}
                  disabled={cartLoading || currentStock === 0}
                  className="btn-primary flex-1 btn-lg"
                >
                  {cartLoading ? (
                    <>
                      <svg
                        className="animate-spin -ml-1 mr-3 h-5 w-5 text-white"
                        xmlns="http://www.w3.org/2000/svg"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <circle
                          className="opacity-25"
                          cx="12"
                          cy="12"
                          r="10"
                          stroke="currentColor"
                          strokeWidth="4"
                        ></circle>
                        <path
                          className="opacity-75"
                          fill="currentColor"
                          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                        ></path>
                      </svg>
                      Adding to Cart...
                    </>
                  ) : currentStock === 0 ? (
                    "Out of Stock"
                  ) : (
                    <>
                      <svg
                        className="w-5 h-5 mr-2"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth={2}
                          d="M3 3h2l.4 2M7 13h10l4-8H5.4m0 0L7 13m0 0l-1.1 5M7 13l-1.1 5m0 0h9.1M17 13v6a2 2 0 01-2 2H9a2 2 0 01-2-2v-6"
                        />
                      </svg>
                      Add to Cart
                    </>
                  )}
                </button>
                <button className="btn-outline px-6">
                  <svg
                    className="w-5 h-5"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth={2}
                      d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"
                    />
                  </svg>
                </button>
              </div>
            </div>

            {/* Features */}
            <div className="bg-white rounded-xl p-6 border">
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 bg-green-100 rounded-lg flex items-center justify-center">
                    <svg
                      className="w-5 h-5 text-green-600"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={2}
                        d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
                      />
                    </svg>
                  </div>
                  <div>
                    <p className="font-medium text-gray-900">Free Shipping</p>
                    <p className="text-sm text-gray-500">On orders over $50</p>
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 bg-blue-100 rounded-lg flex items-center justify-center">
                    <svg
                      className="w-5 h-5 text-blue-600"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={2}
                        d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                  </div>
                  <div>
                    <p className="font-medium text-gray-900">30-Day Returns</p>
                    <p className="text-sm text-gray-500">Easy return policy</p>
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 bg-purple-100 rounded-lg flex items-center justify-center">
                    <svg
                      className="w-5 h-5 text-purple-600"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth={2}
                        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                      />
                    </svg>
                  </div>
                  <div>
                    <p className="font-medium text-gray-900">Secure Payment</p>
                    <p className="text-sm text-gray-500">SSL encrypted</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
