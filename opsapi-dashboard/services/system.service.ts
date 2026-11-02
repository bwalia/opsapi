import apiClient from '@/lib/api-client';

export interface AppModule {
  machine_name: string;
  name: string;
  description?: string;
  category?: string;
}

/** One feature from helper/project-config.lua, and whether this deployment serves it. */
export interface AppFeature {
  feature: string;
  enabled: boolean;
  plugin: boolean;
  modules: AppModule[];
}

export interface SystemInfo {
  project_code: string;
  enabled_features: string[];
  apps?: AppFeature[];
  environment: string;
  version: string;
}

export const systemService = {
  /** GET /api/v2/system/info: the PROJECT_CODE this API runs with and every feature it knows. */
  async getInfo(): Promise<SystemInfo> {
    const res = await apiClient.get('/api/v2/system/info');
    return res.data as SystemInfo;
  },
  /** GET /api/v2/system/apps (signed in only: it names installed plugins): every feature and its modules. */
  async getApps(): Promise<AppFeature[]> {
    const res = await apiClient.get('/api/v2/system/apps');
    return (res.data?.data ?? []) as AppFeature[];
  },
  /** System info plus the app catalog, for the Apps page. */
  async getInfoWithApps(): Promise<SystemInfo> {
    const [info, apps] = await Promise.all([systemService.getInfo(), systemService.getApps()]);
    return { ...info, apps };
  },
};
