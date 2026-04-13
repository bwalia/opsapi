/**
 * Menu Service
 *
 * Handles all menu-related API calls for the backend-driven navigation system.
 * This is the single source of truth for navigation - the frontend should NOT
 * implement any permission filtering logic. All filtering happens on the backend.
 *
 * @module services/menu.service
 */

import apiClient, { toFormData } from '@/lib/api-client';
import type {
  MenuResponse,
  NamespaceMenuConfigResponse,
  MenuConfigUpdate,
  BatchMenuConfigUpdate,
  MenuItem,
} from '@/types';

/**
 * Menu service object containing all menu-related API operations
 */
export const menuService = {
  /**
   * Fetches the user's menu filtered by their permissions in the current namespace.
   * This is the main endpoint that the Sidebar component should use.
   *
   * The API returns only the menu items the user has access to based on:
   * - Their namespace permissions (from assigned roles)
   * - Namespace ownership status
   * - Platform admin status
   * - Namespace-specific menu configuration
   *
   * @returns Promise containing filtered menu items, namespace context, and permissions
   */
  async getUserMenu(): Promise<MenuResponse> {
    const response = await apiClient.get<MenuResponse>('/api/v2/user/menu');
    return response.data;
  },

  /**
   * Fetches the menu configuration for the current namespace.
   * This is used by namespace admins to manage which menus are visible.
   *
   * @returns Promise containing namespace menu configuration
   */
  async getNamespaceMenuConfig(): Promise<NamespaceMenuConfigResponse> {
    const response = await apiClient.get<NamespaceMenuConfigResponse>(
      '/api/v2/namespace/menu-config'
    );
    return response.data;
  },

  /**
   * Updates the menu configuration for a specific menu item in the current namespace.
   *
   * @param menuKey - The key of the menu item to update (e.g., 'dashboard', 'users')
   * @param config - The configuration updates
   * @returns Promise containing update confirmation
   */
  async updateMenuConfig(
    menuKey: string,
    config: MenuConfigUpdate
  ): Promise<{ message: string; config: unknown }> {
    const response = await apiClient.put(
      `/api/v2/namespace/menu-config/${menuKey}`,
      toFormData(config as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Batch updates menu configurations for the current namespace.
   *
   * @param configs - Object mapping menu keys to their configuration updates
   * @returns Promise containing batch update results
   */
  async batchUpdateMenuConfig(
    configs: BatchMenuConfigUpdate
  ): Promise<{ message: string; results: Record<string, unknown> }> {
    const response = await apiClient.put(
      '/api/v2/namespace/menu-config',
      toFormData(configs as unknown as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Enables a menu item for the current namespace.
   *
   * @param menuKey - The key of the menu item to enable
   * @returns Promise containing confirmation
   */
  async enableMenuItem(menuKey: string): Promise<{ message: string }> {
    const response = await apiClient.post(
      `/api/v2/namespace/menu-config/${menuKey}/enable`
    );
    return response.data;
  },

  /**
   * Disables a menu item for the current namespace.
   *
   * @param menuKey - The key of the menu item to disable
   * @returns Promise containing confirmation
   */
  async disableMenuItem(menuKey: string): Promise<{ message: string }> {
    const response = await apiClient.post(
      `/api/v2/namespace/menu-config/${menuKey}/disable`
    );
    return response.data;
  },

  // ============================================
  // Platform Admin Operations (Global Menu Template)
  // ============================================

  /**
   * Fetches all menu items (platform admin only).
   * Used for managing the global menu template.
   *
   * @returns Promise containing all menu items
   */
  async getAllMenuItems(): Promise<{ data: MenuItem[]; total: number }> {
    const response = await apiClient.get<{ data: MenuItem[]; total: number }>(
      '/api/v2/menu/all'
    );
    return response.data;
  },

  /**
   * Creates a new global menu item (platform admin only).
   *
   * @param data - Menu item data
   * @returns Promise containing created menu item
   */
  async createMenuItem(data: Partial<MenuItem>): Promise<{ message: string; item: MenuItem }> {
    const response = await apiClient.post(
      '/api/v2/menu',
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Updates a global menu item (platform admin only).
   *
   * @param id - Menu item ID or UUID
   * @param data - Updated menu item data
   * @returns Promise containing updated menu item
   */
  async updateMenuItem(
    id: string | number,
    data: Partial<MenuItem>
  ): Promise<{ message: string; item: MenuItem }> {
    const response = await apiClient.put(
      `/api/v2/menu/${id}`,
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  /**
   * Deletes a global menu item (platform admin only).
   *
   * @param id - Menu item ID or UUID
   * @returns Promise containing deletion confirmation
   */
  async deleteMenuItem(id: string | number): Promise<{ message: string }> {
    const response = await apiClient.delete(`/api/v2/menu/${id}`);
    return response.data;
  },
};

export default menuService;
