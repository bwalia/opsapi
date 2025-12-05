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
  | 'settings'
  | 'namespaces';

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

// Seller information for admin view
export interface OrderSeller {
  uuid: string;
  first_name?: string;
  last_name?: string;
  email?: string;
  full_name?: string;
}

export interface Order {
  id: number;
  uuid: string;
  customer_uuid: string;
  store_uuid: string;
  order_number?: string;
  status: OrderStatus;
  payment_status: PaymentStatus;
  fulfillment_status?: string;
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
  seller?: OrderSeller; // Only populated for admin users
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

// ============================================
// Namespace Types (Multi-tenant)
// ============================================

export type NamespaceStatus = 'active' | 'suspended' | 'pending' | 'archived';
export type NamespacePlan = 'free' | 'starter' | 'professional' | 'enterprise';
export type NamespaceMemberStatus = 'active' | 'invited' | 'suspended' | 'removed';

export interface Namespace {
  id: number;
  uuid: string;
  name: string;
  slug: string;
  description?: string;
  domain?: string;
  logo_url?: string;
  banner_url?: string;
  status: NamespaceStatus;
  plan: NamespacePlan;
  settings?: Record<string, unknown>;
  max_users: number;
  max_stores: number;
  owner_user_id?: number;
  created_at: string;
  updated_at: string;
  // Aggregated fields
  member_count?: number;
  store_count?: number;
}

export interface NamespaceWithMembership extends Namespace {
  is_owner: boolean;
  member_status: NamespaceMemberStatus;
  joined_at?: string;
  roles?: NamespaceRole[];
}

export interface NamespaceMember {
  id: number;
  uuid: string;
  namespace_id: number;
  user_id: number;
  status: NamespaceMemberStatus;
  is_owner: boolean;
  joined_at?: string;
  invited_by?: number;
  created_at: string;
  updated_at: string;
  // Joined fields
  user?: {
    uuid: string;
    email: string;
    first_name: string;
    last_name: string;
    username?: string;
    full_name?: string;
    active: boolean;
  };
  roles?: NamespaceRole[];
  invited_by_name?: string;
}

export interface NamespaceRole {
  id: number;
  uuid: string;
  namespace_id: number;
  role_name: string;
  display_name: string;
  description?: string;
  permissions: string | NamespacePermissions;
  permissions_parsed?: NamespacePermissions;
  is_system: boolean;
  is_default: boolean;
  priority: number;
  created_at: string;
  updated_at: string;
  member_count?: number;
}

// Namespace-scoped permissions
export type NamespaceModule =
  | 'dashboard'
  | 'users'
  | 'roles'
  | 'stores'
  | 'products'
  | 'orders'
  | 'customers'
  | 'settings'
  | 'namespace'
  | 'chat'
  | 'delivery'
  | 'reports';

export type NamespacePermissions = Record<NamespaceModule, PermissionAction[]>;

export interface NamespaceInvitation {
  id: number;
  uuid: string;
  namespace_id?: number;
  email: string;
  role_id?: number;
  invited_by?: number;
  status: 'pending' | 'accepted' | 'declined' | 'expired';
  token: string;
  message?: string;
  expires_at: string;
  accepted_at?: string;
  created_at: string;
  updated_at?: string;
  namespace?: Namespace;
  role?: NamespaceRole;
  inviter?: {
    uuid?: string;
    first_name?: string;
    last_name?: string;
    email?: string;
    name?: string; // Combined name from some API responses
  };
}

// API Response types for namespace
export interface NamespaceLoginResponse extends LoginResponse {
  namespaces: NamespaceWithMembership[];
  current_namespace?: {
    id: number;
    uuid: string;
    name: string;
    slug: string;
    is_owner: boolean;
  };
}

export interface NamespaceSwitchResponse {
  token: string;
  namespace: Namespace;
  membership: NamespaceMember;
  permissions: NamespacePermissions;
}

export interface NamespaceStats {
  total_members: number;
  total_stores: number;
  total_orders: number;
  total_customers: number;
  total_products: number;
  total_revenue: number;
}

// Create/Update DTOs
export interface CreateNamespaceDto {
  name: string;
  slug?: string;
  description?: string;
  domain?: string;
  logo_url?: string;
  banner_url?: string;
  plan?: NamespacePlan;
  settings?: Record<string, unknown>;
  max_users?: number;
  max_stores?: number;
}

export interface UpdateNamespaceDto extends Partial<CreateNamespaceDto> {
  status?: NamespaceStatus;
}

export interface InviteMemberDto {
  email: string;
  role_id?: number;
  message?: string;
}

export interface CreateNamespaceRoleDto {
  role_name: string;
  display_name?: string;
  description?: string;
  permissions?: NamespacePermissions;
  is_default?: boolean;
  priority?: number;
}

export interface UpdateNamespaceRoleDto extends Partial<CreateNamespaceRoleDto> {}

// Module metadata for UI
export interface NamespaceModuleMeta {
  name: NamespaceModule;
  display_name: string;
  description: string;
}

export interface NamespaceActionMeta {
  name: PermissionAction;
  display_name: string;
  description: string;
}

// ============================================
// User Namespace Settings (User-First Architecture)
// Users are GLOBAL, namespaces are assigned to users
// ============================================

export interface UserNamespaceSettings {
  id: number;
  user_id: number;
  default_namespace_id?: number;
  default_namespace_uuid?: string;
  default_namespace_name?: string;
  default_namespace_slug?: string;
  last_active_namespace_id?: number;
  last_active_namespace_uuid?: string;
  last_active_namespace_name?: string;
  last_active_namespace_slug?: string;
  created_at: string;
  updated_at: string;
}

export interface UserNamespacesResponse {
  data: NamespaceWithMembership[];
  total: number;
  settings?: {
    default_namespace_id?: number;
    default_namespace_uuid?: string;
    default_namespace_slug?: string;
    last_active_namespace_id?: number;
    last_active_namespace_uuid?: string;
    last_active_namespace_slug?: string;
  };
}

export interface UpdateUserNamespaceSettingsDto {
  default_namespace_id?: number | string;
}

export interface CreateNamespaceResponse {
  message: string;
  namespace: Namespace;
  membership: NamespaceMember;
  token: string;
}
