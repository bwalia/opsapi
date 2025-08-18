import React from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";

export default function EmptyCart() {
  const router = useRouter();

  const handleStartShopping = () => {
    router.push("/");
  };

  return (
    <div className="container mx-auto px-4 py-8">
      <Card className="max-w-md mx-auto text-center">
        <CardHeader>
          <div className="mx-auto w-16 h-16 bg-gray-100 rounded-full flex items-center justify-center mb-4">
            <svg
              className="w-8 h-8 text-gray-400"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M3 3h2l.4 2M7 13h10l4-8H5.4m0 0L7 13m0 0l-2.5 5M7 13l2.5 5m6-5v6a2 2 0 01-2 2H9a2 2 0 01-2-2v-6m8 0V9a2 2 0 00-2-2H9a2 2 0 00-2 2v4.01"
              />
            </svg>
          </div>
          <CardTitle className="text-2xl font-bold text-gray-900 mb-2">
            Your Cart is Empty
          </CardTitle>
          <p className="text-gray-600">
            Looks like you haven't added any products to your cart yet.
          </p>
        </CardHeader>
        <CardContent>
          <Button onClick={handleStartShopping} className="w-full">
            Start Shopping
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
