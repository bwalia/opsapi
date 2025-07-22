"use client";
import { useState, useEffect } from "react";
import { useRouter, useParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";

export default function ProductVariants() {
  const [product, setProduct] = useState<any>(null);
  const [variants, setVariants] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);

  const { user, loading: authLoading } = useAuth();
  const router = useRouter();
  const params = useParams();
  const productId = params.id as string;

  useEffect(() => {
    if (!authLoading && (!user || user.role !== "seller")) {
      router.push("/login");
      return;
    }

    if (user && productId) {
      loadProduct();
    }
  }, [user, authLoading, router, productId]);

  const loadProduct = async () => {
    try {
      setLoading(true);
      const response = await api.getVariants(productId);
      setProduct(response);
    } catch (error) {
      console.error("Failed to load product:", error);
      router.push("/seller/products");
    } finally {
      setLoading(false);
    }
  };

  if (loading || authLoading) {
    return <div className="container mx-auto px-4 py-8">Loading...</div>;
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="mb-6">
        <button
          onClick={() => router.back()}
          className="text-blue-600 hover:text-blue-800 mb-4"
        >
          ← Back to Products
        </button>
        <h1 className="text-2xl font-bold">Product Variants</h1>
        <p className="text-gray-600">Managing variants for: {product?.name}</p>
      </div>

      <div className="text-center py-12">
        <div className="text-4xl mb-4">🚧</div>
        <h3 className="text-lg font-semibold text-gray-700 mb-2">
          Variants Feature Coming Soon
        </h3>
        <p className="text-gray-500 mb-4">
          Product variants functionality will be available in the next update
        </p>
      </div>
    </div>
  );
}
