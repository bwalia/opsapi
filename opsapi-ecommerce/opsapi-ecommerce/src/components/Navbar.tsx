"use client";
import { useState, useEffect } from "react";
import Link from "next/link";
import { useAuth } from "@/contexts/AuthContext";
import api from "@/lib/api";

export default function Navbar() {
  const { user, logout } = useAuth();
  const [cartCount, setCartCount] = useState(0);

  useEffect(() => {
    const updateCartCount = async () => {
      try {
        const response = await api.getCart();
        const cart = response?.cart || {};
        const count = Object.values(cart).reduce((total: number, item: any) => {
          return total + (item?.quantity || 0);
        }, 0);
        setCartCount(count);
      } catch (error) {
        console.error("Failed to update cart count:", error);
      }
    };

    updateCartCount();

    const handleCartUpdate = () => updateCartCount();
    window.addEventListener("cartUpdated", handleCartUpdate);

    return () => window.removeEventListener("cartUpdated", handleCartUpdate);
  }, []);

  return (
    <nav className="bg-white shadow-sm border-b">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-16">
          <div className="flex items-center">
            <Link href="/" className="text-xl font-bold text-gray-900">
              Kisaan
            </Link>
          </div>

          <div className="flex items-center space-x-4">
            <Link href="/" className="text-gray-700 hover:text-gray-900">
              Products
            </Link>

            <Link
              href="/cart"
              className="text-gray-700 hover:text-gray-900 relative"
            >
              Cart
              {cartCount > 0 && (
                <span className="absolute -top-2 -right-2 bg-red-500 text-white text-xs rounded-full h-5 w-5 flex items-center justify-center">
                  {cartCount}
                </span>
              )}
            </Link>

            {user ? (
              <div className="flex items-center space-x-4">
                {user.role === "seller" && (
                  <Link
                    href="/seller/dashboard"
                    className="text-gray-700 hover:text-gray-900"
                  >
                    Dashboard
                  </Link>
                )}
                <span className="text-gray-700">Hi, {user.name}</span>
                <button
                  onClick={logout}
                  className="bg-red-600 text-white px-3 py-1 rounded text-sm hover:bg-red-700"
                >
                  Logout
                </button>
              </div>
            ) : (
              <div className="flex items-center space-x-2">
                <Link
                  href="/login"
                  className="text-gray-700 hover:text-gray-900"
                >
                  Login
                </Link>
                <Link
                  href="/register"
                  className="bg-blue-600 text-white px-3 py-1 rounded text-sm hover:bg-blue-700"
                >
                  Register
                </Link>
              </div>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
