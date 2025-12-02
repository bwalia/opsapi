// ============================================
// Core API Response Types
// ============================================

export interface ApiResponse<T> {
  data: T;
  message?: string;
  error?: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  perPage: number;
  totalPages: number;
}

export interface PaginationParams {
  page?: number;
  perPage?: number;
  orderBy?: string;
  orderDir?: 'asc' | 'desc';
}

// ============================================
// Authentication Types
// ============================================

export interface User {
  id: number;
  uuid: string;
  email: string;
  username: string;
  first_name: string;
  last_name: string;
  phone_no?: string;
  address?: string;
  active: boolean;
  oauth_provider?: string;
  oauth_id?: string;
  created_at: string;
  updated_at: string;
  roles?: Role[];
  // For creation only (not returned from API)
  password?: string;
  role?: string;
}

export interface AuthState {
  user: User | null;
  token: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
}

export interface LoginCredentials {
  username: string;
  password: string;
}

export interface LoginResponse {
  token: string;
  user: User;
  message?: string;
}

// ============================================
// Role & Permission Types
// ============================================

export interface Role {
  id: number | string;
  internal_id?: number;
  uuid: string;
  role_name: string;
  name?: string;
  role_id?: number;
  description?: string;
  created_at: string;
  updated_at: string;
}

export interface UserRole {
  id: number;
  user_id: number;
  role_id: number;
  role_name?: string;
  name?: string;
}

// Module represents a dashboard section/feature
export interface Module {
  id: number;
  uuid: string;
  name: string;
  machine_name: string;
  description?: string;
  icon?: string;
  created_at: string;
  updated_at: string;
}

// Permission actions for each module
export type PermissionAction = 'create' | 'read' | 'update' | 'delete' | 'manage';

export interface Permission {
  id: number;
  uuid: string;
  role: string;
  role_id?: number;
  module_id?: number;
  module_machine_name: string;
  module?: Module;
  permissions: string; // Comma-separated actions: "create,read,update,delete"
  created_at: string;
  updated_at: string;
}

// Dashboard modules for permission management
export type DashboardModule =
  | 'dashboard'
  | 'users'
  | 'roles'
  | 'stores'
  | 'products'
  | 'orders'
  | 'customers'
  | 'settings';

// Permission config for checking access
export interface PermissionConfig {
  module: DashboardModule;
  actions: PermissionAction[];
}

// User permissions map for quick lookups
export type UserPermissions = Record<DashboardModule, PermissionAction[]>;

// ============================================
// Store Types
// ============================================

export interface Store {
  id: number;
  uuid: string;
  name: string;
  description?: string;
  address?: string;
  city?: string;
  state?: string;
  country?: string;
  postal_code?: string;
  phone?: string;
  email?: string;
  logo_url?: string;
  banner_url?: string;
  is_active: boolean;
  user_id?: number;
  uuid_business_id?: string;
  created_at: string;
  updated_at: string;
}

// ============================================
// Product Types
// ============================================

export interface Product {
  id: number;
  uuid: string;
  name: string;
  description?: string;
  price: string;
  SKU: string;
  quantity_in_stock: string;
  manufacturer?: string;
  status: string;
  created_at: string;
  updated_at: string;
}

export interface StoreProduct {
  id: number;
  uuid: string;
  store_uuid: string;
  name: string;
  description?: string;
  price: number;
  compare_at_price?: number;
  cost_per_item?: number;
  sku?: string;
  barcode?: string;
  quantity: number;
  track_quantity: boolean;
  continue_selling_when_out_of_stock: boolean;
  category_uuid?: string;
  status: 'active' | 'draft' | 'archived';
  vendor?: string;
  tags?: string;
  weight?: number;
  weight_unit?: string;
  images?: string;
  thumbnail_url?: string;
  created_at: string;
  updated_at: string;
}

export interface Category {
  id: number;
  uuid: string;
  name: string;
  description?: string;
  parent_uuid?: string;
  image_url?: string;
  is_active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

// ============================================
// Order Types
// ============================================

export type OrderStatus =
  | 'pending'
  | 'confirmed'
  | 'processing'
  | 'ready_for_pickup'
  | 'out_for_delivery'
  | 'delivered'
  | 'cancelled'
  | 'refunded';

export type PaymentStatus = 'pending' | 'paid' | 'failed' | 'refunded';

export interface Order {
  id: number;
  uuid: string;
  customer_uuid: string;
  store_uuid: string;
  order_number?: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
  payment_method?: string;
  subtotal: number;
  tax_amount?: number;
  shipping_amount?: number;
  discount_amount?: number;
  total: number;
  currency: string;
  shipping_address?: string;
  billing_address?: string;
  notes?: string;
  created_at: string;
  updated_at: string;
  customer?: Customer;
  store?: Store;
  items?: OrderItem[];
}

export interface OrderItem {
  id: number;
  uuid: string;
  order_uuid: string;
  product_uuid: string;
  quantity: number;
  unit_price: number;
  total_price: number;
  product_name?: string;
  product_sku?: string;
  created_at: string;
  updated_at: string;
}

// ============================================
// Customer Types
// ============================================

export interface Customer {
  id: number;
  uuid: string;
  first_name: string;
  last_name: string;
  email: string;
  phone?: string;
  address?: string;
  city?: string;
  state?: string;
  country?: string;
  postal_code?: string;
  notes?: string;
  store_uuid?: string;
  user_id?: number;
  created_at: string;
  updated_at: string;
}

// ============================================
// Dashboard Stats Types
// ============================================

export interface DashboardStats {
  totalUsers: number;
  totalOrders: number;
  totalProducts: number;
  totalStores: number;
  totalRevenue: number;
  recentOrders: Order[];
  ordersByStatus: { status: string; count: number }[];
  revenueByMonth: { month: string; revenue: number }[];
}

// ============================================
// Health Check Types
// ============================================

export interface HealthCheckDetails {
  connected?: boolean;
  server_time?: string;
  test_query?: string;
  total_stores?: number;
  total_orders?: number;
  total_users?: number;
  database_size_bytes?: number;
  memory_usage_kb?: number;
  memory_usage_mb?: number;
  uptime_seconds?: number;
  worker_pid?: number;
  worker_count?: number;
  migrations_applied?: number;
  migrations_table_exists?: boolean;
  writable?: boolean;
  readable?: boolean;
  test_passed?: boolean;
}

export interface HealthCheck {
  name: string;
  status: 'healthy' | 'degraded' | 'unhealthy';
  response_time_ms?: number;
  details?: HealthCheckDetails;
  error?: string;
}

export interface HealthStatus {
  status: 'healthy' | 'degraded' | 'unhealthy';
  timestamp: number;
  timestamp_iso?: string;
  version?: string;
  environment?: string;
  total_checks?: number;
  unhealthy_checks?: number;
  degraded_checks?: number;
  total_response_time_ms?: number;
  checks?: HealthCheck[];
}

// ============================================
// Table & UI Types
// ============================================

export interface TableColumn<T> {
  key: keyof T | string;
  header: string;
  sortable?: boolean;
  render?: (item: T) => React.ReactNode;
  width?: string;
}

export interface SelectOption {
  value: string;
  label: string;
}

export interface ModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
}

export interface ConfirmDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: () => void;
  title: string;
  message: string;
  confirmText?: string;
  cancelText?: string;
  variant?: 'danger' | 'warning' | 'info';
  isLoading?: boolean;
}
