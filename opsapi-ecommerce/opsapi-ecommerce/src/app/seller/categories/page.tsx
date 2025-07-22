"use client";
import { useState, useEffect, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";

function CategoriesContent() {
  const [categories, setCategories] = useState([]);
  const [stores, setStores] = useState([]);
  const [selectedStore, setSelectedStore] = useState("");
  const [dataLoading, setDataLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  
  type Category = {
    uuid: string;
    name: string;
    description?: string;
    slug?: string;
    sort_order?: number | string;
    is_active?: boolean;
    [key: string]: any;
  };

  const [editingCategory, setEditingCategory] = useState<Category | null>(null);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    slug: "",
    sort_order: "0",
  });

  const { user, loading: authLoading } = useAuth();
  const router = useRouter();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (!authLoading && !user) {
      router.push("/login");
      return;
    }

    if (user) {
      const storeParam = searchParams.get("store");
      if (storeParam) {
        setSelectedStore(storeParam);
      }

      loadData();
    }
  }, [user, authLoading, router, searchParams]);

  const loadData = async () => {
    try {
      // Load stores
      const storesResponse = await api.getStores();
      const storesData = Array.isArray(storesResponse?.data)
        ? storesResponse.data
        : Array.isArray(storesResponse)
        ? storesResponse
        : [];
      setStores(storesData);

      // Load categories if store is selected
      if (selectedStore) {
        loadCategories(selectedStore);
      }
    } catch (error) {
      console.error("Failed to load data:", error);
      setStores([]);
    } finally {
      setDataLoading(false);
    }
  };

  const loadCategories = async (storeId: string) => {
    try {
      const response = await api.getCategories(storeId);
      const categoriesData = Array.isArray(response?.data)
        ? response.data
        : Array.isArray(response)
        ? response
        : [];
      setCategories(categoriesData);
    } catch (error) {
      console.error("Failed to load categories:", error);
      setCategories([]);
    }
  };

  const handleStoreChange = (storeId: string) => {
    setSelectedStore(storeId);
    if (storeId) {
      loadCategories(storeId);
    } else {
      setCategories([]);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedStore) {
      alert("Please select a store first");
      return;
    }

    try {
      const categoryData = {
        ...formData,
        store_id: parseInt(selectedStore),
      };

      if (editingCategory) {
        await api.updateCategory(editingCategory.uuid, categoryData);
      } else {
        await api.createCategory(categoryData);
      }

      setShowForm(false);
      setEditingCategory(null);
      setFormData({ name: "", description: "", slug: "", sort_order: "0" });
      loadCategories(selectedStore);
    } catch (error: any) {
      alert(
        `Failed to ${editingCategory ? "update" : "create"} category: ` +
          error.message
      );
    }
  };

  const handleEdit = (category: any) => {
    setEditingCategory(category);
    setFormData({
      name: category.name,
      description: category.description || "",
      slug: category.slug || "",
      sort_order: category.sort_order?.toString() || "0",
    });
    setShowForm(true);
  };

  const handleDelete = async (category: any) => {
    if (!confirm(`Are you sure you want to delete "${category.name}"?`)) {
      return;
    }

    try {
      await api.deleteCategory(category.uuid);
      loadCategories(selectedStore);
    } catch (error: any) {
      alert("Failed to delete category: " + error.message);
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

  if (dataLoading) {
    return (
      <div className="container mx-auto px-4 py-8">Loading categories...</div>
    );
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold">Manage Categories</h1>
        <button
          onClick={() => setShowForm(true)}
          disabled={!selectedStore}
          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
        >
          Add Category
        </button>
      </div>

      {/* Store Selector */}
      <div className="mb-6">
        <label className="block text-sm font-medium text-gray-700 mb-2">
          Select Store
        </label>
        <select
          value={selectedStore}
          onChange={(e) => handleStoreChange(e.target.value)}
          className="w-full max-w-md px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
        >
          <option value="">Choose a store...</option>
          {stores.map((store: any) => (
            <option key={store.uuid} value={store.uuid}>
              {store.name}
            </option>
          ))}
        </select>
      </div>

      {/* Category Form Modal */}
      {showForm && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white p-6 rounded-lg w-full max-w-md">
            <h2 className="text-xl font-semibold mb-4">
              {editingCategory ? "Edit Category" : "Add New Category"}
            </h2>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Category Name
                </label>
                <input
                  type="text"
                  name="name"
                  required
                  value={formData.name}
                  onChange={handleChange}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
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
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Slug (URL)
                </label>
                <input
                  type="text"
                  name="slug"
                  value={formData.slug}
                  onChange={handleChange}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Sort Order
                </label>
                <input
                  type="number"
                  name="sort_order"
                  min="0"
                  value={formData.sort_order}
                  onChange={handleChange}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                />
              </div>

              <div className="flex justify-end space-x-2">
                <button
                  type="button"
                  onClick={() => {
                    setShowForm(false);
                    setEditingCategory(null);
                    setFormData({
                      name: "",
                      description: "",
                      slug: "",
                      sort_order: "0",
                    });
                  }}
                  className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  {editingCategory ? "Update" : "Create"} Category
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Categories List */}
      {!selectedStore ? (
        <div className="text-center py-12">
          <div className="text-4xl mb-4">📂</div>
          <h2 className="text-xl font-semibold text-gray-700 mb-2">
            Select a Store
          </h2>
          <p className="text-gray-500">
            Choose a store to manage its categories
          </p>
        </div>
      ) : categories.length === 0 ? (
        <div className="text-center py-12">
          <div className="text-4xl mb-4">📂</div>
          <h2 className="text-xl font-semibold text-gray-700 mb-2">
            No Categories Yet
          </h2>
          <p className="text-gray-500 mb-4">
            Create categories to organize your products
          </p>
          <button
            onClick={() => setShowForm(true)}
            className="bg-blue-600 text-white px-6 py-2 rounded hover:bg-blue-700"
          >
            Create Your First Category
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {categories.map((category: any) => (
            <div
              key={category.uuid}
              className="bg-white border rounded-lg p-4 shadow-sm"
            >
              <h3 className="font-semibold text-lg mb-2">{category.name}</h3>
              <p className="text-gray-600 text-sm mb-3">
                {category.description}
              </p>

              <div className="flex items-center justify-between mb-3">
                <span className="text-xs text-gray-500">
                  Order: {category.sort_order || 0}
                </span>
                <span
                  className={`px-2 py-1 rounded text-xs ${
                    category.is_active
                      ? "bg-green-100 text-green-800"
                      : "bg-gray-100 text-gray-800"
                  }`}
                >
                  {category.is_active ? "Active" : "Inactive"}
                </span>
              </div>

              <div className="flex space-x-2">
                <button
                  onClick={() => handleEdit(category)}
                  className="flex-1 bg-blue-600 text-white py-2 px-3 rounded text-sm hover:bg-blue-700"
                >
                  Edit
                </button>
                <button
                  onClick={() => handleDelete(category)}
                  className="flex-1 bg-red-600 text-white py-2 px-3 rounded text-sm hover:bg-red-700"
                >
                  Delete
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default function SellerCategories() {
  return (
    <Suspense fallback={<div className="container mx-auto px-4 py-8">Loading...</div>}>
      <CategoriesContent />
    </Suspense>
  );
}
