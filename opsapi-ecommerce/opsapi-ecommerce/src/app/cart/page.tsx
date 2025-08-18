"use client";
import { useState } from "react";
import { useCart } from "@/contexts/CartContext";
import { Button } from "@/components/ui/Button";
import CartItem from "@/components/cart/CartItem";
import OrderSummary from "@/components/cart/OrderSummary";
import EmptyCart from "@/components/cart/EmptyCart";
import CartSkeleton from "@/components/cart/CartSkeleton";

export default function Cart() {
  const { cart, total, loading, clearCart } = useCart();
  const [isClearing, setIsClearing] = useState(false);

  if (loading) {
    return <CartSkeleton />;
  }

  const cartItems =
    cart && typeof cart === "object"
      ? Object.values(cart).filter(
          (item) =>
            item &&
            typeof item === "object" &&
            item.product_uuid &&
            item.name &&
            typeof item.price === "number" &&
            typeof item.quantity === "number" &&
            item.price > 0 &&
            item.quantity > 0
        )
      : [];

  if (cartItems.length === 0) {
    return <EmptyCart />;
  }

  const handleClearCart = async () => {
    if (!confirm("Are you sure you want to clear your cart?")) {
      return;
    }

    try {
      setIsClearing(true);
      await clearCart();
    } catch (error) {
      console.error("Failed to clear cart:", error);
      alert("Failed to clear cart");
    } finally {
      setIsClearing(false);
    }
  };

  return (
    <div className="min-h-screen py-8 bg-gray-50">
      <div className="container mx-auto px-4">
        {/* Header */}
        <div className="flex justify-between items-center mb-8">
          <div>
            <h1 className="text-3xl font-bold text-gray-900">Shopping Cart</h1>
            <p className="text-gray-600 mt-1">
              {cartItems.length} {cartItems.length === 1 ? "item" : "items"} in
              your cart
            </p>
          </div>

          <Button
            variant="outline"
            onClick={handleClearCart}
            loading={isClearing}
            className="text-gray-500 hover:text-red-600 hover:border-red-600"
          >
            Clear Cart
          </Button>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          {/* Cart Items */}
          <div className="lg:col-span-2">
            <div className="space-y-4">
              {cartItems.map((item: any) => (
                <CartItem
                  key={`${item.product_uuid}_${item.variant_uuid || "default"}`}
                  item={item}
                />
              ))}
            </div>
          </div>

          {/* Order Summary */}
          <div className="lg:col-span-1">
            <OrderSummary />
          </div>
        </div>
      </div>
    </div>
  );
}
