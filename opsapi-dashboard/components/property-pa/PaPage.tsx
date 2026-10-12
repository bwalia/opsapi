'use client';

/**
 * Wraps every Property PA page, like PdPage does for Property Deals: the plugin must be on in this
 * workspace and the user must hold the page's module (manager pages also need
 * property_pa_knowledge.manage, the backend's "manager"). usePaCan() gates single actions on the
 * permission the route checks.
 */
import React, { useEffect, useState } from 'react';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useNamespaceStore } from '@/store/namespace.store';
import { ErrorNote, PluginOff, Spinner } from '@/components/property-deals/ui';
import { paService } from '@/services/property-pa.service';
import { pdError } from '@/services/property-deals.service';

export const PA_PRODUCT = 'Property PA';
export type PaModule = 'property_pa_records' | 'property_pa_updates' | 'property_pa_knowledge' | 'property_pa_handoffs';
export type PaAction = 'read' | 'create' | 'update' | 'delete' | 'manage';

/** can(module, action) for Property PA modules; isManager = property_pa_knowledge.manage. */
export function usePaCan() {
  const { hasPermission } = usePermissions();
  const can = (module: PaModule, action: PaAction = 'read') => hasPermission(module, action);
  return { can, isManager: can('property_pa_knowledge', 'manage') };
}

// Plugin on/off per workspace, probed at most once a minute.
const offCache: Record<string, { off: boolean; at: number }> = {};
const fresh = (c?: { at: number }) => !!c && Date.now() - c.at < 60_000;

function usePluginOff(): boolean | undefined {
  const ns = useNamespaceStore((s) => s.currentNamespace?.uuid || 'default');
  const [probed, setProbed] = useState<{ ns: string; off: boolean } | null>(null);
  useEffect(() => {
    if (fresh(offCache[ns])) return;
    let live = true;
    // Every PA route answers 404 PLUGIN_DISABLED before it checks the role, so this works for anyone.
    paService.status().then(
      () => false,
      (e) => pdError(e).code === 'PLUGIN_DISABLED',
    ).then((off) => {
      offCache[ns] = { off, at: Date.now() };
      if (live) setProbed({ ns, off });
    });
    return () => { live = false; };
  }, [ns]);
  if (probed?.ns === ns) return probed.off;
  return fresh(offCache[ns]) ? offCache[ns].off : undefined;
}

export default function PaPage({ module = 'property_pa_records', manager = false, children }: {
  module?: PaModule;
  manager?: boolean;
  children: React.ReactNode;
}) {
  const { isLoading } = usePermissions();
  const { can, isManager } = usePaCan();
  const off = usePluginOff();
  if (isLoading || off === undefined) return <Spinner />;
  if (off) return <PluginOff product={PA_PRODUCT} />;
  if (!can(module, 'read') || (manager && !isManager)) {
    return <div className="mt-6"><ErrorNote product={PA_PRODUCT} error={{ status: 403, message: 'No access' }} /></div>;
  }
  return <>{children}</>;
}
