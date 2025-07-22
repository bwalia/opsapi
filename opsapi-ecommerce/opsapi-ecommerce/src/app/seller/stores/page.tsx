"use client";
import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";

export default function SellerStores() {
  const [stores, setStores] = useState([]);
  const [storesLoading, setStoresLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    slug: "",
  });
  const { user, loading: authLoading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!authLoading && !user) {
      router.push("/login");
      return;
    }
    if (user) {
      loadStores();
    }
  }, [user, authLoading, router]);

  const loadStores = async () => {
    try {
      const response = await api.getMyStores();
      const storesData = Array.isArray(response?.data)
        ? response.data
        : Array.isArray(response)
        ? response
        : [];
      setStores(storesData);
    } catch (error) {
      console.error("Failed to load stores:", error);
      setStores([]);
    } finally {
      setStoresLoading(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      const newStore = await api.createStore(formData);
      setShowForm(false);
      setFormData({ name: "", description: "", slug: "" });
      loadStores();
      
      // Suggest creating categories
      if (confirm('Store created successfully! Would you like to create categories for your products?')) {
        router.push(`/seller/categories?store=${newStore.id}`);
      }
    } catch (error: any) {
      alert("Failed to create store: " + error.message);
    }
  };

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>
  ) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]: value,
      ...(name === "name" &&
        !formData.slug && { slug: value.toLowerCase().replace(/\s+/g, "-") }),
    }));
  };

  if (storesLoading) {
    return <div className="container mx-auto px-4 py-8">Loading stores...</div>;
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold">My Stores</h1>
        <button
          onClick={() => setShowForm(true)}
          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
        >
          Create Store
        </button>
      </div>

      {showForm && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white p-6 rounded-lg w-full max-w-md">
            <h2 className="text-xl font-semibold mb-4">Create New Store</h2>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Store Name
                </label>
                <input
                  type="text"
                  name="name"
                  required
                  value={formData.name}
                  onChange={handleChange}
                  className="text-black w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Description
                </label>
                <textarea
                  name="description"
                  rows={3}
                  value={formData.description}
                  onChange={handleChange}
                  className="text-black w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Store Slug (URL)
                </label>
                <input
                  type="text"
                  name="slug"
                  required
                  value={formData.slug}
                  onChange={handleChange}
                  className="text-black w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div className="flex justify-end space-x-2">
                <button
                  type="button"
                  onClick={() => setShowForm(false)}
                  className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  Create Store
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {stores.length === 0 ? (
        <div className="text-center py-12">
          <div className="text-6xl mb-4">🏪</div>
          <h2 className="text-xl font-semibold text-gray-700 mb-2">
            No Stores Yet
          </h2>
          <p className="text-gray-500 mb-4">
            Create your first store to start selling products
          </p>
          <button
            onClick={() => setShowForm(true)}
            className="bg-blue-600 text-white px-6 py-2 rounded hover:bg-blue-700"
          >
            Create Your First Store
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {stores &&
            stores.length > 0 &&
            stores.map((store: any) => (
              <div
                key={store.uuid}
                className="bg-white border rounded-lg p-6 shadow-sm"
              >
                <h3 className="text-lg font-semibold mb-2">{store.name}</h3>
                <p className="text-gray-600 mb-4">{store.description}</p>

                <div className="flex items-center justify-between mb-4">
                  <span
                    className={`px-2 py-1 rounded text-xs ${
                      store.status === "active"
                        ? "bg-green-100 text-green-800"
                        : "bg-gray-100 text-gray-800"
                    }`}
                  >
                    {store.status}
                  </span>
                  <span className="text-sm text-gray-500">/{store.slug}</span>
                </div>

                <div className="grid grid-cols-2 gap-2 mb-2">
                  <button
                    onClick={() =>
                      router.push(`/seller/categories?store=${store.uuid}`)
                    }
                    className="bg-purple-600 text-white py-2 px-3 rounded text-sm hover:bg-purple-700"
                  >
                    Categories
                  </button>
                  <button
                    onClick={() =>
                      router.push(`/seller/products?store=${store.uuid}`)
                    }
                    className="bg-blue-600 text-white py-2 px-3 rounded text-sm hover:bg-blue-700"
                  >
                    Products
                  </button>
                </div>
                <button
                  onClick={() => router.push(`/seller/stores/${store.uuid}`)}
                  className="w-full border border-gray-300 py-2 px-3 rounded text-sm hover:bg-gray-50"
                >
                  Edit Store
                </button>
              </div>
            ))}
        </div>
      )}
    </div>
  );
}
