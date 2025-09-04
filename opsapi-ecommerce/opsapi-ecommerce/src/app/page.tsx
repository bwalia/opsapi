"use client";
import { useState, useEffect } from "react";
import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import api from "@/lib/api";
import { Product } from "@/types";

export default function Home() {
  const [products, setProducts] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    loadProducts();
  }, []);

  const loadProducts = async () => {
    try {
      setLoading(true);
      setError("");
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
      console.error("Failed to load products:", err);
      setError(err.message || "Failed to load products");
      setProducts([]);
    } finally {
      setLoading(false);
    }
  };

  const handleAddToCart = () => {
    // Show success message or update cart count
    console.log("Product added to cart successfully");
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
    <div className="min-h-screen">
      {/* Hero Section */}
      <div className="bg-gradient-to-br from-[#fe004d] to-[#e6003d] text-white">
        <div className="px-4 py-16">
          <div className="max-w-4xl mx-auto text-center">
            <h1 className="text-4xl md:text-6xl font-bold mb-6">
              Your Own Store By
              <span className="block text-pink-200">Kisaan</span>
            </h1>
            <p className="text-xl md:text-2xl mb-8 text-pink-100">
              Discover amazing products from sellers worldwide
            </p>
            <div className="flex flex-col sm:flex-row gap-4 justify-center">
              <Link
                href="/register"
                className="bg-white text-[#fe004d] px-8 py-4 rounded-lg font-semibold hover:bg-gray-100 transition-colors"
              >
                Start Selling Today
              </Link>
              <Link
                href="#products"
                className="border-2 border-white text-white px-8 py-4 rounded-lg font-semibold hover:bg-white hover:text-[#fe004d] transition-colors"
              >
                Browse Products
              </Link>
            </div>
          </div>
        </div>
      </div>

      {/* Products Section */}
      <div id="products" className="px-4 py-16">
        <div className="text-center mb-12">
          <h2 className="text-3xl md:text-4xl font-bold text-gray-900 mb-4">
            Featured Products
          </h2>
          <p className="text-lg text-gray-600 max-w-2xl mx-auto">
            Discover unique products from our community of sellers
          </p>
        </div>

        {!products || products.length === 0 ? (
          <div className="text-center py-16">
            <div className="max-w-md mx-auto">
              <div className="empty-state-icon">
                <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"
                  />
                </svg>
              </div>
              <h3 className="text-2xl font-semibold text-gray-900 mb-4">
                No Products Yet
              </h3>
              <p className="text-gray-600 mb-6">
                Be the first to add products to our marketplace!
              </p>
              <Link href="/register" className="btn-primary">
                Become a Seller
              </Link>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
            {products.map((product) => (
              <ProductCard
                key={product.uuid}
                product={product}
                onAddToCart={handleAddToCart}
                showVariants={true}
              />
            ))}
          </div>
        )}
      </div>

      {/* CTA Section */}
      <div className="bg-gray-50 py-16">
        <div className="container mx-auto px-4 text-center">
          <h2 className="text-3xl font-bold text-gray-900 mb-4">
            Ready to Start Selling?
          </h2>
          <p className="text-lg text-gray-600 mb-8 max-w-2xl mx-auto">
            Join thousands of sellers who trust our platform to grow their
            business
          </p>
          <Link href="/register" className="btn-primary text-lg px-8 py-4">
            Get Started for Free
          </Link>
        </div>
      </div>
    </div>
  );
}
