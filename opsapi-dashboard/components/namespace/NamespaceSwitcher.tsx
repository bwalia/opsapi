'use client';

import React, { useState, useCallback, memo } from 'react';
import {
  Building2,
  ChevronDown,
  Check,
  Plus,
  Settings,
  Users,
  Loader2,
  Crown,
  Star,
  StarOff,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useNamespace } from '@/contexts/NamespaceContext';
import type { NamespaceWithMembership } from '@/types';

interface NamespaceSwitcherProps {
  variant?: 'header' | 'sidebar';
  className?: string;
}

// Namespace item in dropdown
const NamespaceItem = memo(function NamespaceItem({
  namespace,
  isActive,
  isDefault,
  onClick,
  onSetDefault,
}: {
  namespace: NamespaceWithMembership;
  isActive: boolean;
  isDefault: boolean;
  onClick: () => void;
  onSetDefault: () => void;
}) {
  const handleSetDefault = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      onSetDefault();
    },
    [onSetDefault]
  );

  return (
    <div
      className={cn(
        'w-full flex items-center gap-3 px-3 py-2.5 text-left transition-colors rounded-lg group',
        isActive
          ? 'bg-primary-50 text-primary-700'
          : 'hover:bg-secondary-50 text-secondary-700'
      )}
    >
      <button
        onClick={onClick}
        className="flex items-center gap-3 flex-1 min-w-0"
      >
        <div
          className={cn(
            'w-8 h-8 rounded-lg flex items-center justify-center text-white font-semibold text-sm',
            isActive ? 'bg-primary-500' : 'bg-secondary-400'
          )}
        >
          {namespace.logo_url ? (
            <img
              src={namespace.logo_url}
              alt={namespace.name}
              className="w-full h-full object-cover rounded-lg"
            />
          ) : (
            namespace.name.charAt(0).toUpperCase()
          )}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1.5">
            <span className="text-sm font-medium truncate">{namespace.name}</span>
            {namespace.is_owner && (
              <Crown className="w-3.5 h-3.5 text-amber-500 flex-shrink-0" />
            )}
            {isDefault && (
              <Star className="w-3.5 h-3.5 text-primary-500 flex-shrink-0 fill-primary-500" />
            )}
          </div>
          <span className="text-xs text-secondary-500 truncate block">
            {namespace.slug}
          </span>
        </div>
      </button>

      <div className="flex items-center gap-1">
        {!isDefault && (
          <button
            onClick={handleSetDefault}
            title="Set as default namespace"
            className="p-1.5 rounded-md opacity-0 group-hover:opacity-100 hover:bg-secondary-200 transition-all"
          >
            <StarOff className="w-3.5 h-3.5 text-secondary-400 hover:text-primary-500" />
          </button>
        )}
        {isActive && <Check className="w-4 h-4 text-primary-600 flex-shrink-0" />}
      </div>
    </div>
  );
});

// Create namespace modal trigger
const CreateNamespaceButton = memo(function CreateNamespaceButton({
  onClick,
}: {
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-3 px-3 py-2.5 text-left text-secondary-600 hover:bg-secondary-50 rounded-lg transition-colors"
    >
      <div className="w-8 h-8 rounded-lg border-2 border-dashed border-secondary-300 flex items-center justify-center">
        <Plus className="w-4 h-4" />
      </div>
      <span className="text-sm font-medium">Create Namespace</span>
    </button>
  );
});

export const NamespaceSwitcher: React.FC<NamespaceSwitcherProps> = memo(
  function NamespaceSwitcher({ variant = 'header', className }) {
    const [isOpen, setIsOpen] = useState(false);
    const [showCreateModal, setShowCreateModal] = useState(false);
    const [settingDefault, setSettingDefault] = useState<string | null>(null);
    const {
      currentNamespace,
      namespaces,
      namespacesLoading,
      isSwitching,
      switchNamespace,
      setDefaultNamespace,
      isNamespaceOwner,
      defaultNamespaceInfo,
    } = useNamespace();

    const handleToggle = useCallback(() => {
      setIsOpen((prev) => !prev);
    }, []);

    const handleClose = useCallback(() => {
      setIsOpen(false);
    }, []);

    const handleSwitch = useCallback(
      async (namespaceId: string) => {
        if (currentNamespace?.uuid === namespaceId) {
          handleClose();
          return;
        }

        const success = await switchNamespace(namespaceId);
        if (success) {
          handleClose();
          // Reload to apply new namespace context
          window.location.reload();
        }
      },
      [currentNamespace?.uuid, switchNamespace, handleClose]
    );

    const handleSetDefault = useCallback(
      async (namespace: NamespaceWithMembership) => {
        setSettingDefault(namespace.uuid);
        try {
          await setDefaultNamespace(namespace.id);
        } finally {
          setSettingDefault(null);
        }
      },
      [setDefaultNamespace]
    );

    const handleCreateClick = useCallback(() => {
      setShowCreateModal(true);
      handleClose();
    }, [handleClose]);

    // Don't render if no namespaces available
    if (!currentNamespace && namespaces.length === 0 && !namespacesLoading) {
      return null;
    }

    const isCompact = variant === 'sidebar';

    return (
      <>
        <div className={cn('relative', className)}>
          {/* Trigger Button */}
          <button
            onClick={handleToggle}
            disabled={isSwitching}
            className={cn(
              'flex items-center gap-2 transition-colors rounded-lg',
              isCompact
                ? 'w-full p-2 hover:bg-white/10'
                : 'px-3 py-2 hover:bg-secondary-100 border border-secondary-200'
            )}
            aria-expanded={isOpen}
            aria-haspopup="listbox"
          >
            {isSwitching ? (
              <Loader2 className="w-5 h-5 animate-spin text-secondary-500" />
            ) : (
              <div
                className={cn(
                  'flex items-center justify-center rounded-lg font-semibold text-white',
                  isCompact ? 'w-8 h-8 text-sm' : 'w-7 h-7 text-xs',
                  'bg-primary-500'
                )}
              >
                {currentNamespace?.logo_url ? (
                  <img
                    src={currentNamespace.logo_url}
                    alt={currentNamespace.name}
                    className="w-full h-full object-cover rounded-lg"
                  />
                ) : currentNamespace ? (
                  currentNamespace.name.charAt(0).toUpperCase()
                ) : (
                  <Building2 className="w-4 h-4" />
                )}
              </div>
            )}

            {!isCompact && (
              <>
                <div className="flex-1 min-w-0 text-left">
                  <span className="text-sm font-medium text-secondary-900 truncate block">
                    {currentNamespace?.name || 'Select Namespace'}
                  </span>
                </div>
                <ChevronDown
                  className={cn(
                    'w-4 h-4 text-secondary-400 transition-transform',
                    isOpen && 'rotate-180'
                  )}
                />
              </>
            )}
          </button>

          {/* Dropdown */}
          {isOpen && (
            <>
              <div
                className="fixed inset-0 z-40"
                onClick={handleClose}
                aria-hidden="true"
              />
              <div
                className={cn(
                  'absolute z-50 bg-white rounded-xl shadow-xl border border-secondary-200 py-2',
                  isCompact
                    ? 'left-full top-0 ml-2 w-64'
                    : 'top-full left-0 mt-2 w-72'
                )}
              >
                {/* Header */}
                <div className="px-3 pb-2 mb-2 border-b border-secondary-100">
                  <p className="text-xs font-medium text-secondary-500 uppercase tracking-wide">
                    Namespaces
                  </p>
                  {defaultNamespaceInfo && (
                    <p className="text-xs text-secondary-400 mt-0.5">
                      Default: {defaultNamespaceInfo.name || defaultNamespaceInfo.slug}
                    </p>
                  )}
                </div>

                {/* Namespace List */}
                <div className="max-h-64 overflow-y-auto px-2">
                  {namespacesLoading ? (
                    <div className="flex items-center justify-center py-4">
                      <Loader2 className="w-5 h-5 animate-spin text-secondary-400" />
                    </div>
                  ) : namespaces.length === 0 ? (
                    <p className="text-sm text-secondary-500 text-center py-4">
                      No namespaces available
                    </p>
                  ) : (
                    namespaces.map((namespace) => (
                      <div key={namespace.uuid} className="relative">
                        {settingDefault === namespace.uuid && (
                          <div className="absolute inset-0 bg-white/50 flex items-center justify-center rounded-lg z-10">
                            <Loader2 className="w-4 h-4 animate-spin text-primary-500" />
                          </div>
                        )}
                        <NamespaceItem
                          namespace={namespace}
                          isActive={currentNamespace?.uuid === namespace.uuid}
                          isDefault={defaultNamespaceInfo?.uuid === namespace.uuid}
                          onClick={() => handleSwitch(namespace.uuid)}
                          onSetDefault={() => handleSetDefault(namespace)}
                        />
                      </div>
                    ))
                  )}
                </div>

                {/* Actions */}
                <div className="px-2 pt-2 mt-2 border-t border-secondary-100 space-y-1">
                  <CreateNamespaceButton onClick={handleCreateClick} />

                  {currentNamespace && (
                    <>
                      {isNamespaceOwner && (
                        <a
                          href="/dashboard/namespace/settings"
                          className="w-full flex items-center gap-3 px-3 py-2.5 text-left text-secondary-600 hover:bg-secondary-50 rounded-lg transition-colors"
                        >
                          <Settings className="w-4 h-4" />
                          <span className="text-sm">Namespace Settings</span>
                        </a>
                      )}
                      <a
                        href="/dashboard/namespace/members"
                        className="w-full flex items-center gap-3 px-3 py-2.5 text-left text-secondary-600 hover:bg-secondary-50 rounded-lg transition-colors"
                      >
                        <Users className="w-4 h-4" />
                        <span className="text-sm">Manage Members</span>
                      </a>
                    </>
                  )}
                </div>
              </div>
            </>
          )}
        </div>

        {/* Create Namespace Modal */}
        {showCreateModal && (
          <CreateNamespaceModal onClose={() => setShowCreateModal(false)} />
        )}
      </>
    );
  }
);

// Create Namespace Modal
const CreateNamespaceModal = memo(function CreateNamespaceModal({
  onClose,
}: {
  onClose: () => void;
}) {
  const { createNamespace } = useNamespace();
  const [name, setName] = useState('');
  const [slug, setSlug] = useState('');
  const [description, setDescription] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      if (!name.trim()) {
        setError('Name is required');
        return;
      }

      setIsSubmitting(true);
      setError(null);

      const result = await createNamespace({
        name: name.trim(),
        slug: slug.trim() || undefined,
        description: description.trim() || undefined,
      });

      setIsSubmitting(false);

      if (result) {
        onClose();
        // Reload to apply new namespace
        window.location.reload();
      } else {
        setError('Failed to create namespace. Please try again.');
      }
    },
    [name, slug, description, createNamespace, onClose]
  );

  const handleNameChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const value = e.target.value;
      setName(value);
      // Auto-generate slug from name
      if (!slug || slug === generateSlug(name)) {
        setSlug(generateSlug(value));
      }
    },
    [slug, name]
  );

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div
        className="absolute inset-0 bg-secondary-900/50 backdrop-blur-sm"
        onClick={onClose}
      />
      <div className="relative bg-white rounded-xl shadow-2xl w-full max-w-md mx-4 p-6">
        <h2 className="text-xl font-semibold text-secondary-900 mb-4">
          Create New Namespace
        </h2>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Name <span className="text-error-500">*</span>
            </label>
            <input
              type="text"
              value={name}
              onChange={handleNameChange}
              placeholder="My Company"
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              autoFocus
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Slug
            </label>
            <input
              type="text"
              value={slug}
              onChange={(e) => setSlug(e.target.value)}
              placeholder="my-company"
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
            <p className="text-xs text-secondary-500 mt-1">
              Used in URLs. Only lowercase letters, numbers, and hyphens.
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Description
            </label>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="A brief description of your namespace..."
              rows={3}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none"
            />
          </div>

          {error && (
            <div className="p-3 bg-error-50 border border-error-200 rounded-lg">
              <p className="text-sm text-error-700">{error}</p>
            </div>
          )}

          <div className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={isSubmitting || !name.trim()}
              className="px-4 py-2 text-sm font-medium text-white bg-primary-500 hover:bg-primary-600 rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
            >
              {isSubmitting && <Loader2 className="w-4 h-4 animate-spin" />}
              Create Namespace
            </button>
          </div>
        </form>
      </div>
    </div>
  );
});

// Helper to generate slug from name
function generateSlug(name: string): string {
  return name
    .toLowerCase()
    .replace(/\s+/g, '-')
    .replace(/[^a-z0-9-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

export default NamespaceSwitcher;
