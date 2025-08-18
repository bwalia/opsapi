"use client";
import { useState, useEffect } from "react";
import { useRouter, useParams } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";
import { ProductVariant } from "@/types";
import ConfirmDialog from "@/components/ui/ConfirmDialog";

export default function ProductVariants() {
  const [product, setProduct] = useState<any>(null);
  const [variants, setVariants] = useState<ProductVariant[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [editingVariant, setEditingVariant] = useState<ProductVariant | null>(
    null
  );
  const [deleteDialog, setDeleteDialog] = useState<{
    open: boolean;
    id: string | null;
  }>({ open: false, id: null });
  const [formData, setFormData] = useState({
    title: "",
    option1: "",
    option2: "",
    option3: "",
    sku: "",
    price: "",
    inventory_quantity: "0",
    is_active: true,
  });

  const { user, loading: authLoading } = useAuth();
  const router = useRouter();
  const params = useParams();
  const productId = params.id as string;

  useEffect(() => {
    if (!authLoading && (!user || user.role !== "seller")) {
      router.push("/login");
      return;
    }

    if (user && productId) loadData();
  }, [user, authLoading, router, productId]);

  const loadData = async () => {
    try {
      setLoading(true);
      const [productResponse, variantsResponse] = await Promise.all([
        api.getProduct(productId),
        api.getVariants(productId),
      ]);
      setProduct(productResponse);
      setVariants(Array.isArray(variantsResponse) ? variantsResponse : []);
    } catch (error) {
      console.error("Failed to load data:", error);
      router.push("/seller/products");
    } finally {
      setLoading(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      if (editingVariant)
        await api.updateVariant(editingVariant.uuid, formData);
      else await api.createVariant(productId, formData);
      setShowForm(false);
      setEditingVariant(null);
      resetForm();
      await loadData();
    } catch (error: any) {
      alert(
        `Failed to ${editingVariant ? "update" : "create"} variant: ${
          error.message
        }`
      );
    }
  };

  const handleEdit = (variant: ProductVariant) => {
    setEditingVariant(variant);
    setFormData({
      title: variant.title,
      option1: variant.option1 || "",
      option2: variant.option2 || "",
      option3: variant.option3 || "",
      sku: variant.sku || "",
      price: variant.price?.toString() || "",
      inventory_quantity: variant.inventory_quantity.toString(),
      is_active: variant.is_active,
    });
    setShowForm(true);
  };

  const requestDelete = (variantId: string) =>
    setDeleteDialog({ open: true, id: variantId });

  const confirmDelete = async () => {
    if (!deleteDialog.id) return setDeleteDialog({ open: false, id: null });
    try {
      await api.deleteVariant(deleteDialog.id);
      await loadData();
    } catch (error: any) {
      alert(`Failed to delete variant: ${error.message}`);
    } finally {
      setDeleteDialog({ open: false, id: null });
    }
  };

  const resetForm = () => {
    setFormData({
      title: "",
      option1: "",
      option2: "",
      option3: "",
      sku: "",
      price: "",
      inventory_quantity: "0",
      is_active: true,
    });
  };

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]:
        type === "checkbox" ? (e.target as HTMLInputElement).checked : value,
    }));
  };

  if (loading || authLoading)
    return <div className="container mx-auto px-4 py-8">Loading...</div>;

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="mb-6">
        <button
          onClick={() => router.back()}
          className="text-[#fe004d] hover:text-[#e6003d] mb-4"
        >
          ← Back to Products
        </button>
        <div className="flex justify-between items-center">
          <div>
            <h1 className="text-2xl font-bold">Product Variants</h1>
            <p className="text-gray-600">
              Managing variants for: {product?.name}
            </p>
          </div>
          <button onClick={() => setShowForm(true)} className="btn-primary">
            Add Variant
          </button>
        </div>
      </div>

      {/* Confirm Delete */}
      <ConfirmDialog
        open={deleteDialog.open}
        title="Delete Variant"
        message="Are you sure you want to delete this variant?"
        onCancel={() => setDeleteDialog({ open: false, id: null })}
        onConfirm={confirmDelete}
        confirmText="Delete"
      />

      {/* Variant Form Modal */}
      {showForm && (
        <div className="fixed inset-0 bg-black/50 backdrop-blur-sm flex items-center justify-center z-50 p-4">
          <div className="bg-white p-6 rounded-xl w-full max-w-2xl max-h-screen overflow-y-auto shadow-xl">
            <h2 className="text-xl font-semibold mb-4">
              {editingVariant ? "Edit Variant" : "Add New Variant"}
            </h2>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Variant Title
                </label>
                <input
                  type="text"
                  name="title"
                  required
                  value={formData.title}
                  onChange={handleChange}
                  placeholder="e.g., Red / Large"
                  className="input"
                />
              </div>
              <div className="grid grid-cols-3 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Option 1 (e.g., Color)
                  </label>
                  <input
                    type="text"
                    name="option1"
                    value={formData.option1}
                    onChange={handleChange}
                    placeholder="Red"
                    className="input"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Option 2 (e.g., Size)
                  </label>
                  <input
                    type="text"
                    name="option2"
                    value={formData.option2}
                    onChange={handleChange}
                    placeholder="Large"
                    className="input"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Option 3 (e.g., Material)
                  </label>
                  <input
                    type="text"
                    name="option3"
                    value={formData.option3}
                    onChange={handleChange}
                    placeholder="Cotton"
                    className="input"
                  />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    SKU
                  </label>
                  <input
                    type="text"
                    name="sku"
                    value={formData.sku}
                    onChange={handleChange}
                    className="input"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Price ($)
                  </label>
                  <input
                    type="number"
                    name="price"
                    step="0.01"
                    value={formData.price}
                    onChange={handleChange}
                    placeholder="Leave empty to use product price"
                    className="input"
                  />
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
                    required
                    value={formData.inventory_quantity}
                    onChange={handleChange}
                    className="input"
                  />
                </div>
                <div className="flex items-center pt-6">
                  <input
                    type="checkbox"
                    name="is_active"
                    checked={formData.is_active}
                    onChange={handleChange}
                    className="mr-2"
                  />
                  <label className="text-sm text-gray-700">
                    Active variant
                  </label>
                </div>
              </div>
              <div className="flex justify-end gap-2 pt-2">
                <button
                  type="button"
                  onClick={() => {
                    setShowForm(false);
                    setEditingVariant(null);
                    resetForm();
                  }}
                  className="px-4 py-2 border border-gray-300 rounded hover:bg-gray-50"
                >
                  Cancel
                </button>
                <button type="submit" className="btn-primary">
                  {editingVariant ? "Update" : "Add"} Variant
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Variants List */}
      {variants.length === 0 ? (
        <div className="text-center py-12">
          <div className="text-4xl mb-4">📦</div>
          <h3 className="text-lg font-semibold text-gray-700 mb-2">
            No Variants Yet
          </h3>
          <p className="text-gray-500 mb-4">
            Add variants to offer different options for this product
          </p>
          <button onClick={() => setShowForm(true)} className="btn-primary">
            Add Your First Variant
          </button>
        </div>
      ) : (
        <div className="bg-white rounded-lg shadow overflow-hidden">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Variant
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Options
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  SKU
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Price
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Stock
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody className="bg-white divide-y divide-gray-200">
              {variants.map((variant) => (
                <tr key={variant.uuid}>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <div className="text-sm font-medium text-gray-900">
                      {variant.title}
                    </div>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <div className="text-sm text-gray-500">
                      {[variant.option1, variant.option2, variant.option3]
                        .filter(Boolean)
                        .join(" / ")}
                    </div>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                    {variant.sku || "N/A"}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    {variant.price
                      ? `$${parseFloat(variant.price.toString()).toFixed(2)}`
                      : "Default"}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                    {variant.inventory_quantity}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <span
                      className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${
                        variant.is_active
                          ? "bg-green-100 text-green-800"
                          : "bg-gray-100 text-gray-800"
                      }`}
                    >
                      {variant.is_active ? "Active" : "Inactive"}
                    </span>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm font-medium">
                    <button
                      onClick={() => handleEdit(variant)}
                      className="text-blue-600 hover:text-blue-900 mr-3"
                    >
                      Edit
                    </button>
                    <button
                      onClick={() => requestDelete(variant.uuid)}
                      className="text-red-600 hover:text-red-900"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
