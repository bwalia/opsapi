import React, { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { Select } from "@/components/ui/Select";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import api from "@/lib/api";

interface Category {
  uuid: string;
  name: string;
}

interface ProductFormProps {
  storeId: string;
  product?: any;
  mode: "create" | "edit";
}

export default function ProductForm({
  storeId,
  product,
  mode,
}: ProductFormProps) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [categories, setCategories] = useState<Category[]>([]);
  const [formData, setFormData] = useState({
    name: product?.name || "",
    description: product?.description || "",
    price: product?.price || "",
    inventory_quantity: product?.inventory_quantity || "",
    category_id: product?.category_id || "",
    images: product?.images || "",
  });
  const [errors, setErrors] = useState<Record<string, string>>({});

  useEffect(() => {
    loadCategories();
  }, [storeId]);

  const loadCategories = async () => {
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
    }
  };

  const validateForm = () => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = "Product name is required";
    }

    if (!formData.description.trim()) {
      newErrors.description = "Product description is required";
    }

    if (!formData.price || parseFloat(formData.price) <= 0) {
      newErrors.price = "Valid price is required";
    }

    if (
      !formData.inventory_quantity ||
      parseInt(formData.inventory_quantity) < 0
    ) {
      newErrors.inventory_quantity = "Valid inventory quantity is required";
    }

    if (!formData.category_id) {
      newErrors.category_id = "Category is required";
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validateForm()) {
      return;
    }

    try {
      setLoading(true);

      const productData = {
        ...formData,
        store_id: storeId,
        price: parseFloat(formData.price),
        inventory_quantity: parseInt(formData.inventory_quantity),
        images: formData.images
          ? formData.images.split(",").map((img: string) => img.trim())
          : [],
      };

      if (mode === "create") {
        await api.createProduct(storeId, productData);
      } else {
        await api.updateProduct(product?.uuid, productData);
      }

      router.push(`/seller/stores/${storeId}/products`);
    } catch (error: any) {
      console.error("Failed to save product:", error);
      alert(error?.message || "Failed to save product");
    } finally {
      setLoading(false);
    }
  };

  const handleChange = (field: string, value: string) => {
    setFormData((prev) => ({ ...prev, [field]: value }));
    if (errors[field]) {
      setErrors((prev) => ({ ...prev, [field]: "" }));
    }
  };

  const categoryOptions = categories.map((cat) => ({
    value: cat.uuid,
    label: cat.name,
  }));

  return (
    <div className="max-w-2xl mx-auto">
      <Card>
        <CardHeader>
          <CardTitle>
            {mode === "create" ? "Add New Product" : "Edit Product"}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-6">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Product Name *
              </label>
              <Input
                type="text"
                value={formData.name}
                onChange={(e) => handleChange("name", e.target.value)}
                error={!!errors.name}
                helperText={errors.name}
                placeholder="Enter product name"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Description *
              </label>
              <Textarea
                value={formData.description}
                onChange={(e) => handleChange("description", e.target.value)}
                error={!!errors.description}
                helperText={errors.description}
                placeholder="Describe your product"
                rows={4}
              />
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Price *
                </label>
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  value={formData.price}
                  onChange={(e) => handleChange("price", e.target.value)}
                  error={!!errors.price}
                  helperText={errors.price}
                  placeholder="0.00"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Inventory Quantity *
                </label>
                <Input
                  type="number"
                  min="0"
                  value={formData.inventory_quantity}
                  onChange={(e) =>
                    handleChange("inventory_quantity", e.target.value)
                  }
                  error={!!errors.inventory_quantity}
                  helperText={errors.inventory_quantity}
                  placeholder="0"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Category *
              </label>
              <Select
                value={formData.category_id}
                onChange={(e) => handleChange("category_id", e.target.value)}
                options={categoryOptions}
                error={!!errors.category_id}
                helperText={errors.category_id}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Image URLs
              </label>
              <Textarea
                value={formData.images}
                onChange={(e) => handleChange("images", e.target.value)}
                placeholder="Enter image URLs separated by commas"
                rows={3}
                helperText="Enter image URLs separated by commas (optional)"
              />
            </div>

            <div className="flex space-x-4 pt-4">
              <Button type="submit" loading={loading} className="flex-1">
                {mode === "create" ? "Create Product" : "Update Product"}
              </Button>

              <Button
                type="button"
                variant="outline"
                onClick={() => router.back()}
                className="flex-1"
              >
                Cancel
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
