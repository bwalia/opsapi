"use client";
import { useState, useEffect, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";
import { Product } from "@/types";

function ProductsContent() {
  const [products, setProducts] = useState([]);
  const [stores, setStores] = useState([]);
  const [categories, setCategories] = useState([]);
  const [selectedStore, setSelectedStore] = useState("");
  const [dataLoading, setDataLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);

  const [editingProduct, setEditingProduct] = useState<Product | null>(null);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    price: "",
    sku: "",
    category_id: "",
    inventory_quantity: "0",
    track_inventory: true,
    images: [] as string[],
  });
  const [imageUrl, setImageUrl] = useState("");

  const { user, loading: authLoading } = useAuth();
  const router = useRouter();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (!authLoading && !user) {
      router.push("/login");
      return;
    }

    if (user) {
      loadData();
    }
  }, [user, authLoading, router]);

  useEffect(() => {
    const storeParam = searchParams.get("store");
    if (storeParam && storeParam !== selectedStore) {
      setSelectedStore(storeParam);
    }
  }, [searchParams]);

  useEffect(() => {
    if (selectedStore && stores.length > 0) {
      loadProductsForStore(selectedStore);
    }
  }, [selectedStore, stores]);

  const loadData = async () => {
    try {
      // Load user's stores
      const storesResponse = await api.getMyStores();
      const storesData = Array.isArray(storesResponse?.data)
        ? storesResponse.data
        : Array.isArray(storesResponse)
        ? storesResponse
        : [];
      setStores(storesData);

      // Auto-select store from URL or first store
      const storeParam = searchParams.get("store");
      if (storeParam && storesData.find((s: any) => s.uuid === storeParam)) {
        setSelectedStore(storeParam);
      } else if (storesData.length > 0 && !selectedStore) {
        setSelectedStore(storesData[0].uuid);
      }
    } catch (error) {
      console.error("Failed to load data:", error);
      setStores([]);
      setProducts([]);
    } finally {
      setDataLoading(false);
    }
  };

  const loadCategories = async (storeId: string) => {
    if (!storeId) return;

    try {
      const response = await api.getCategories(storeId);
      console.log("Categories response:", response);

      let categoriesData = [];
      if (Array.isArray(response?.data)) {
        categoriesData = response.data;
      } else if (Array.isArray(response)) {
        categoriesData = response;
      } else if (
        response &&
        typeof response === "object" &&
        response.categories
      ) {
        categoriesData = Array.isArray(response.categories)
          ? response.categories
          : [];
      }

      setCategories(categoriesData);
    } catch (error) {
      console.error("Failed to load categories:", error);
      setCategories([]);
    }
  };

  const loadProductsForStore = async (storeId: string) => {
    if (!storeId) return;

    try {
      // Load both products and categories in parallel
      const [productsResponse, categoriesResponse] = await Promise.all([
        api.getStoreProducts(storeId),
        api.getCategories(storeId),
      ]);

      const productsData = Array.isArray(productsResponse?.data)
        ? productsResponse.data
        : Array.isArray(productsResponse)
        ? productsResponse
        : [];
      setProducts(productsData);

      // Handle categories response
      let categoriesData = [];
      if (Array.isArray(categoriesResponse?.data)) {
        categoriesData = categoriesResponse.data;
      } else if (Array.isArray(categoriesResponse)) {
        categoriesData = categoriesResponse;
      }
      setCategories(categoriesData);
    } catch (error) {
      console.error("Failed to load products:", error);
      setProducts([]);
      setCategories([]);
    }
  };

  const handleStoreChange = (storeId: string) => {
    setSelectedStore(storeId);
    if (storeId) {
      loadProductsForStore(storeId);
    } else {
      setProducts([]);
      setCategories([]);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedStore) {
      alert("Please select a store first");
      return;
    }

    if (!formData.name.trim()) {
      alert("Product name is required");
      return;
    }

    if (!formData.price || parseFloat(formData.price) <= 0) {
      alert("Please enter a valid price");
      return;
    }

    try {
      const submitData = {
        name: formData.name.trim(),
        description: formData.description.trim(),
        price: parseFloat(formData.price),
        sku: formData.sku.trim(),
        category_id: formData.category_id || null,
        inventory_quantity: parseInt(formData.inventory_quantity) || 0,
        track_inventory: formData.track_inventory,
        images: JSON.stringify(formData.images.filter((img) => img.trim())),
      };

      console.log("Submitting product data:", submitData);

      if (editingProduct) {
        console.log("Updating product:", editingProduct.uuid);
        const result = await api.updateProduct(editingProduct.uuid, submitData);
        console.log("Update result:", result);
        alert("Product updated successfully!");
      } else {
        console.log("Creating product for store:", selectedStore);
        const result = await api.createProduct(selectedStore, submitData);
        console.log("Create result:", result);
        alert("Product created successfully!");
      }

      setShowForm(false);
      setEditingProduct(null);
      setFormData({
        name: "",
        description: "",
        price: "",
        sku: "",
        category_id: "",
        inventory_quantity: "0",
        track_inventory: true,
        images: [],
      });
      setImageUrl("");

      // Reload products and categories
      await loadProductsForStore(selectedStore);
    } catch (error: any) {
      console.error("Failed to save product:", error);
      alert(
        `Failed to ${editingProduct ? "update" : "create"} product: ` +
          (error?.message || "Unknown error")
      );
    }
  };

  const handleChange = (
    e: React.ChangeEvent<
      HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement
    >
  ) => {
    const { name, value, type } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]:
        type === "checkbox" ? (e.target as HTMLInputElement).checked : value,
    }));
  };

  const handleDeleteProduct = async (product: any) => {
    if (!product?.uuid) return;

    const confirmMessage = `Are you sure you want to delete "${product.name}"? This action cannot be undone and will also delete all variants.`;
    if (!confirm(confirmMessage)) return;

    try {
      await api.deleteProduct(product.uuid);
      alert("Product deleted successfully");
      // Reload products
      if (selectedStore) {
        await loadProductsForStore(selectedStore);
      }
    } catch (error: any) {
      console.error("Failed to delete product:", error);
      alert("Failed to delete product: " + (error?.message || "Unknown error"));
    }
  };

  const handleEdit = (product: any) => {
    if (!product) return;

    let productImages = [];
    try {
      if (product.images && typeof product.images === "string") {
        const parsed = JSON.parse(product.images);
        productImages = Array.isArray(parsed)
          ? parsed.filter((img) => typeof img === "string" && img.trim())
          : [];
      } else if (Array.isArray(product.images)) {
        productImages = product.images.filter(
          (img: string) => typeof img === "string" && img.trim()
        );
      }
    } catch (error) {
      console.error("Failed to parse product images:", error);
      productImages = [];
    }

    setEditingProduct(product);
    setFormData({
      name: product.name || "",
      description: product.description || "",
      price: (typeof product.price === "number" ? product.price : 0).toString(),
      sku: product.sku || "",
      category_id: product.category?.uuid || "",
      inventory_quantity: (typeof product.inventory_quantity === "number"
        ? product.inventory_quantity
        : 0
      ).toString(),
      track_inventory: product.track_inventory !== false,
      images: productImages,
    });
    setShowForm(true);
  };

  if (dataLoading) {
    return (
      <div className="container mx-auto px-4 py-8">Loading products...</div>
    );
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold">Manage Products</h1>
        <button
          onClick={() => setShowForm(true)}
          disabled={!selectedStore}
          className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
        >
          Add Product
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

      {/* Add Product Form Modal */}
      {showForm && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white p-6 rounded-lg w-full max-w-2xl max-h-screen overflow-y-auto">
            <h2 className="text-xl font-semibold mb-4">
              {editingProduct ? "Edit Product" : "Add New Product"}
            </h2>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Product Name
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
                    SKU
                  </label>
                  <input
                    type="text"
                    name="sku"
                    value={formData.sku}
                    onChange={handleChange}
                    className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                  />
                </div>
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

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Price ($)
                  </label>
                  <input
                    type="number"
                    name="price"
                    step="0.01"
                    required
                    value={formData.price}
                    onChange={handleChange}
                    className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                  />
                </div>

                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Category
                  </label>
                  <div className="flex space-x-2">
                    <select
                      name="category_id"
                      value={formData.category_id}
                      onChange={handleChange}
                      className="flex-1 px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                    >
                      <option value="">No Category</option>
                      {categories.map((category: any) => (
                        <option key={category.uuid} value={category.uuid}>
                          {category.name}
                        </option>
                      ))}
                    </select>
                    {categories.length === 0 && (
                      <button
                        type="button"
                        onClick={() =>
                          router.push(
                            `/seller/categories?store=${selectedStore}`
                          )
                        }
                        className="px-3 py-2 bg-purple-600 text-white rounded text-sm hover:bg-purple-700"
                      >
                        Create Categories
                      </button>
                    )}
                  </div>
                  {categories.length === 0 && (
                    <p className="text-xs text-gray-500 mt-1">
                      Create categories first to organize your products better
                    </p>
                  )}
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Inventory Quantity
                  </label>
                  <input
                    type="number"
                    name="inventory_quantity"
                    min="0"
                    value={formData.inventory_quantity}
                    onChange={handleChange}
                    className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                  />
                </div>

                <div className="flex items-center pt-6">
                  <input
                    type="checkbox"
                    name="track_inventory"
                    checked={formData.track_inventory}
                    onChange={handleChange}
                    className="mr-2"
                  />
                  <label className="text-sm text-gray-700">
                    Track inventory
                  </label>
                </div>
              </div>

              {/* Product Images */}
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Product Images
                </label>
                <div className="space-y-2">
                  <div className="flex gap-2">
                    <input
                      type="url"
                      value={imageUrl}
                      onChange={(e) => setImageUrl(e.target.value)}
                      placeholder="Enter image URL"
                      className="flex-1 px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                    />
                    <button
                      type="button"
                      onClick={() => {
                        const url = imageUrl.trim();
                        if (
                          url &&
                          (url.startsWith("http://") ||
                            url.startsWith("https://"))
                        ) {
                          setFormData((prev) => ({
                            ...prev,
                            images: [...prev.images, url],
                          }));
                          setImageUrl("");
                        } else if (url) {
                          alert(
                            "Please enter a valid image URL starting with http:// or https://"
                          );
                        }
                      }}
                      className="px-3 py-2 bg-green-600 text-white rounded hover:bg-green-700"
                    >
                      Add
                    </button>
                  </div>
                  {formData.images.length > 0 && (
                    <div className="grid grid-cols-3 gap-2">
                      {formData.images.map((img, index) => (
                        <div key={index} className="relative">
                          <img
                            src={img}
                            alt={`Product ${index + 1}`}
                            className="w-full h-20 object-cover rounded"
                            onError={(e) => {
                              const target = e.target as HTMLImageElement;
                              target.src =
                                "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHJlY3Qgd2lkdGg9IjI0IiBoZWlnaHQ9IjI0IiBmaWxsPSIjRjNGNEY2Ii8+CjxwYXRoIGQ9Ik0xMiAxNkM5Ljc5IDEzLjc5IDkuNzkgMTAuMjEgMTIgOEMxNC4yMSAxMC4yMSAxNC4yMSAxMy43OSAxMiAxNloiIGZpbGw9IiM5Q0EzQUYiLz4KPC9zdmc+";
                            }}
                          />
                          <button
                            type="button"
                            onClick={() => {
                              setFormData((prev) => ({
                                ...prev,
                                images: prev.images.filter(
                                  (_, i) => i !== index
                                ),
                              }));
                            }}
                            className="absolute -top-1 -right-1 bg-red-500 text-white rounded-full w-5 h-5 text-xs hover:bg-red-600"
                          >
                            ×
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>

              <div className="flex justify-end space-x-2 pt-4">
                <button
                  type="button"
                  onClick={() => {
                    setShowForm(false);
                    setEditingProduct(null);
                    setFormData({
                      name: "",
                      description: "",
                      price: "",
                      sku: "",
                      category_id: "",
                      inventory_quantity: "0",
                      track_inventory: true,
                      images: [],
                    });
                    setImageUrl("");
                  }}
                  className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  {editingProduct ? "Update" : "Add"} Product
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Products List */}
      {!selectedStore ? (
        <div className="text-center py-12">
          <div className="text-4xl mb-4">📦</div>
          <h2 className="text-xl font-semibold text-gray-700 mb-2">
            Select a Store
          </h2>
          <p className="text-gray-500">Choose a store to manage its products</p>
        </div>
      ) : products.length === 0 ? (
        <div className="text-center py-12">
          <div className="text-4xl mb-4">📦</div>
          <h2 className="text-xl font-semibold text-gray-700 mb-2">
            No Products Yet
          </h2>
          <p className="text-gray-500 mb-4">
            Add your first product to start selling
          </p>
          <button
            onClick={() => setShowForm(true)}
            className="bg-blue-600 text-white px-6 py-2 rounded hover:bg-blue-700"
          >
            Add Your First Product
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {products.map((product: any) => (
            <div
              key={product.uuid}
              className="bg-white border rounded-lg p-4 shadow-sm"
            >
              <h3 className="font-semibold text-lg mb-2">{product.name}</h3>
              <p className="text-gray-600 text-sm mb-3 line-clamp-2">
                {product.description}
              </p>

              <div className="flex justify-between items-center mb-3">
                <span className="text-xl font-bold text-green-600">
                  ${parseFloat(product.price).toFixed(2)}
                </span>
                <span className="text-sm text-gray-500">
                  Stock: {product.inventory_quantity}
                </span>
              </div>

              <div className="flex items-center justify-between mb-3">
                <span className="text-xs text-gray-500">
                  SKU: {product.sku || "N/A"}
                </span>
                <span
                  className={`px-2 py-1 rounded text-xs ${
                    product.is_active
                      ? "bg-green-100 text-green-800"
                      : "bg-gray-100 text-gray-800"
                  }`}
                >
                  {product.is_active ? "Active" : "Inactive"}
                </span>
              </div>

              <div className="flex space-x-2">
                <button
                  onClick={() => handleEdit(product)}
                  className="flex-1 bg-blue-600 text-white py-2 px-3 rounded text-sm hover:bg-blue-700"
                >
                  Edit
                </button>
                <button
                  onClick={() =>
                    router.push(`/seller/products/${product.uuid}/variants`)
                  }
                  className="flex-1 border border-gray-300 py-2 px-3 rounded text-sm hover:bg-gray-50"
                >
                  Variants
                </button>
                <button
                  onClick={() => handleDeleteProduct(product)}
                  className="bg-red-600 text-white py-2 px-3 rounded text-sm hover:bg-red-700"
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

export default function SellerProducts() {
  return (
    <Suspense
      fallback={<div className="container mx-auto px-4 py-8">Loading...</div>}
    >
      <ProductsContent />
    </Suspense>
  );
}
