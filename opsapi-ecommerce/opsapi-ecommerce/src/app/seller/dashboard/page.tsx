"use client";
import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";

export default function SellerDashboard() {
  const [stats, setStats] = useState({
    stores: 0,
    products: 0,
    orders: 0,
    revenue: 0,
  });
  const [stores, setStores] = useState([]);
  const [loading, setLoading] = useState(true);

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
          const productsResponse = await api.searchProducts({ store_id: store.uuid });
          const products = Array.isArray(productsResponse?.data)
            ? productsResponse.data
            : Array.isArray(productsResponse)
            ? productsResponse
            : [];
          totalProducts += products.length;
        } catch (error) {
          console.error(`Failed to load products for store ${store.uuid}:`, error);
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

  if (loading || authLoading) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="text-center">
          <div className="text-2xl font-semibold text-gray-700">Loading dashboard...</div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="container mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="mb-8">
          <h1 className="text-4xl font-bold text-gray-800 mb-2">Seller Dashboard</h1>
          <p className="text-lg text-gray-600">Welcome back, {user?.name}!</p>
        </div>

        {/* Stats Cards */}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
          <StatCard title="Total Stores" value={stats.stores} icon="store" />
          <StatCard title="Total Products" value={stats.products} icon="product" />
          <StatCard title="Total Orders" value={stats.orders} icon="order" />
          <StatCard title="Revenue" value={`$${stats.revenue.toFixed(2)}`} icon="revenue" />
        </div>

        {/* Quick Actions */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <ActionCard title="Manage Stores" description="Create and manage your stores" link="/seller/stores" icon="store" />
          <ActionCard title="Manage Products" description="Add and edit your products" link="/seller/products" icon="product" />
          <ActionCard title="Manage Categories" description="Organize your products" link="/seller/categories" icon="category" />
        </div>

        {/* Recent Stores */}
        <div className="bg-white rounded-xl shadow-md overflow-hidden">
          <div className="p-6 border-b border-gray-200">
            <div className="flex items-center justify-between">
              <h2 className="text-2xl font-semibold text-gray-800">Your Stores</h2>
              <Link href="/seller/stores" className="text-blue-600 hover:text-blue-700 font-medium">
                View All
              </Link>
            </div>
          </div>
          <div className="p-6">
            {stores.length === 0 ? (
              <div className="text-center py-12">
                <div className="text-5xl mb-4">🏪</div>
                <h3 className="text-xl font-semibold text-gray-700 mb-2">No Stores Yet</h3>
                <p className="text-gray-500 mb-6">Create your first store to start selling.</p>
                <Link href="/seller/stores" className="bg-blue-600 text-white px-6 py-3 rounded-lg font-semibold hover:bg-blue-700 transition-colors">
                  Create Store
                </Link>
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                {stores.slice(0, 6).map((store: any) => (
                  <StoreCard key={store.uuid} store={store} />
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

const StatCard = ({ title, value, icon }: { title: string, value: string | number, icon: string }) => (
  <div className="bg-white p-6 rounded-xl shadow-md flex items-center">
    <div className={`p-3 rounded-full bg-${getIconColor(icon)}-100`}>
      <Icon name={icon} className={`w-7 h-7 text-${getIconColor(icon)}-600`} />
    </div>
    <div className="ml-4">
      <p className="text-sm font-medium text-gray-500">{title}</p>
      <p className="text-3xl font-bold text-gray-800">{value}</p>
    </div>
  </div>
);

const ActionCard = ({ title, description, link, icon }: { title: string, description: string, link: string, icon: string }) => (
  <Link href={link} className="bg-white p-6 rounded-xl shadow-md hover:shadow-lg transition-shadow flex items-center">
    <div className={`p-3 rounded-full bg-${getIconColor(icon)}-100`}>
      <Icon name={icon} className={`w-8 h-8 text-${getIconColor(icon)}-600`} />
    </div>
    <div className="ml-4">
      <h3 className="text-lg font-semibold text-gray-800 mb-1">{title}</h3>
      <p className="text-gray-500 text-sm">{description}</p>
    </div>
  </Link>
);

const StoreCard = ({ store }: { store: any }) => (
  <div className="border border-gray-200 rounded-xl p-5 hover:shadow-md transition-shadow bg-white">
    <h3 className="font-semibold text-xl mb-2 text-gray-800">{store.name}</h3>
    <p className="text-gray-600 text-sm mb-4 h-10 overflow-hidden">{store.description || "No description"}</p>
    <div className="flex items-center justify-between">
      <span className={`px-3 py-1 rounded-full text-xs font-medium ${store.status === "active" ? "bg-green-100 text-green-800" : "bg-gray-100 text-gray-800"}`}>
        {store.status}
      </span>
      <Link href={`/seller/products?store=${store.uuid}`} className="text-blue-600 hover:text-blue-700 text-sm font-medium">
        Manage Products &rarr;
      </Link>
    </div>
  </div>
);

const Icon = ({ name, className }: { name: string, className: string }) => {
  const icons: { [key: string]: JSX.Element } = {
    store: <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-4m-5 0H3m2 0h3M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 8h1m-1-4h1m4 4h1m-1-4h1" />,
    product: <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />,
    order: <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />,
    revenue: <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1" />,
    category: <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
  };
  return <svg className={className} fill="none" stroke="currentColor" viewBox="0 0 24 24">{icons[name]}</svg>;
};

const getIconColor = (icon: string) => {
  switch (icon) {
    case 'store': return 'blue';
    case 'product': return 'green';
    case 'order': return 'yellow';
    case 'revenue': return 'purple';
    case 'category': return 'indigo';
    default: return 'gray';
  }
};