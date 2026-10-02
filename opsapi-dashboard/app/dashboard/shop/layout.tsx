import { ShopNav } from '@/components/shop/ShopNav';

export default function ShopLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="space-y-6">
      <ShopNav />
      {children}
    </div>
  );
}
