"use client";
import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";
import DashboardStats from "@/components/seller/DashboardStats";
import StoreManagement from "@/components/seller/StoreManagement";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";

interface Store {
  uuid: string;
  name: string;
  description?: string;
  slug: string;
  created_at?: string;
}

export default function SellerDashboard() {
  const [stats, setStats] = useState({
    stores: 0,
    products: 0,
    orders: 0,
    revenue: 0,
  });
  const [stores, setStores] = useState<Store[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedStore, setSelectedStore] = useState<Store | null>(null);

  const { user, loading: authLoading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!authLoading && (!user || user.role !== "seller")) {
      router.push("/login");
      return;
    }

    if (user && user.role === "seller") {
      loadDashboardData();
    }
  }, [user, authLoading, router]);

  const loadDashboardData = async () => {
    try {
      setLoading(true);

      const storesResponse = await api.getMyStores();
      const storesData = Array.isArray(storesResponse?.data)
        ? storesResponse.data
        : Array.isArray(storesResponse)
        ? storesResponse
        : [];

      setStores(storesData);

      let totalProducts = 0;
      for (const store of storesData) {
        try {
          const productsResponse = await api.searchProducts({
            store_id: store.uuid,
          });
          const products = Array.isArray(productsResponse?.data)
            ? productsResponse.data
            : Array.isArray(productsResponse)
            ? productsResponse
            : [];
          totalProducts += products.length;
        } catch (error) {
          console.error(
            `Failed to load products for store ${store.uuid}:`,
            error
          );
        }
      }

      setStats({
        stores: storesData.length,
        products: totalProducts,
        orders: 0, // TODO: Implement orders API
        revenue: 0, // TODO: Calculate from orders
      });
    } catch (error) {
      console.error("Failed to load dashboard data:", error);
    } finally {
      setLoading(false);
    }
  };

  const handleQuickActions = (action: string) => {
    switch (action) {
      case "create-store":
        router.push("/seller/stores/new");
        break;
      case "add-product":
        if (stores.length > 0) {
          router.push(`/seller/stores/${stores[0].uuid}/products/new`);
        } else {
          router.push("/seller/stores/new");
        }
        break;
      case "view-orders":
        router.push("/seller/orders");
        break;
      case "analytics":
        router.push("/seller/analytics");
        break;
    }
  };

  if (loading || authLoading) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="text-center">
          <div className="text-2xl font-semibold text-gray-700">
            Loading dashboard...
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="container mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Header */}
        <div className="mb-8">
          <h1 className="text-4xl font-bold text-gray-800 mb-2">
            Seller Dashboard
          </h1>
          <p className="text-lg text-gray-600">Welcome back, {user?.name}!</p>
        </div>

        {/* Stats Cards */}
        <DashboardStats stats={stats} />

        {/* Quick Actions */}
        <Card className="mb-8">
          <CardHeader>
            <CardTitle>Quick Actions</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
              <Button
                variant="outline"
                onClick={() => handleQuickActions("create-store")}
                className="h-20 flex flex-col items-center justify-center space-y-2"
              >
                <svg
                  className="w-6 h-6"
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
                <span>Create Store</span>
              </Button>

              <Button
                variant="outline"
                onClick={() => handleQuickActions("add-product")}
                className="h-20 flex flex-col items-center justify-center space-y-2"
                disabled={stores.length === 0}
              >
                <svg
                  className="w-6 h-6"
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
                <span>Add Product</span>
              </Button>

              <Button
                variant="outline"
                onClick={() => handleQuickActions("view-orders")}
                className="h-20 flex flex-col items-center justify-center space-y-2"
              >
                <svg
                  className="w-6 h-6"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                  />
                </svg>
                <span>View Orders</span>
              </Button>

              <Button
                variant="outline"
                onClick={() => handleQuickActions("analytics")}
                className="h-20 flex flex-col items-center justify-center space-y-2"
              >
                <svg
                  className="w-6 h-6"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2zm0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
                <span>Analytics</span>
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Store Management */}
        <StoreManagement stores={stores} onStoreSelect={setSelectedStore} />
      </div>
    </div>
  );
}
