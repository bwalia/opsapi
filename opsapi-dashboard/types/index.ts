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
  | 'reports'
  | 'services';

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

// Kanban API Response types
export interface KanbanProjectsResponse {
  data: KanbanProject[];
  total: number;
  page: number;
  per_page: number;
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
