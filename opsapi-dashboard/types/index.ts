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

export interface LoginNamespace {
  id: number;
  uuid: string;
  name: string;
  slug: string;
  is_owner?: boolean;
  role?: string;
  permissions?: NamespacePermissions;
}

export interface LoginResponse {
  token: string;
  user: User;
  message?: string;
  namespaces?: Array<{
    id: number;
    uuid: string;
    name: string;
    slug: string;
    is_owner?: boolean;
    status?: string;
    member_status?: string;
  }>;
  current_namespace?: LoginNamespace;
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
  | 'namespaces'
  | 'services';

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

export type CustomerState = 'enabled' | 'disabled' | 'invited' | 'declined';
export type MarketingOptInLevel = 'single_opt_in' | 'confirmed_opt_in' | 'unknown';

export interface CustomerAddress {
  id?: string;
  address1?: string;
  address2?: string;
  city?: string;
  province?: string;
  country?: string;
  zip?: string;
  phone?: string;
  name?: string;
  company?: string;
  country_code?: string;
  province_code?: string;
  is_default?: boolean;
}

export interface Customer {
  id: number;
  uuid: string;
  email: string;
  first_name?: string;
  last_name?: string;
  phone?: string;
  date_of_birth?: string;
  addresses: CustomerAddress[] | string; // JSON array stored as text
  notes?: string;
  tags?: string;
  accepts_marketing: boolean;
  namespace_id?: number;
  marketing_opt_in_level: MarketingOptInLevel;
  last_order_date?: string;
  orders_count: number;
  total_spent: number;
  average_order_value: number;
  verified_email: boolean;
  tax_exempt: boolean;
  state: CustomerState;
  user_id?: number;
  stripe_customer_id?: string;
  created_at: string;
  updated_at: string;
}

export interface CreateCustomerDto {
  email: string;
  first_name?: string;
  last_name?: string;
  phone?: string;
  date_of_birth?: string;
  addresses?: CustomerAddress[];
  notes?: string;
  tags?: string;
  accepts_marketing?: boolean;
  marketing_opt_in_level?: MarketingOptInLevel;
  verified_email?: boolean;
  tax_exempt?: boolean;
  state?: CustomerState;
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
  | 'reports'
  | 'services'
  | 'projects';

export type NamespacePermissions = Partial<Record<NamespaceModule, PermissionAction[]>>;

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

// ============================================
// Services Module Types (GitHub Workflow Integration)
// ============================================

export interface NamespaceService {
  id: number;
  uuid: string;
  namespace_id: number;
  name: string;
  description?: string;
  icon?: string;
  color?: string;
  github_owner: string;
  github_repo: string;
  github_workflow_file: string;
  github_branch: string;
  github_integration_id?: number;
  status: 'active' | 'inactive' | 'archived';
  last_deployment_at?: string;
  last_deployment_status?: string;
  deployment_count: number;
  success_count: number;
  failure_count: number;
  created_by?: number;
  updated_by?: number;
  created_at: string;
  updated_at: string;
  // Populated fields
  secrets_count?: number;
  variables_count?: number;
  github_integration_name?: string;
  secrets?: ServiceSecret[];
  variables?: ServiceVariable[];
  deployments?: ServiceDeployment[];
  github_integration?: GithubIntegration;
}

export interface ServiceSecret {
  id: number;
  uuid: string;
  service_id: number;
  key: string;
  value: string; // Always "********" from API
  description?: string;
  is_required: boolean;
  created_by?: number;
  updated_by?: number;
  created_at: string;
  updated_at: string;
}

export interface ServiceVariable {
  id: number;
  uuid: string;
  service_id: number;
  key: string;
  value: string;
  description?: string;
  is_required: boolean;
  default_value?: string;
  created_at: string;
  updated_at: string;
}

export interface ServiceDeployment {
  id: number;
  uuid: string;
  service_id: number;
  triggered_by?: number;
  github_run_id?: number;
  github_run_url?: string;
  github_run_number?: number;
  status: 'pending' | 'triggered' | 'running' | 'success' | 'failure' | 'cancelled' | 'error';
  inputs?: string; // JSON string of non-secret inputs
  started_at?: string;
  completed_at?: string;
  error_message?: string;
  error_details?: string;
  created_at: string;
  updated_at: string;
  // Populated fields
  first_name?: string;
  last_name?: string;
  triggered_by_email?: string;
  service_name?: string;
  github_owner?: string;
  github_repo?: string;
  github_workflow_file?: string;
}

export interface GithubIntegration {
  id: number;
  uuid: string;
  namespace_id: number;
  name: string;
  github_token: string; // Always "********" from API
  github_username?: string;
  status: 'active' | 'inactive';
  last_validated_at?: string;
  created_by?: number;
  created_at: string;
  updated_at: string;
}

export interface ServiceStats {
  total_services: number;
  total_all_services: number;
  total_deployments: number;
  total_successes: number;
  total_failures: number;
  active_integrations: number;
}

// DTOs
export interface CreateServiceDto {
  name: string;
  description?: string;
  icon?: string;
  color?: string;
  github_owner: string;
  github_repo: string;
  github_workflow_file: string;
  github_branch?: string;
  github_integration_id?: number;
  status?: 'active' | 'inactive';
}

export interface UpdateServiceDto {
  name?: string;
  description?: string;
  icon?: string;
  color?: string;
  github_owner?: string;
  github_repo?: string;
  github_workflow_file?: string;
  github_branch?: string;
  github_integration_id?: number;
  status?: 'active' | 'inactive' | 'archived';
}

export interface CreateSecretDto {
  key: string;
  value: string;
  description?: string;
  is_required?: boolean;
}

export interface UpdateSecretDto {
  key?: string;
  value?: string; // Send actual value to update, or "********" to keep existing
  description?: string;
  is_required?: boolean;
}

export interface CreateVariableDto {
  key: string;
  value: string;
  description?: string;
  is_required?: boolean;
  default_value?: string;
}

export interface UpdateVariableDto {
  key?: string;
  value?: string;
  description?: string;
  is_required?: boolean;
  default_value?: string;
}

export interface CreateGithubIntegrationDto {
  name?: string;
  github_token: string;
  github_username?: string;
}

export interface UpdateGithubIntegrationDto {
  name?: string;
  github_token?: string; // Send actual value to update, or "********" to keep existing
  github_username?: string;
  status?: 'active' | 'inactive';
}

export interface TriggerDeploymentDto {
  inputs?: Record<string, string>; // Custom inputs to override defaults
}

export interface DeploymentResponse {
  data: ServiceDeployment;
  message: string;
  error?: string;
}

// ============================================
// Kanban Project Management Types
// ============================================

export type KanbanProjectStatus = 'active' | 'on_hold' | 'completed' | 'archived' | 'cancelled';
export type KanbanProjectVisibility = 'public' | 'private' | 'internal';
export type KanbanTaskStatus = 'open' | 'in_progress' | 'blocked' | 'review' | 'completed' | 'cancelled';
export type KanbanTaskPriority = 'critical' | 'high' | 'medium' | 'low' | 'none';
export type KanbanMemberRole = 'owner' | 'admin' | 'member' | 'viewer' | 'guest';
export type KanbanSprintStatus = 'planned' | 'active' | 'completed' | 'cancelled';
export type BudgetCurrency = 'USD' | 'EUR' | 'GBP' | 'INR' | 'CAD' | 'AUD' | 'JPY' | 'CNY';

export interface KanbanProject {
  id: number;
  uuid: string;
  namespace_id: number;
  name: string;
  slug: string;
  description?: string;
  status: KanbanProjectStatus;
  visibility: KanbanProjectVisibility;
  color?: string;
  icon?: string;
  cover_image_url?: string;
  // Budget tracking
  budget: number;
  budget_spent: number;
  budget_currency: BudgetCurrency;
  hourly_rate?: number;
  // Dates
  start_date?: string;
  due_date?: string;
  completed_at?: string;
  // Ownership
  owner_user_uuid: string;
  chat_channel_uuid?: string;
  // Settings
  settings?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  // Counts
  task_count: number;
  completed_task_count: number;
  member_count: number;
  board_count: number;
  // User-specific flags (populated based on current user)
  is_starred?: boolean;
  current_user_role?: KanbanMemberRole;
  // Timestamps
  created_at: string;
  updated_at: string;
  archived_at?: string;
  deleted_at?: string;
  // Populated fields
  owner?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
  };
  boards?: KanbanBoard[];
  members?: KanbanProjectMember[];
  labels?: KanbanLabel[];
}

export interface KanbanProjectMember {
  id: number;
  uuid: string;
  project_id: number;
  user_uuid: string;
  role: KanbanMemberRole;
  permissions?: Record<string, unknown>;
  joined_at: string;
  invited_by?: string;
  is_starred: boolean;
  notification_preference: 'all' | 'mentions' | 'none';
  last_accessed_at?: string;
  created_at: string;
  updated_at: string;
  left_at?: string;
  deleted_at?: string;
  // Populated fields
  user?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
    avatar_url?: string;
  };
}

export interface KanbanBoard {
  id: number;
  uuid: string;
  project_id: number;
  name: string;
  description?: string;
  position: number;
  is_default: boolean;
  settings?: Record<string, unknown>;
  wip_limit?: number;
  column_count: number;
  task_count: number;
  created_by: string;
  created_at: string;
  updated_at: string;
  archived_at?: string;
  deleted_at?: string;
  // Populated fields
  columns?: KanbanColumn[];
  project?: KanbanProject;
}

export interface KanbanColumn {
  id: number;
  uuid: string;
  board_id: number;
  name: string;
  description?: string;
  position: number;
  color?: string;
  wip_limit?: number;
  is_done_column: boolean;
  auto_close_tasks: boolean;
  task_count: number;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
  // Populated fields
  tasks?: KanbanTask[];
}

export interface KanbanTask {
  id: number;
  uuid: string;
  board_id: number;
  column_id: number;
  parent_task_id?: number;
  sprint_id?: number;
  task_number: number;
  title: string;
  description?: string;
  status: KanbanTaskStatus;
  priority: KanbanTaskPriority;
  position: number;
  // Effort tracking
  story_points?: number;
  time_estimate_minutes?: number;
  time_spent_minutes: number;
  // Budget
  budget?: number;
  budget_spent: number;
  // Dates
  start_date?: string;
  due_date?: string;
  completed_at?: string;
  // Ownership
  reporter_user_uuid: string;
  chat_channel_uuid?: string;
  // Display
  cover_image_url?: string;
  cover_color?: string;
  // Metadata
  metadata?: Record<string, unknown>;
  // Counts
  comment_count: number;
  attachment_count: number;
  subtask_count: number;
  completed_subtask_count: number;
  assignee_count: number;
  // Timestamps
  created_at: string;
  updated_at: string;
  archived_at?: string;
  deleted_at?: string;
  // Populated fields
  assignees?: KanbanTaskAssignee[];
  labels?: KanbanLabel[];
  checklists?: KanbanChecklist[];
  comments?: KanbanComment[];
  attachments?: KanbanAttachment[];
  reporter?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
    avatar_url?: string;
  };
  parent_task?: KanbanTask;
  subtasks?: KanbanTask[];
}

export interface KanbanTaskAssignee {
  id: number;
  uuid: string;
  task_id: number;
  user_uuid: string;
  assigned_by: string;
  assigned_at: string;
  created_at: string;
  deleted_at?: string;
  // Populated fields
  user?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
    avatar_url?: string;
  };
}

export interface KanbanLabel {
  id: number;
  uuid: string;
  project_id: number;
  name: string;
  color: string;
  description?: string;
  usage_count: number;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
}

export interface KanbanComment {
  id: number;
  uuid: string;
  task_id: number;
  parent_comment_id?: number;
  user_uuid: string;
  content: string;
  is_edited: boolean;
  edited_at?: string;
  reaction_count: number;
  reply_count: number;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
  // Populated fields
  user?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
    avatar_url?: string;
  };
  replies?: KanbanComment[];
}

export interface KanbanAttachment {
  id: number;
  uuid: string;
  task_id: number;
  uploaded_by: string;
  file_name: string;
  file_url: string;
  file_type?: string;
  file_size?: number;
  thumbnail_url?: string;
  metadata?: Record<string, unknown>;
  created_at: string;
  deleted_at?: string;
  // Populated fields
  uploader?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
  };
}

export interface KanbanChecklist {
  id: number;
  uuid: string;
  task_id: number;
  name: string;
  position: number;
  item_count: number;
  completed_item_count: number;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
  // Populated fields
  items?: KanbanChecklistItem[];
}

export interface KanbanChecklistItem {
  id: number;
  uuid: string;
  checklist_id: number;
  content: string;
  is_completed: boolean;
  completed_at?: string;
  completed_by?: string;
  assignee_user_uuid?: string;
  due_date?: string;
  position: number;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
  // Populated fields
  assignee?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
  };
}

export interface KanbanSprint {
  id: number;
  uuid: string;
  project_id: number;
  board_id?: number;
  name: string;
  goal?: string;
  status: KanbanSprintStatus;
  start_date?: string;
  end_date?: string;
  completed_at?: string;
  total_points: number;
  completed_points: number;
  task_count: number;
  completed_task_count: number;
  created_by: string;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
}

export interface KanbanActivity {
  id: number;
  uuid: string;
  task_id: number;
  user_uuid: string;
  action: string;
  entity_type?: string;
  entity_id?: number;
  old_value?: string;
  new_value?: string;
  metadata?: Record<string, unknown>;
  created_at: string;
  // Populated fields
  user?: {
    uuid: string;
    first_name: string;
    last_name: string;
    email: string;
    avatar_url?: string;
  };
}

// Kanban API DTOs
export interface CreateKanbanProjectDto {
  name: string;
  slug?: string;
  description?: string;
  status?: KanbanProjectStatus;
  visibility?: KanbanProjectVisibility;
  color?: string;
  icon?: string;
  cover_image_url?: string;
  budget?: number;
  budget_currency?: BudgetCurrency;
  hourly_rate?: number;
  start_date?: string;
  due_date?: string;
  settings?: Record<string, unknown>;
}

export interface UpdateKanbanProjectDto extends Partial<CreateKanbanProjectDto> {
  archived_at?: string | null;
}

export interface CreateKanbanBoardDto {
  name: string;
  description?: string;
  position?: number;
  is_default?: boolean;
  settings?: Record<string, unknown>;
  wip_limit?: number;
}

export interface UpdateKanbanBoardDto extends Partial<CreateKanbanBoardDto> {
  archived_at?: string | null;
}

export interface CreateKanbanColumnDto {
  name: string;
  description?: string;
  position?: number;
  color?: string;
  wip_limit?: number;
  is_done_column?: boolean;
  auto_close_tasks?: boolean;
}

export interface UpdateKanbanColumnDto extends Partial<CreateKanbanColumnDto> {}

export interface CreateKanbanTaskDto {
  title: string;
  description?: string;
  column_id?: number;
  status?: KanbanTaskStatus;
  priority?: KanbanTaskPriority;
  position?: number;
  story_points?: number;
  time_estimate_minutes?: number;
  budget?: number;
  start_date?: string;
  due_date?: string;
  cover_image_url?: string;
  cover_color?: string;
  parent_task_id?: number;
  sprint_id?: number;
  assignee_uuids?: string[];
  label_ids?: number[];
}

export interface UpdateKanbanTaskDto extends Partial<CreateKanbanTaskDto> {
  time_spent_minutes?: number;
  budget_spent?: number;
  archived_at?: string | null;
}

export interface MoveKanbanTaskDto {
  column_id: number;
  position: number;
}

export interface CreateKanbanLabelDto {
  name: string;
  color?: string;
  description?: string;
}

export interface UpdateKanbanLabelDto extends Partial<CreateKanbanLabelDto> {}

export interface CreateKanbanCommentDto {
  content: string;
  parent_comment_id?: number;
}

export interface UpdateKanbanCommentDto {
  content: string;
}

export interface CreateKanbanChecklistDto {
  name: string;
  position?: number;
}

export interface UpdateKanbanChecklistDto extends Partial<CreateKanbanChecklistDto> {}

export interface CreateKanbanChecklistItemDto {
  content: string;
  position?: number;
  assignee_user_uuid?: string;
  due_date?: string;
}

export interface UpdateKanbanChecklistItemDto extends Partial<CreateKanbanChecklistItemDto> {
  is_completed?: boolean;
}

export interface AddKanbanMemberDto {
  user_uuid: string;
  role?: KanbanMemberRole;
}

export interface UpdateKanbanMemberDto {
  role?: KanbanMemberRole;
  notification_preference?: 'all' | 'mentions' | 'none';
}

export interface ReorderColumnsDto {
  column_ids: number[];
}

export interface ReorderTasksDto {
  task_ids: number[];
}

// Kanban project permissions (returned by API)
export interface KanbanProjectPermissions {
  can_create: boolean;
  can_update: boolean;
  can_delete: boolean;
  can_manage: boolean;
}

// Kanban API Response types
export interface KanbanProjectsResponse {
  data: KanbanProject[];
  total: number;
  page: number;
  per_page: number;
  permissions?: KanbanProjectPermissions;
}

export interface KanbanBoardFullResponse {
  board: KanbanBoard;
  columns: (KanbanColumn & { tasks: KanbanTask[] })[];
  project: KanbanProject;
}

export interface KanbanProjectStats {
  total_tasks: number;
  completed_tasks: number;
  overdue_tasks: number;
  tasks_by_status: Record<KanbanTaskStatus, number>;
  tasks_by_priority: Record<KanbanTaskPriority, number>;
  budget_total: number;
  budget_spent: number;
  time_estimated_minutes: number;
  time_spent_minutes: number;
}

export interface KanbanMyTasksResponse {
  data: KanbanTask[];
  total: number;
  page: number;
  per_page: number;
}

// Drag and Drop types
export interface DragItem {
  type: 'task' | 'column';
  id: number;
  uuid: string;
  columnId?: number;
  position: number;
}

export interface DropResult {
  source: {
    columnId: number;
    position: number;
  };
  destination: {
    columnId: number;
    position: number;
  } | null;
  taskId: number;
}

// ============================================
// Time Tracking Types
// ============================================

export type TimeEntryStatus = 'running' | 'logged' | 'approved' | 'invoiced' | 'rejected';

export interface TimeEntry {
  id: number;
  uuid: string;
  task_id: number;
  user_uuid: string;
  description?: string;
  started_at: string;
  ended_at?: string;
  duration_minutes: number;
  is_billable: boolean;
  hourly_rate?: number;
  billed_amount?: number;
  invoice_id?: string;
  status: TimeEntryStatus;
  approved_by?: string;
  approved_at?: string;
  metadata?: Record<string, unknown>;
  created_at: string;
  updated_at: string;
  deleted_at?: string;
  // Populated fields
  task_uuid?: string;
  task_title?: string;
  task_number?: number;
  board_name?: string;
  project_name?: string;
  project_uuid?: string;
  first_name?: string;
  last_name?: string;
  email?: string;
  elapsed_minutes?: number; // For running timers
}

export interface RunningTimer extends TimeEntry {
  elapsed_minutes: number;
  task_uuid: string;
  task_title: string;
  task_number: number;
  project_name: string;
  project_uuid: string;
}

export interface TimesheetSummary {
  total_minutes: number;
  billable_minutes: number;
  total_billed: number;
  unique_users?: number;
}

export interface TimeReportByUser {
  user_uuid: string;
  first_name: string;
  last_name: string;
  email: string;
  total_minutes: number;
  billable_minutes: number;
  total_billed: number;
  entry_count: number;
}

// Time Tracking DTOs
export interface CreateTimeEntryDto {
  description?: string;
  started_at?: string;
  ended_at?: string;
  duration_minutes?: number;
  is_billable?: boolean;
  hourly_rate?: number;
}

export interface UpdateTimeEntryDto extends Partial<CreateTimeEntryDto> {}

export interface StartTimerDto {
  task_uuid: string;
  description?: string;
}

export interface StopTimerDto {
  description?: string;
}

export interface TimesheetParams {
  page?: number;
  perPage?: number;
  start_date?: string;
  end_date?: string;
  project_id?: number;
  status?: TimeEntryStatus;
}

export interface TimesheetResponse {
  data: TimeEntry[];
  summary: TimesheetSummary;
  meta: {
    total: number;
    page: number;
    perPage: number;
  };
}

export interface TimeReportResponse extends TimesheetResponse {
  user_breakdown?: TimeReportByUser[];
}

// ============================================
// Notification Types
// ============================================

export type NotificationType =
  | 'task_assigned'
  | 'task_unassigned'
  | 'task_commented'
  | 'task_mentioned'
  | 'task_completed'
  | 'task_status_changed'
  | 'task_due_soon'
  | 'task_overdue'
  | 'project_invited'
  | 'project_removed'
  | 'project_role_changed'
  | 'sprint_started'
  | 'sprint_ended'
  | 'checklist_completed'
  | 'comment_reply'
  | 'comment_mentioned'
  | 'general';

export type NotificationPriority = 'low' | 'normal' | 'high' | 'urgent';
export type DigestFrequency = 'instant' | 'hourly' | 'daily' | 'weekly';

export interface KanbanNotification {
  id: number;
  uuid: string;
  namespace_id: number;
  recipient_user_uuid: string;
  type: NotificationType;
  title: string;
  message: string;
  action_url?: string;
  project_id?: number;
  task_id?: number;
  comment_id?: number;
  actor_user_uuid?: string;
  is_read: boolean;
  read_at?: string;
  is_email_sent: boolean;
  email_sent_at?: string;
  is_push_sent: boolean;
  push_sent_at?: string;
  priority: NotificationPriority;
  group_key?: string;
  metadata?: Record<string, unknown>;
  created_at: string;
  expires_at?: string;
  deleted_at?: string;
  // Populated fields
  project_name?: string;
  project_uuid?: string;
  task_title?: string;
  task_number?: number;
  task_uuid?: string;
  actor_first_name?: string;
  actor_last_name?: string;
}

export interface NotificationPreferences {
  id?: number;
  user_uuid?: string;
  project_id?: number;
  email_enabled: boolean;
  push_enabled: boolean;
  in_app_enabled: boolean;
  digest_frequency: DigestFrequency;
  digest_hour: number;
  digest_day: number;
  quiet_hours_enabled: boolean;
  quiet_hours_start?: number;
  quiet_hours_end?: number;
  timezone: string;
  preferences: Record<NotificationType, boolean>;
  created_at?: string;
  updated_at?: string;
}

export interface NotificationsResponse {
  data: KanbanNotification[];
  meta: {
    total: number;
    unread_count: number;
    page: number;
    perPage: number;
  };
}

export interface UpdateNotificationPreferencesDto {
  email_enabled?: boolean;
  push_enabled?: boolean;
  in_app_enabled?: boolean;
  digest_frequency?: DigestFrequency;
  digest_hour?: number;
  digest_day?: number;
  quiet_hours_enabled?: boolean;
  quiet_hours_start?: number;
  quiet_hours_end?: number;
  timezone?: string;
  preferences?: Record<NotificationType, boolean>;
}

// ============================================
// Sprint Enhancement Types
// ============================================

export interface SprintBurndownPoint {
  id: number;
  sprint_id: number;
  recorded_date: string;
  total_points: number;
  completed_points: number;
  remaining_points: number;
  total_tasks: number;
  completed_tasks: number;
  remaining_tasks: number;
  added_points: number;
  removed_points: number;
  ideal_remaining: number;
  created_at: string;
}

export interface SprintRetrospective {
  what_went_well?: string[];
  what_to_improve?: string[];
  action_items?: string[];
  notes?: string;
}

export interface KanbanSprintEnhanced extends KanbanSprint {
  velocity?: number;
  retrospective?: SprintRetrospective;
  review_notes?: string;
  // Enhanced stats from API
  completed_count?: number;
  // Board info
  board_name?: string;
  board_uuid?: string;
  project_name?: string;
  project_uuid?: string;
}

export interface SprintBurndownResponse {
  sprint: {
    uuid: string;
    name: string;
    start_date?: string;
    end_date?: string;
    total_points: number;
    completed_points: number;
  };
  data_points: SprintBurndownPoint[];
}

export interface VelocityHistoryItem {
  uuid: string;
  name: string;
  start_date?: string;
  end_date?: string;
  velocity?: number;
  total_points: number;
  completed_points: number;
  task_count: number;
  completed_task_count?: number;
  status: KanbanSprintStatus;
}

export interface VelocityHistory {
  sprints: VelocityHistoryItem[];
  average_velocity: number;
  sprint_count: number;
}

// Sprint DTOs
export interface CreateSprintDto {
  name: string;
  goal?: string;
  board_id?: number;
  start_date?: string;
  end_date?: string;
}

export interface UpdateSprintDto extends Partial<CreateSprintDto> {
  retrospective?: SprintRetrospective;
  review_notes?: string;
}

export interface CompleteSprintDto {
  retrospective?: SprintRetrospective;
}

export interface AddTasksToSprintDto {
  task_ids: number[];
}

// ============================================
// Analytics Types
// ============================================

export interface ProjectAnalyticsStats {
  tasks: {
    total_tasks: number;
    open_tasks: number;
    in_progress_tasks: number;
    blocked_tasks: number;
    review_tasks: number;
    completed_tasks: number;
    cancelled_tasks: number;
    overdue_tasks: number;
    due_today_tasks: number;
    total_points: number;
    completed_points: number;
  };
  members: {
    member_count: number;
  };
  boards: {
    board_count: number;
  };
  sprints: {
    total_sprints: number;
    active_sprints: number;
    completed_sprints: number;
    avg_velocity?: number;
  };
  time: {
    total_minutes: number;
    billable_minutes: number;
    total_billed: number;
  };
  budget: {
    budget: number;
    budget_spent: number;
    budget_currency: BudgetCurrency;
  };
  progress_percentage: number;
}

export interface CompletionTrendPoint {
  date: string;
  completed_count: number;
  completed_points: number;
  created_count: number;
}

export interface CompletionTrendResponse {
  days: number;
  trend: CompletionTrendPoint[];
}

export interface PriorityDistribution {
  priority: KanbanTaskPriority;
  count: number;
  active_count: number;
}

export interface TeamWorkloadMember {
  user_uuid: string;
  first_name: string;
  last_name: string;
  email: string;
  role: KanbanMemberRole;
  assigned_tasks: number;
  active_tasks: number;
  completed_tasks: number;
  in_progress_tasks: number;
  overdue_tasks: number;
  total_points: number;
  completed_points: number;
}

export interface MemberActivityPoint {
  date: string;
  activity_count: number;
  completed_count: number;
  comment_count: number;
  time_spent_minutes: number;
}

export interface MemberActivityResponse {
  user_uuid: string;
  days: number;
  activity: MemberActivityPoint[];
}

export interface CycleTimeByColumn {
  column_name: string;
  column_color?: string;
  position: number;
  avg_hours_to_complete: number;
  avg_time_minutes: number;
  task_count: number;
}

export interface CycleTimeByPriority {
  priority: KanbanTaskPriority;
  avg_hours: number;
  min_hours: number;
  max_hours: number;
  task_count: number;
}

export interface CycleTimeResponse {
  by_column: CycleTimeByColumn[];
  by_priority: CycleTimeByPriority[];
}

export interface ProjectActivity {
  id: number;
  uuid: string;
  task_id: number;
  user_uuid: string;
  action: string;
  entity_type?: string;
  entity_id?: number;
  old_value?: string;
  new_value?: string;
  metadata?: Record<string, unknown>;
  created_at: string;
  task_uuid: string;
  task_title: string;
  task_number: number;
  board_uuid: string;
  board_name: string;
  first_name: string;
  last_name: string;
  email: string;
}

export interface ActivityFeedResponse {
  data: ProjectActivity[];
  meta: {
    total: number;
    page: number;
    perPage: number;
  };
}

export interface ActivitySummary {
  by_action: Array<{
    action: string;
    count: number;
  }>;
  active_users: Array<{
    user_uuid: string;
    first_name: string;
    last_name: string;
    activity_count: number;
  }>;
  total_activities: number;
  hours: number;
}

export interface LabelStats {
  uuid: string;
  name: string;
  color: string;
  usage_count: number;
  active_task_count: number;
  open_task_count: number;
}

// ============================================
// WebSocket Event Types
// ============================================

export type WebSocketEventType =
  | 'notification:new'
  | 'notification:read'
  | 'notification:count_updated'
  | 'task:updated'
  | 'task:created'
  | 'task:deleted'
  | 'task:moved'
  | 'comment:new'
  | 'timer:started'
  | 'timer:stopped'
  | 'sprint:started'
  | 'sprint:completed'
  | 'project:updated'
  | 'member:joined'
  | 'member:left'
  | 'ping'
  | 'pong';

export interface WebSocketMessage<T = unknown> {
  type: WebSocketEventType | string;
  data?: T;
  payload?: T;
  timestamp?: string;
  namespace_id?: number;
  project_id?: number;
  user_uuid?: string;
}

export interface NotificationNewEvent {
  notification: KanbanNotification;
}

export interface NotificationCountEvent {
  unread_count: number;
}

export interface TaskUpdateEvent {
  task: KanbanTask;
  action: 'created' | 'updated' | 'deleted' | 'moved';
  old_column_id?: number;
  new_column_id?: number;
}

export interface TimerEvent {
  time_entry: TimeEntry;
  task: {
    uuid: string;
    title: string;
    task_number: number;
  };
}

// ============================================
// Menu Types (Backend-Driven Navigation)
// ============================================

/**
 * Menu item returned from the API
 * Represents a navigation item that the user has permission to access
 */
export interface MenuItem {
  key: string;
  name: string;
  icon: string;
  path: string;
  module: NamespaceModule | null;
  priority: number;
  badge_key?: string | null;
  always_show: boolean;
  is_admin_only: boolean;
}

/**
 * Namespace context returned with menu
 */
export interface MenuNamespaceContext {
  id: number;
  uuid: string;
  name: string;
  slug: string;
  is_owner: boolean;
}

/**
 * Response from GET /api/v2/user/menu
 */
export interface MenuResponse {
  menu: MenuItem[];
  main_menu: MenuItem[];
  secondary_menu: MenuItem[];
  namespace: MenuNamespaceContext;
  permissions: NamespacePermissions;
  is_admin: boolean;
}

/**
 * Namespace menu configuration item
 */
export interface NamespaceMenuConfig {
  id: number;
  uuid: string;
  namespace_id: number;
  menu_item_id: number;
  is_enabled: boolean;
  custom_name?: string | null;
  custom_icon?: string | null;
  custom_priority?: number | null;
  settings?: string;
  menu_key?: string;
  default_name?: string;
  default_icon?: string;
  path?: string;
  module?: string;
  default_priority?: number;
  is_admin_only?: boolean;
  always_show?: boolean;
  created_at?: string;
  updated_at?: string;
}

/**
 * Response from GET /api/v2/namespace/menu-config
 */
export interface NamespaceMenuConfigResponse {
  namespace: {
    id: number;
    uuid: string;
    name: string;
  };
  menu_config: NamespaceMenuConfig[];
}

/**
 * Payload for updating menu configuration
 */
export interface MenuConfigUpdate {
  is_enabled?: boolean;
  custom_name?: string | null;
  custom_icon?: string | null;
  custom_priority?: number | null;
  settings?: Record<string, unknown>;
}

/**
 * Batch menu config update payload
 */
export interface BatchMenuConfigUpdate {
  menus: Record<string, MenuConfigUpdate>;
}

/**
 * Menu store state
 */
export interface MenuState {
  menu: MenuItem[];
  mainMenu: MenuItem[];
  secondaryMenu: MenuItem[];
  isLoading: boolean;
  error: string | null;
  lastFetched: number | null;
  namespaceContext: MenuNamespaceContext | null;
  permissions: NamespacePermissions | null;
  isAdmin: boolean;
}
