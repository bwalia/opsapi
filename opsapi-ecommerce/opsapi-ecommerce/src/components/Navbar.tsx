"use client";
import Link from "next/link";
import { useAuth } from "@/contexts/AuthContext";
import { useCart } from "@/contexts/CartContext";
import { useState } from "react";

export default function Navbar() {
  const { user, logout } = useAuth();
  const { itemCount } = useCart();
  const [isMenuOpen, setIsMenuOpen] = useState(false);

  return (
    <nav className="bg-white shadow-sm border-b border-gray-100 sticky top-0 z-50">
      <div className="container mx-auto px-4">
        <div className="flex justify-between items-center h-14">
          {/* Logo */}
          <Link href="/" className="flex items-center space-x-2">
            <div className="w-6 h-6 bg-[#fe004d] rounded-md flex items-center justify-center">
              <span className="text-white font-bold text-sm">K</span>
            </div>
            <span className="text-lg font-bold text-gray-900">Kisaan</span>
          </Link>

          {/* Desktop Navigation */}
          <div className="hidden md:flex items-center space-x-6">
            <Link
              href="/"
              className="text-gray-600 hover:text-[#fe004d] text-sm font-medium transition-colors"
            >
              Home
            </Link>

            <Link
              href="/cart"
              className="relative text-gray-600 hover:text-[#fe004d] text-sm font-medium transition-colors"
            >
              <div className="flex items-center space-x-1">
                <svg
                  className="w-4 h-4"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M3 3h2l.4 2M7 13h10l4-8H5.4m0 0L7 13m0 0l-1.1 5M7 13l-1.1 5m0 0h9.1M17 13v6a2 2 0 01-2 2H9a2 2 0 01-2-2v-6"
                  />
                </svg>
                <span>Cart</span>
              </div>
              {itemCount > 0 && (
                <span className="absolute -top-1 -right-1 bg-[#fe004d] text-white rounded-full w-4 h-4 flex items-center justify-center text-xs font-medium">
                  {itemCount}
                </span>
              )}
            </Link>

            {user ? (
              <div className="flex items-center space-x-3">
                <span className="text-xs text-gray-500">Hi, {user.name}</span>
                {user.role === "seller" && (
                  <Link
                    href="/seller/stores"
                    className="btn-secondary text-xs px-3 py-1.5"
                  >
                    Dashboard
                  </Link>
                )}
                <button
                  onClick={logout}
                  className="text-gray-400 hover:text-gray-600 text-xs"
                >
                  Logout
                </button>
              </div>
            ) : (
              <div className="flex items-center space-x-3">
                <Link
                  href="/login"
                  className="text-gray-600 hover:text-[#fe004d] text-sm font-medium"
                >
                  Login
                </Link>
                <Link
                  href="/register"
                  className="btn-primary text-xs px-4 py-2"
                >
                  Get Started
                </Link>
              </div>
            )}
          </div>

          {/* Mobile menu button */}
          <button
            onClick={() => setIsMenuOpen(!isMenuOpen)}
            className="md:hidden p-1.5 rounded-md hover:bg-gray-100"
          >
            <svg
              className="w-5 h-5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M4 6h16M4 12h16M4 18h16"
              />
            </svg>
          </button>
        </div>

        {/* Mobile Navigation */}
        {isMenuOpen && (
          <div className="md:hidden py-3 border-t border-gray-100">
            <div className="flex flex-col space-y-2">
              <Link
                href="/"
                className="text-gray-600 hover:text-[#fe004d] text-sm font-medium py-1"
              >
                Home
              </Link>
              <Link
                href="/cart"
                className="text-gray-600 hover:text-[#fe004d] text-sm font-medium flex items-center py-1"
              >
                Cart{" "}
                {itemCount > 0 && (
                  <span className="ml-2 bg-[#fe004d] text-white rounded-full w-4 h-4 flex items-center justify-center text-xs">
                    {itemCount}
                  </span>
                )}
              </Link>
              {user ? (
                <>
                  {user.role === "seller" && (
                    <Link
                      href="/seller/stores"
                      className="text-gray-600 hover:text-[#fe004d] text-sm font-medium py-1"
                    >
                      Dashboard
                    </Link>
                  )}
                  <button
                    onClick={logout}
                    className="text-left text-gray-400 hover:text-gray-600 text-sm py-1"
                  >
                    Logout
                  </button>
                </>
              ) : (
                <>
                  <Link
                    href="/login"
                    className="text-gray-600 hover:text-[#fe004d] text-sm font-medium py-1"
                  >
                    Login
                  </Link>
                  <Link
                    href="/register"
                    className="btn-primary text-xs px-4 py-2 inline-block text-center mt-2"
                  >
                    Get Started
                  </Link>
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </nav>
  );
}
