"use client";
import Link from "next/link";
import { useCart } from "@/contexts/CartContext";

export default function Cart() {
  const { cart, total, loading, removeFromCart, clearCart } = useCart();

  if (loading) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center">Loading cart...</div>
      </div>
    );
  }

  const cartItems = cart && typeof cart === 'object' ? 
    Object.values(cart).filter(item => 
      item && 
      typeof item === 'object' && 
      item.product_uuid && 
      item.name && 
      typeof item.price === 'number' && 
      typeof item.quantity === 'number' &&
      item.price > 0 &&
      item.quantity > 0
    ) : [];

  if (cartItems.length === 0) {
    return (
      <div className="container mx-auto px-4 py-8">
        <div className="text-center py-12">
          <h1 className="text-2xl font-bold mb-4">Your Cart is Empty</h1>
          <p className="text-gray-600 mb-6">
            Add some products to get started!
          </p>
          <Link
            href="/"
            className="bg-blue-600 text-white px-6 py-2 rounded hover:bg-blue-700"
          >
            Continue Shopping
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen py-8">
      <div className="container mx-auto px-4">
        <div className="flex justify-between items-center mb-8">
          <h1 className="text-3xl font-bold text-gray-900">Shopping Cart</h1>
          <button
            onClick={() => {
              try {
                if (confirm('Are you sure you want to clear your cart?')) {
                  clearCart();
                }
              } catch (error) {
                console.error('Failed to clear cart:', error);
                alert('Failed to clear cart');
              }
            }}
            className="text-gray-500 hover:text-[#fe004d] text-sm font-medium"
          >
            Clear Cart
          </button>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-2">
            <div className="space-y-4">
              {cartItems.map((item: any) => {
                const itemTotal = (item.price * item.quantity);
                return (
                  <div
                    key={`${item.product_uuid}_${item.variant_uuid || 'default'}`}
                    className="card flex items-center justify-between"
                  >
                    <div className="flex-1">
                      <h3 className="font-semibold text-lg text-gray-900 mb-1">{item.name || 'Unknown Product'}</h3>
                      {item.variant_title && (
                        <p className="text-sm text-[#fe004d] mb-2">
                          Variant: {item.variant_title}
                        </p>
                      )}
                      <p className="text-gray-600 mb-1">${item.price.toFixed(2)} each</p>
                      <p className="text-sm text-gray-500">
                        Quantity: {item.quantity}
                      </p>
                    </div>
                    <div className="flex items-center space-x-4">
                      <span className="text-xl font-bold text-[#fe004d]">
                        ${itemTotal.toFixed(2)}
                      </span>
                      <button
                        onClick={() => {
                          try {
                            removeFromCart(item.product_uuid);
                          } catch (error) {
                            console.error('Failed to remove item:', error);
                            alert('Failed to remove item from cart');
                          }
                        }}
                        className="text-gray-400 hover:text-red-500 p-2 rounded-lg hover:bg-red-50 transition-colors"
                      >
                        <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                        </svg>
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="lg:col-span-1">
            <div className="card sticky top-4">
              <h2 className="text-xl font-semibold mb-6 text-gray-900">Order Summary</h2>

              <div className="space-y-3 mb-6">
                <div className="flex justify-between text-gray-600">
                  <span>Subtotal:</span>
                  <span>${(typeof total === 'number' ? total : 0).toFixed(2)}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                  <span>Tax (8.5%):</span>
                  <span>${(typeof total === 'number' ? total * 0.085 : 0).toFixed(2)}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                  <span>Shipping:</span>
                  <span className="text-green-600">
                    {(typeof total === 'number' && total > 50) ? 'FREE' : '$5.99'}
                  </span>
                </div>
                {(typeof total === 'number' && total > 0 && total <= 50) && (
                  <p className="text-sm text-gray-500">
                    Add ${(50 - total).toFixed(2)} more for free shipping!
                  </p>
                )}
                <div className="border-t pt-3 flex justify-between text-lg font-bold text-gray-900">
                  <span>Total:</span>
                  <span className="text-[#fe004d]">
                    ${(typeof total === 'number' ? (total * 1.085 + (total > 50 ? 0 : 5.99)) : 5.99).toFixed(2)}
                  </span>
                </div>
              </div>

              <Link
                href="/checkout"
                className="btn-primary w-full text-center block mb-3"
              >
                Proceed to Checkout
              </Link>

              <Link
                href="/"
                className="btn-secondary w-full text-center block"
              >
                Continue Shopping
              </Link>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
