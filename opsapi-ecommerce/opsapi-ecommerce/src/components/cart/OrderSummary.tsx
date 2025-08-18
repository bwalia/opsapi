import React from "react";
import { useRouter } from "next/navigation";
import { useCart } from "@/contexts/CartContext";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { formatPrice } from "@/lib/utils";

interface OrderSummaryProps {
  className?: string;
}

export default function OrderSummary({ className }: OrderSummaryProps) {
  const { total } = useCart();
  const router = useRouter();

  const subtotal = typeof total === "number" ? total : 0;
  const tax = subtotal * 0.085; // 8.5% tax
  const shipping = subtotal > 50 ? 0 : 5.99;
  const totalAmount = subtotal + tax + shipping;

  const handleCheckout = () => {
    router.push("/checkout");
  };

  const handleContinueShopping = () => {
    router.push("/");
  };

  return (
    <Card className={`sticky top-4 ${className}`}>
      <CardHeader>
        <CardTitle>Order Summary</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-3">
          <div className="flex justify-between text-gray-600">
            <span>Subtotal:</span>
            <span>{formatPrice(subtotal)}</span>
          </div>

          <div className="flex justify-between text-gray-600">
            <span>Tax (8.5%):</span>
            <span>{formatPrice(tax)}</span>
          </div>

          <div className="flex justify-between text-gray-600">
            <span>Shipping:</span>
            <span
              className={shipping === 0 ? "text-green-600 font-medium" : ""}
            >
              {shipping === 0 ? "FREE" : formatPrice(shipping)}
            </span>
          </div>

          {subtotal > 0 && subtotal <= 50 && (
            <p className="text-sm text-gray-500 bg-blue-50 p-2 rounded">
              Add {formatPrice(50 - subtotal)} more for free shipping!
            </p>
          )}

          <div className="border-t pt-3 flex justify-between text-lg font-bold text-gray-900">
            <span>Total:</span>
            <span className="text-primary">{formatPrice(totalAmount)}</span>
          </div>
        </div>

        <div className="space-y-3 pt-4">
          <Button onClick={handleCheckout} className="w-full">
            Proceed to Checkout
          </Button>

          <Button
            variant="outline"
            onClick={handleContinueShopping}
            className="w-full"
          >
            Continue Shopping
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
