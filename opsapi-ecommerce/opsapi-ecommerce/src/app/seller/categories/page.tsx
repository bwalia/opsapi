"use client";
import { useState, useEffect, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";
import Modal from "@/components/ui/Modal";
import ConfirmDialog from "@/components/ui/ConfirmDialog";

function CategoriesContent() {
  const [categories, setCategories] = useState([]);
  const [stores, setStores] = useState([]);
  const [selectedStore, setSelectedStore] = useState("");
  const [dataLoading, setDataLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [showDelete, setShowDelete] = useState<{
    open: boolean;
    category: any | null;
  }>({ open: false, category: null });

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
      if (storeParam) setSelectedStore(storeParam);
      loadData();
    }
  }, [user, authLoading, router, searchParams]);

  const loadData = async () => {
    try {
      const storesResponse = await api.getMyStores();
      const storesData = Array.isArray(storesResponse?.data)
        ? storesResponse.data
        : Array.isArray(storesResponse)
        ? storesResponse
        : [];
      setStores(storesData);

      if (selectedStore) loadCategories(selectedStore);
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
    if (storeId) loadCategories(storeId);
    else setCategories([]);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedStore) {
      // Use a non-blocking toast-like banner
      alert("Please select a store first");
      return;
    }

    try {
      const categoryData = { ...formData, store_id: selectedStore };
      if (editingCategory)
        await api.updateCategory(editingCategory.uuid, categoryData);
      else await api.createCategory(categoryData);

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

  const requestDelete = (category: any) => {
    setShowDelete({ open: true, category });
  };

  const confirmDelete = async () => {
    if (!showDelete.category) return;
    try {
      await api.deleteCategory(showDelete.category.uuid);
      loadCategories(selectedStore);
    } catch (error: any) {
      alert("Failed to delete category: " + error.message);
    } finally {
      setShowDelete({ open: false, category: null });
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
          className="btn-primary disabled:bg-gray-400"
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
          className="input max-w-md"
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
      <Modal
        isOpen={showForm}
        onClose={() => setShowForm(false)}
        title={editingCategory ? "Edit Category" : "Add New Category"}
      >
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
              className="input"
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
              className="input"
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Slug (URL)
              </label>
              <input
                type="text"
                name="slug"
                value={formData.slug}
                onChange={handleChange}
                className="input"
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
                className="input"
              />
            </div>
          </div>
          <div className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={() => setShowForm(false)}
              className="px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
            >
              Cancel
            </button>
            <button type="submit" className="btn-primary">
              {editingCategory ? "Update" : "Create"} Category
            </button>
          </div>
        </form>
      </Modal>

      {/* Confirm Delete */}
      <ConfirmDialog
        open={showDelete.open}
        title="Delete Category"
        message={`Are you sure you want to delete "${
          showDelete.category?.name || ""
        }"?`}
        confirmText="Delete"
        onCancel={() => setShowDelete({ open: false, category: null })}
        onConfirm={confirmDelete}
      />

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
          <button onClick={() => setShowForm(true)} className="btn-primary">
            Create Your First Category
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {categories.map((category: any) => (
            <div key={category.uuid} className="card">
              <div className="card-body">
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
                <div className="flex gap-2">
                  <button
                    onClick={() => handleEdit(category)}
                    className="btn-primary btn-sm text-xs"
                  >
                    Edit
                  </button>
                  <button
                    onClick={() => requestDelete(category)}
                    className="px-2 py-1 text-xs font-medium text-red-600 bg-red-50 border border-red-200 rounded-md hover:bg-red-100"
                  >
                    Delete
                  </button>
                </div>
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
    <Suspense
      fallback={<div className="container mx-auto px-4 py-8">Loading...</div>}
    >
      <CategoriesContent />
    </Suspense>
  );
}
