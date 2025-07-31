export interface User {
  id: string;
  email: string;
  name: string;
  role?: string;
}

export interface Store {
  id: string;
  uuid: string;
  name: string;
  description?: string;
  slug: string;
  status: string;
  user_id: string;
  created_at: string;
  updated_at: string;
}

export interface Category {
  id: string;
  uuid: string;
  store_id: string;
  name: string;
  description?: string;
  slug?: string;
  sort_order: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface Product {
  id: string;
  uuid: string;
  store_id: string;
  category_id?: string;
  name: string;
  description?: string;
  sku?: string;
  price: number;
  inventory_quantity: number;
  track_inventory: boolean;
  is_active: boolean;
  is_featured: boolean;
  images?: string[];
  variants?: ProductVariant[];
  created_at: string;
  updated_at: string;
}

export interface ProductVariant {
  id: string;
  uuid: string;
  product_id: string;
  title: string;
  option1?: string;
  option2?: string;
  option3?: string;
  sku?: string;
  price?: number;
  inventory_quantity: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface CartItem {
  product_uuid: string;
  variant_uuid?: string;
  name: string;
  variant_title?: string;
  price: number;
  quantity: number;
}

export interface Order {
  id: string;
  uuid: string;
  store_id: string;
  customer_id?: string;
  order_number: string;
  status: string;
  financial_status: string;
  fulfillment_status: string;
  subtotal: number;
  tax_amount: number;
  shipping_amount: number;
  total_amount: number;
  billing_address?: any;
  shipping_address?: any;
  customer_notes?: string;
  created_at: string;
  updated_at: string;
}

export interface Customer {
  id: string;
  uuid: string;
  email: string;
  first_name?: string;
  last_name?: string;
  phone?: string;
  addresses?: any[];
  created_at: string;
  updated_at: string;
}

export interface ProductCardProps {
  product: Product & { description?: string };
  onAddToCart?: () => void;
  showVariants?: boolean;
}