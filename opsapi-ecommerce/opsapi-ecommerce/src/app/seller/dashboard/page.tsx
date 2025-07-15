'use client';
import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useAuth } from '@/contexts/AuthContext';
import api from '@/lib/api';

export default function SellerDashboard() {
  const [stores, setStores] = useState([]);
  const [stats, setStats] = useState({ stores: 0, products: 0, orders: 0 });
  const [loading, setLoading] = useState(true);
  const { user, loading: authLoading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!authLoading && !user) {
      router.push('/login');
      return;
    }
    if (user) {
      loadDashboard();
    }
  }, [user, authLoading, router]);

  const loadDashboard = async () => {
    try {
      // Load user's stores
      const storesResponse = await api.getStores();
      const storesData = Array.isArray(storesResponse?.data) ? storesResponse.data : 
                        Array.isArray(storesResponse) ? storesResponse : [];
      
      setStores(storesData);
      setStats({
        stores: storesData.length,
        products: 0, // TODO: Add product count
        orders: 0    // TODO: Add order count
      });
    } catch (error) {
      console.error('Failed to load dashboard:', error);
      setStores([]);
      setStats({ stores: 0, products: 0, orders: 0 });
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return <div className="container mx-auto px-4 py-8">Loading dashboard...</div>;
  }

  return (
    <div className="container mx-auto px-4 py-8">
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">Seller Dashboard</h1>
        <p className="text-gray-600">Welcome back, {user?.name}!</p>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
        <div className="bg-white p-6 rounded-lg shadow">
          <h3 className="text-lg font-semibold text-gray-700">Stores</h3>
          <p className="text-3xl font-bold text-blue-600">{stats.stores}</p>
        </div>
        <div className="bg-white p-6 rounded-lg shadow">
          <h3 className="text-lg font-semibold text-gray-700">Products</h3>
          <p className="text-3xl font-bold text-green-600">{stats.products}</p>
        </div>
        <div className="bg-white p-6 rounded-lg shadow">
          <h3 className="text-lg font-semibold text-gray-700">Orders</h3>
          <p className="text-3xl font-bold text-orange-600">{stats.orders}</p>
        </div>
      </div>

      {/* Quick Actions */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <Link
          href="/seller/stores"
          className="bg-blue-600 text-white p-4 rounded-lg hover:bg-blue-700 text-center"
        >
          <div className="text-2xl mb-2">🏪</div>
          <div>Manage Stores</div>
        </Link>
        <Link
          href="/seller/products"
          className="bg-green-600 text-white p-4 rounded-lg hover:bg-green-700 text-center"
        >
          <div className="text-2xl mb-2">📦</div>
          <div>Manage Products</div>
        </Link>
        <Link
          href="/seller/categories"
          className="bg-purple-600 text-white p-4 rounded-lg hover:bg-purple-700 text-center"
        >
          <div className="text-2xl mb-2">📂</div>
          <div>Categories</div>
        </Link>
        <Link
          href="/seller/orders"
          className="bg-orange-600 text-white p-4 rounded-lg hover:bg-orange-700 text-center"
        >
          <div className="text-2xl mb-2">📋</div>
          <div>Orders</div>
        </Link>
      </div>

      {/* Recent Stores */}
      <div className="bg-white rounded-lg shadow">
        <div className="p-6 border-b">
          <div className="flex justify-between items-center">
            <h2 className="text-xl font-semibold">Your Stores</h2>
            <Link
              href="/seller/stores"
              className="text-blue-600 hover:text-blue-800 text-sm"
            >
              View All
            </Link>
          </div>
        </div>
        <div className="p-6">
          {stores.length === 0 ? (
            <div className="text-center py-8">
              <div className="text-4xl mb-4">🏪</div>
              <h3 className="text-lg font-semibold text-gray-700 mb-2">No Stores Yet</h3>
              <p className="text-gray-500 mb-4">Create your first store to start selling</p>
              <Link
                href="/seller/stores"
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
              >
                Create Store
              </Link>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {stores && stores.length > 0 ? stores.slice(0, 6).map((store: any) => (
                <div key={store.uuid} className="border rounded-lg p-4">
                  <h3 className="font-semibold">{store.name}</h3>
                  <p className="text-gray-600 text-sm">{store.description}</p>
                  <div className="mt-2 flex justify-between items-center">
                    <span className={`px-2 py-1 rounded text-xs ${
                      store.status === 'active' ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800'
                    }`}>
                      {store.status}
                    </span>
                    <Link
                      href={`/seller/stores/${store.uuid}`}
                      className="text-blue-600 hover:text-blue-800 text-sm"
                    >
                      Manage
                    </Link>
                  </div>
                </div>
              )) : (
                <div className="col-span-full text-center py-4">
                  <p className="text-gray-500">No stores to display</p>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}