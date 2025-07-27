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
    <div className="container mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-2xl font-bold">Shopping Cart</h1>
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
          className="text-red-600 hover:text-red-800 text-sm"
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
                  className="border rounded-lg p-4 flex items-center justify-between"
                >
                  <div className="flex-1">
                    <h3 className="font-semibold">{item.name || 'Unknown Product'}</h3>
                    {item.variant_title && (
                      <p className="text-sm text-blue-600 mb-1">
                        Variant: {item.variant_title}
                      </p>
                    )}
                    <p className="text-gray-600">${item.price.toFixed(2)} each</p>
                    <p className="text-sm text-gray-500">
                      Quantity: {item.quantity}
                    </p>
                  </div>
                  <div className="flex items-center space-x-4">
                    <span className="font-semibold">
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
                      className="text-red-600 hover:text-red-800 text-sm"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        <div className="lg:col-span-1">
          <div className="border rounded-lg p-6 sticky top-4">
            <h2 className="text-xl font-semibold mb-4">Order Summary</h2>

            <div className="space-y-2 mb-4">
              <div className="flex justify-between">
                <span>Subtotal:</span>
                <span>${(typeof total === 'number' ? total : 0).toFixed(2)}</span>
              </div>
              <div className="flex justify-between">
                <span>Tax (8.5%):</span>
                <span>${(typeof total === 'number' ? total * 0.085 : 0).toFixed(2)}</span>
              </div>
              <div className="flex justify-between">
                <span>Shipping:</span>
                <span>${(typeof total === 'number' && total > 50) ? '0.00' : '5.99'}</span>
              </div>
              <div className="border-t pt-2 flex justify-between font-semibold">
                <span>Total:</span>
                <span>${(typeof total === 'number' ? (total * 1.085 + (total > 50 ? 0 : 5.99)) : 5.99).toFixed(2)}</span>
              </div>
            </div>

            <Link
              href="/checkout"
              className="w-full bg-blue-600 text-white py-3 px-4 rounded hover:bg-blue-700 block text-center"
            >
              Proceed to Checkout
            </Link>

            <Link
              href="/"
              className="w-full mt-2 border border-gray-300 py-3 px-4 rounded hover:bg-gray-50 block text-center"
            >
              Continue Shopping
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
