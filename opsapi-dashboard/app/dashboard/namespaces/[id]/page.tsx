'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { AlertTriangle, Loader2 } from 'lucide-react';
import { Card, Button } from '@/components/ui';
import {
  NamespaceHeader,
  NamespaceStatsCard,
  NamespaceMembersCard,
  NamespaceSettingsCard,
  NamespaceActivityCard,
} from '@/components/namespace';
import { RequireAdmin } from '@/components/permissions/PermissionGate';
import { usePermissions } from '@/contexts/PermissionsContext';
import { namespaceService } from '@/services';
import type { Namespace, NamespaceStats } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';

export default function NamespaceDetailsPage() {
  const params = useParams();
  const router = useRouter();
  const { isAdmin } = usePermissions();

  const namespaceId = params.id as string;

  const [namespace, setNamespace] = useState<Namespace | null>(null);
  const [stats, setStats] = useState<NamespaceStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchNamespace = useCallback(async () => {
    if (!namespaceId) return;

    setIsLoading(true);
    setError(null);

    try {
      const namespaceData = await namespaceService.getNamespaceById(namespaceId);
      setNamespace(namespaceData);

      // Fetch stats separately (might fail if not enough permissions)
      try {
        const statsData = await namespaceService.getNamespaceStatsAdmin(namespaceId);
        setStats(statsData);
      } catch (statsError) {
        console.warn('Failed to fetch namespace stats:', statsError);
        // Stats are optional, don't block the page
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load namespace';
      setError(message);
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, [namespaceId]);

  useEffect(() => {
    if (isAdmin) {
      fetchNamespace();
    }
  }, [fetchNamespace, isAdmin]);

  const handleEdit = useCallback(() => {
    router.push(`/dashboard/namespaces/${namespaceId}/edit`);
  }, [router, namespaceId]);

  const handleSettings = useCallback(() => {
    router.push(`/dashboard/namespaces/${namespaceId}/settings`);
  }, [router, namespaceId]);

  const handleInviteMember = useCallback(() => {
    // Could open a modal or navigate to members page with invite modal open
    router.push(`/dashboard/namespaces/${namespaceId}/members?invite=true`);
  }, [router, namespaceId]);

  // Access denied view for non-admins
  if (!isAdmin) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Namespace Details</h1>
          <p className="text-secondary-500 mt-1">View namespace information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500 mb-4">
            You need platform administrator access to view namespace details.
          </p>
          <Link href="/dashboard/namespaces">
            <Button variant="outline">Back to Namespaces</Button>
          </Link>
        </Card>
      </div>
    );
  }

  // Loading state
  if (isLoading) {
    return (
      <div className="space-y-6">
        <NamespaceHeader
          namespace={{} as Namespace}
          isLoading={true}
        />
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-6">
            <NamespaceStatsCard namespace={{} as Namespace} stats={null} isLoading={true} />
            <NamespaceMembersCard namespace={{} as Namespace} />
          </div>
          <div className="space-y-6">
            <NamespaceSettingsCard namespace={{} as Namespace} isLoading={true} />
            <NamespaceActivityCard namespace={{} as Namespace} isLoading={true} />
          </div>
        </div>
      </div>
    );
  }

  // Error state
  if (error || !namespace) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Namespace Details</h1>
          <p className="text-secondary-500 mt-1">View namespace information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            {error || 'Namespace Not Found'}
          </h2>
          <p className="text-secondary-500 mb-4">
            The namespace you're looking for doesn't exist or you don't have permission to view it.
          </p>
          <div className="flex items-center justify-center gap-3">
            <Link href="/dashboard/namespaces">
              <Button variant="outline">Back to Namespaces</Button>
            </Link>
            <Button onClick={fetchNamespace}>Try Again</Button>
          </div>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header with namespace info and actions */}
      <NamespaceHeader
        namespace={namespace}
        onEdit={handleEdit}
        onSettings={handleSettings}
      />

      {/* Main content grid */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left column - Stats and Members */}
        <div className="lg:col-span-2 space-y-6">
          <NamespaceStatsCard
            namespace={namespace}
            stats={stats}
          />
          <NamespaceMembersCard
            namespace={namespace}
            onInviteMember={handleInviteMember}
          />
        </div>

        {/* Right column - Settings and Activity */}
        <div className="space-y-6">
          <NamespaceSettingsCard namespace={namespace} />
          <NamespaceActivityCard namespace={namespace} />
        </div>
      </div>
    </div>
  );
}
