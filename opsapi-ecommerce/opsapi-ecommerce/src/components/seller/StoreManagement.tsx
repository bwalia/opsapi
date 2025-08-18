import React from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";

interface Store {
  uuid: string;
  name: string;
  description?: string;
  slug: string;
  created_at?: string;
}

interface StoreManagementProps {
  stores: Store[];
  onStoreSelect?: (store: Store) => void;
}

export default function StoreManagement({
  stores,
  onStoreSelect,
}: StoreManagementProps) {
  const router = useRouter();

  const handleCreateStore = () => {
    router.push("/seller/stores/new");
  };

  const handleEditStore = (store: Store) => {
    router.push(`/seller/stores/${store.uuid}`);
  };

  const handleManageStore = (store: Store) => {
    if (onStoreSelect) {
      onStoreSelect(store);
    } else {
      router.push(`/seller/stores/${store.uuid}/dashboard`);
    }
  };

  if (stores.length === 0) {
    return (
      <Card className="text-center py-12">
        <CardContent>
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
                d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"
              />
            </svg>
          </div>
          <h3 className="text-lg font-semibold text-gray-900 mb-2">
            No Stores Yet
          </h3>
          <p className="text-gray-600 mb-6">
            Create your first store to start selling products
          </p>
          <Button onClick={handleCreateStore}>Create Your First Store</Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex justify-between items-center">
        <h2 className="text-xl font-semibold text-gray-900">Your Stores</h2>
        <Button onClick={handleCreateStore}>Create New Store</Button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {stores.map((store) => (
          <Card key={store.uuid} className="hover:shadow-md transition-shadow">
            <CardHeader>
              <CardTitle className="text-lg">{store.name}</CardTitle>
              {store.description && (
                <p className="text-sm text-gray-600 line-clamp-2">
                  {store.description}
                </p>
              )}
            </CardHeader>
            <CardContent>
              <div className="space-y-3">
                <div className="text-sm text-gray-500">
                  <span className="font-medium">Slug:</span> {store.slug}
                </div>
                {store.created_at && (
                  <div className="text-sm text-gray-500">
                    <span className="font-medium">Created:</span>{" "}
                    {new Date(store.created_at).toLocaleDateString()}
                  </div>
                )}

                <div className="flex space-x-2 pt-2">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => handleManageStore(store)}
                    className="flex-1"
                  >
                    Manage
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => handleEditStore(store)}
                  >
                    Edit
                  </Button>
                </div>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
