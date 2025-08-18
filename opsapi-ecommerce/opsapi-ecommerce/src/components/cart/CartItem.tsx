import React from "react";
import { useCart } from "@/contexts/CartContext";
import { Button } from "@/components/ui/Button";
import { Card, CardContent } from "@/components/ui/Card";
import { formatPrice } from "@/lib/utils";

interface CartItemProps {
  item: {
    product_uuid: string;
    name: string;
    price: number;
    quantity: number;
    variant_title?: string;
    variant_uuid?: string;
  };
  onRemove?: () => void;
}

export default function CartItem({ item, onRemove }: CartItemProps) {
  const { removeFromCart } = useCart();
  const itemTotal = item.price * item.quantity;

  const handleRemove = async () => {
    try {
      await removeFromCart(item.product_uuid);
      onRemove?.();
    } catch (error) {
      console.error("Failed to remove item:", error);
      alert("Failed to remove item from cart");
    }
  };

  return (
    <Card className="hover:shadow-md transition-shadow">
      <CardContent className="p-4">
        <div className="flex items-center justify-between">
          <div className="flex-1 min-w-0">
            <h3 className="font-semibold text-lg text-gray-900 mb-1 truncate">
              {item.name || "Unknown Product"}
            </h3>
            {item.variant_title && (
              <p className="text-sm text-primary mb-2">
                Variant: {item.variant_title}
              </p>
            )}
            <div className="space-y-1">
              <p className="text-gray-600">{formatPrice(item.price)} each</p>
              <p className="text-sm text-gray-500">Quantity: {item.quantity}</p>
            </div>
          </div>

          <div className="flex items-center space-x-4 ml-4">
            <div className="text-right">
              <span className="text-xl font-bold text-primary">
                {formatPrice(itemTotal)}
              </span>
            </div>

            <Button
              variant="ghost"
              size="icon"
              onClick={handleRemove}
              className="text-gray-400 hover:text-red-500 hover:bg-red-50"
              title="Remove item"
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
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
