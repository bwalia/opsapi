'use client';

/**
 * EditRolesModal — assign one or more namespace roles to a member.
 *
 * Shared by the Members screen and the Users list. The affected member must
 * sign in again (or switch namespaces) before their new permissions take effect,
 * since the frontend caches permissions from the login/switch response.
 */

import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { Loader2 } from 'lucide-react';
import { Button } from '@/components/ui';
import { namespaceService } from '@/services';
import type { NamespaceRole } from '@/types';
import toast from 'react-hot-toast';

interface EditRolesModalProps {
  memberUuid: string;
  memberName: string;
  /** True when this member owns the workspace — restricting them is reversible only by a platform admin. */
  isOwner?: boolean;
  currentRoleIds: number[];
  roles: NamespaceRole[];
  onClose: () => void;
  onSuccess: () => void;
}

export function EditRolesModal({
  memberUuid,
  memberName,
  isOwner = false,
  currentRoleIds,
  roles,
  onClose,
  onSuccess,
}: EditRolesModalProps) {
  const [selectedIds, setSelectedIds] = useState<number[]>(() => [...currentRoleIds]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  // Portal to <body> so the modal (and its own <form>) never nests inside a
  // caller's form (e.g. the user edit page), which would be invalid markup.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const toggle = (id: number) =>
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    try {
      await namespaceService.updateMember(memberUuid, { role_ids: selectedIds });
      toast.success('Roles updated');
      onSuccess();
    } catch {
      toast.error('Failed to update roles');
    } finally {
      setIsSubmitting(false);
    }
  };

  if (!mounted) return null;

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-secondary-900/50 backdrop-blur-sm" onClick={onClose} />
      <div className="relative bg-surface rounded-xl shadow-2xl w-full max-w-md mx-4 p-6">
        <h2 className="text-xl font-semibold text-secondary-900 mb-1">Edit roles</h2>
        <p className="text-sm text-secondary-500 mb-4">Choose what {memberName} can do in this workspace.</p>

        {isOwner && (
          <p className="text-xs text-warning-700 bg-warning-50 border border-warning-200 rounded-lg px-3 py-2 mb-4">
            This is the workspace owner. Restricting them to a limited role (e.g. Service Manager)
            takes effect immediately — only a platform admin can restore full access afterwards.
          </p>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="max-h-72 overflow-y-auto space-y-2 -mx-1 px-1">
            {roles.length === 0 ? (
              <p className="text-sm text-secondary-400">No roles available.</p>
            ) : (
              roles.map((role) => (
                <label
                  key={role.id}
                  className="flex items-start gap-3 rounded-lg border border-secondary-200 p-3 cursor-pointer hover:bg-secondary-50"
                >
                  <input
                    type="checkbox"
                    className="mt-0.5 h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
                    checked={selectedIds.includes(role.id)}
                    onChange={() => toggle(role.id)}
                  />
                  <span className="min-w-0">
                    <span className="block font-medium text-secondary-900">
                      {role.display_name || role.role_name}
                    </span>
                    {role.description && (
                      <span className="block text-xs text-secondary-500">{role.description}</span>
                    )}
                  </span>
                </label>
              ))
            )}
          </div>

          <p className="text-xs text-secondary-500">
            They&apos;ll need to sign in again for changes to take effect.
          </p>

          <div className="flex justify-end gap-3 pt-2">
            <Button type="button" variant="secondary" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              Save roles
            </Button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}

export default EditRolesModal;
