'use client';

/**
 * UserWorkspaceRolesCard — manage a user's role(s) in the CURRENT workspace
 * (namespace). This is the tenant-scoped role (Service Manager, Engineer, …),
 * not the global platform role. Owners aren't editable here — ownership grants
 * full access by design.
 */

import React, { useCallback, useEffect, useState } from 'react';
import { Shield, Crown, Building2 } from 'lucide-react';
import { Card, Badge, Button } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { usersService, namespaceService } from '@/services';
import { EditRolesModal } from '@/components/namespace/EditRolesModal';
import type { NamespaceRole } from '@/types';

interface Membership {
  membership_uuid?: string;
  membership_id: number;
  namespace_uuid: string;
  is_owner: boolean;
  roles?: Array<{ id: number; role_name: string; display_name?: string }>;
}

export function UserWorkspaceRolesCard({
  userUuid,
  userName,
}: {
  userUuid: string;
  userName: string;
}) {
  const { currentNamespace, canUpdate } = useNamespace();
  const [membership, setMembership] = useState<Membership | null>(null);
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [loading, setLoading] = useState(true);
  const [modalOpen, setModalOpen] = useState(false);

  const load = useCallback(async () => {
    if (!currentNamespace) return;
    setLoading(true);
    try {
      const [detailed, roleList] = await Promise.all([
        usersService.getUser(userUuid, { detailed: true }),
        canUpdate('users') ? namespaceService.getRoles() : Promise.resolve([] as NamespaceRole[]),
      ]);
      const memberships =
        (detailed as { namespaces?: Membership[] }).namespaces || [];
      setMembership(memberships.find((m) => m.namespace_uuid === currentNamespace.uuid) || null);
      setRoles(roleList);
    } catch {
      setMembership(null);
    } finally {
      setLoading(false);
    }
  }, [userUuid, currentNamespace, canUpdate]);

  useEffect(() => {
    load();
  }, [load]);

  const title = (
    <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
      Workspace roles
    </h3>
  );

  if (loading) {
    return (
      <Card className="p-6 animate-pulse">
        <div className="h-4 bg-secondary-200 rounded w-32 mb-6" />
        <div className="h-8 bg-secondary-200 rounded" />
      </Card>
    );
  }

  if (!membership) {
    return (
      <Card className="p-6">
        {title}
        <div className="text-center py-4 text-secondary-500">
          <Building2 className="w-8 h-8 mx-auto mb-2 text-secondary-300" />
          <p className="text-sm">
            Not a member of {currentNamespace?.name || 'this workspace'}.
          </p>
        </div>
      </Card>
    );
  }

  if (membership.is_owner) {
    return (
      <Card className="p-6">
        {title}
        <div className="flex items-center gap-2">
          <Crown className="w-4 h-4 text-amber-500" />
          <span className="text-sm text-secondary-800">Owner — full access</span>
        </div>
        <p className="text-xs text-secondary-500 mt-2">
          The workspace owner always has full access; their role can&apos;t be limited.
        </p>
      </Card>
    );
  }

  const current = membership.roles || [];

  return (
    <Card className="p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider">
          Workspace roles
        </h3>
        {canUpdate('users') && (
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() => setModalOpen(true)}
            leftIcon={<Shield className="w-3.5 h-3.5" />}
          >
            Manage
          </Button>
        )}
      </div>

      <div className="flex flex-wrap gap-1.5">
        {current.length > 0 ? (
          current.map((r) => (
            <Badge key={r.id} variant="default">
              {r.display_name || r.role_name}
            </Badge>
          ))
        ) : (
          <span className="text-sm text-secondary-400">No roles assigned</span>
        )}
      </div>

      <p className="text-xs text-secondary-500 mt-3">
        What {userName} can do in {currentNamespace?.name || 'this workspace'}.
      </p>

      {modalOpen && (
        <EditRolesModal
          memberUuid={membership.membership_uuid || String(membership.membership_id)}
          memberName={userName}
          currentRoleIds={current.map((r) => Number(r.id))}
          roles={roles}
          onClose={() => setModalOpen(false)}
          onSuccess={() => {
            setModalOpen(false);
            load();
          }}
        />
      )}
    </Card>
  );
}

export default UserWorkspaceRolesCard;
