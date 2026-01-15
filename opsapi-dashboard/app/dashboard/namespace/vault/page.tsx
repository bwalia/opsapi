'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  Shield,
  Lock,
  Unlock,
  Key,
  History,
  Settings,
  Loader2,
  AlertCircle,
} from 'lucide-react';
import { Button, Card, Modal, Badge } from '@/components/ui';
import {
  VaultSetup,
  VaultUnlock,
  FolderTree,
  SecretList,
  AddSecretModal,
  SecretDetail,
  ShareSecretModal,
  VaultAccessLogs,
} from '@/components/vault';
import { vaultService, isVaultUnlocked, clearVaultKey } from '@/services/vault.service';
import { useNamespace } from '@/contexts/NamespaceContext';
import type { Vault, VaultFolder, VaultSecret, VaultStats } from '@/types';
import toast from 'react-hot-toast';
import { ConfirmDialog } from '@/components/ui/Modal';

type VaultView = 'secrets' | 'logs' | 'settings';

export default function VaultPage() {
  const { currentNamespace } = useNamespace();

  // Vault state
  const [vault, setVault] = useState<Vault | null>(null);
  const [vaultState, setVaultState] = useState<'loading' | 'no-vault' | 'locked' | 'unlocked'>('loading');
  const [stats, setStats] = useState<VaultStats | null>(null);

  // Content state
  const [folders, setFolders] = useState<VaultFolder[]>([]);
  const [secrets, setSecrets] = useState<VaultSecret[]>([]);
  const [selectedFolderId, setSelectedFolderId] = useState<string | null>(null);
  const [isLoadingContent, setIsLoadingContent] = useState(false);

  // UI state
  const [currentView, setCurrentView] = useState<VaultView>('secrets');
  const [showAddSecretModal, setShowAddSecretModal] = useState(false);
  const [editingSecret, setEditingSecret] = useState<VaultSecret | null>(null);
  const [viewingSecret, setViewingSecret] = useState<VaultSecret | null>(null);
  const [sharingSecret, setSharingSecret] = useState<VaultSecret | null>(null);
  const [deletingSecret, setDeletingSecret] = useState<VaultSecret | null>(null);
  const [showLogsModal, setShowLogsModal] = useState(false);
  const [isDeletingSecret, setIsDeletingSecret] = useState(false);

  // Check vault status
  const checkVaultStatus = useCallback(async () => {
    try {
      const vaultData = await vaultService.getVault();

      if (!vaultData) {
        setVaultState('no-vault');
        return;
      }

      setVault(vaultData);

      if (isVaultUnlocked()) {
        setVaultState('unlocked');
      } else {
        setVaultState('locked');
      }
    } catch (err) {
      console.error('Failed to check vault status:', err);
      setVaultState('no-vault');
    }
  }, []);

  // Load vault content
  const loadVaultContent = useCallback(async () => {
    if (vaultState !== 'unlocked') return;

    setIsLoadingContent(true);
    try {
      const [foldersData, secretsData, statsData] = await Promise.all([
        vaultService.getFolders(),
        vaultService.getSecrets({ folder_id: selectedFolderId || undefined }),
        vaultService.getStats(),
      ]);

      setFolders(foldersData);
      setSecrets(secretsData.data || []);
      setStats(statsData);
    } catch (err) {
      const error = err as Error;
      if (error.message?.includes('Vault key is required')) {
        // Key was cleared (expired or invalid)
        setVaultState('locked');
        clearVaultKey();
      } else {
        toast.error(error.message || 'Failed to load vault content');
      }
    } finally {
      setIsLoadingContent(false);
    }
  }, [vaultState, selectedFolderId]);

  // Load secrets when folder changes
  const loadSecrets = useCallback(async () => {
    if (vaultState !== 'unlocked') return;

    setIsLoadingContent(true);
    try {
      const secretsData = await vaultService.getSecrets({
        folder_id: selectedFolderId || undefined,
      });
      setSecrets(secretsData.data || []);
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to load secrets');
    } finally {
      setIsLoadingContent(false);
    }
  }, [vaultState, selectedFolderId]);

  useEffect(() => {
    checkVaultStatus();
  }, [checkVaultStatus, currentNamespace]);

  useEffect(() => {
    if (vaultState === 'unlocked') {
      loadVaultContent();
    }
  }, [vaultState, loadVaultContent]);

  useEffect(() => {
    if (vaultState === 'unlocked' && selectedFolderId !== null) {
      loadSecrets();
    }
  }, [selectedFolderId, loadSecrets, vaultState]);

  // Handlers
  const handleVaultCreated = () => {
    setVaultState('unlocked');
  };

  const handleVaultUnlocked = () => {
    setVaultState('unlocked');
  };

  const handleLockVault = () => {
    vaultService.lockVault();
    setVaultState('locked');
    setFolders([]);
    setSecrets([]);
    setStats(null);
    toast.success('Vault locked');
  };

  const handleFoldersChange = () => {
    loadVaultContent();
  };

  const handleAddSecret = () => {
    setEditingSecret(null);
    setShowAddSecretModal(true);
  };

  const handleEditSecret = (secret: VaultSecret) => {
    setViewingSecret(null);
    setEditingSecret(secret);
    setShowAddSecretModal(true);
  };

  const handleViewSecret = (secret: VaultSecret) => {
    setViewingSecret(secret);
  };

  const handleShareSecret = (secret: VaultSecret) => {
    setViewingSecret(null);
    setSharingSecret(secret);
  };

  const handleDeleteSecret = (secret: VaultSecret) => {
    setViewingSecret(null);
    setDeletingSecret(secret);
  };

  const confirmDeleteSecret = async () => {
    if (!deletingSecret) return;

    setIsDeletingSecret(true);
    try {
      await vaultService.deleteSecret(deletingSecret.id);
      toast.success('Secret deleted successfully');
      setDeletingSecret(null);
      loadSecrets();
      // Update stats
      const statsData = await vaultService.getStats();
      setStats(statsData);
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to delete secret');
    } finally {
      setIsDeletingSecret(false);
    }
  };

  const handleSecretSaved = () => {
    loadSecrets();
    vaultService.getStats().then(setStats).catch(console.error);
  };

  // Render loading state
  if (vaultState === 'loading') {
    return (
      <div className="flex items-center justify-center min-h-[400px]">
        <div className="text-center">
          <Loader2 className="w-10 h-10 text-primary-500 animate-spin mx-auto mb-4" />
          <p className="text-secondary-500">Loading vault...</p>
        </div>
      </div>
    );
  }

  // Render no namespace state
  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Secret Vault</h1>
          <p className="text-secondary-500 mt-1">No namespace selected</p>
        </div>

        <Card className="p-8 text-center">
          <AlertCircle className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            No Namespace Selected
          </h2>
          <p className="text-secondary-500">
            Please select a namespace to access your secret vault.
          </p>
        </Card>
      </div>
    );
  }

  // Render setup state (no vault exists)
  if (vaultState === 'no-vault') {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Secret Vault</h1>
          <p className="text-secondary-500 mt-1">Set up your secure vault</p>
        </div>

        <VaultSetup onSuccess={handleVaultCreated} />
      </div>
    );
  }

  // Render locked state
  if (vaultState === 'locked') {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Secret Vault</h1>
          <p className="text-secondary-500 mt-1">Unlock your vault to access secrets</p>
        </div>

        <VaultUnlock
          onSuccess={handleVaultUnlocked}
          failedAttempts={vault?.failed_attempts || 0}
        />
      </div>
    );
  }

  // Render unlocked state - main vault UI
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div className="flex items-center gap-4">
          <div className="w-14 h-14 rounded-xl bg-primary-500 flex items-center justify-center shadow-lg shadow-primary-500/25">
            <Shield className="w-7 h-7 text-white" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-bold text-secondary-900">
                {vault?.name || 'Secret Vault'}
              </h1>
              <Badge variant="success" className="flex items-center gap-1">
                <Unlock className="w-3 h-3" />
                Unlocked
              </Badge>
            </div>
            <p className="text-secondary-500 mt-0.5">
              {stats?.total_secrets || 0} secret{(stats?.total_secrets || 0) !== 1 ? 's' : ''} •{' '}
              {stats?.total_folders || 0} folder{(stats?.total_folders || 0) !== 1 ? 's' : ''}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            onClick={() => setShowLogsModal(true)}
            title="View access logs"
          >
            <History className="w-4 h-4 mr-2" />
            Logs
          </Button>
          <Button variant="secondary" onClick={handleLockVault}>
            <Lock className="w-4 h-4 mr-2" />
            Lock Vault
          </Button>
        </div>
      </div>

      {/* Main Content */}
      <div className="grid grid-cols-12 gap-6 min-h-[600px]">
        {/* Folder Sidebar */}
        <div className="col-span-12 lg:col-span-3">
          <Card className="h-full min-h-[400px]">
            <FolderTree
              folders={folders}
              selectedFolderId={selectedFolderId}
              onSelectFolder={setSelectedFolderId}
              onFoldersChange={handleFoldersChange}
            />
          </Card>
        </div>

        {/* Secret List */}
        <div className="col-span-12 lg:col-span-9">
          <SecretList
            secrets={secrets}
            folders={folders}
            isLoading={isLoadingContent}
            selectedFolderId={selectedFolderId}
            onAddSecret={handleAddSecret}
            onViewSecret={handleViewSecret}
            onEditSecret={handleEditSecret}
            onShareSecret={handleShareSecret}
            onDeleteSecret={handleDeleteSecret}
            onRefresh={loadSecrets}
          />
        </div>
      </div>

      {/* Add/Edit Secret Modal */}
      <AddSecretModal
        isOpen={showAddSecretModal}
        onClose={() => {
          setShowAddSecretModal(false);
          setEditingSecret(null);
        }}
        onSuccess={handleSecretSaved}
        folders={folders}
        editSecret={editingSecret}
        defaultFolderId={selectedFolderId}
      />

      {/* View Secret Modal */}
      {viewingSecret && (
        <SecretDetail
          secret={viewingSecret}
          folders={folders}
          onClose={() => setViewingSecret(null)}
          onEdit={handleEditSecret}
          onShare={handleShareSecret}
          onDelete={handleDeleteSecret}
        />
      )}

      {/* Share Secret Modal */}
      {sharingSecret && (
        <ShareSecretModal
          isOpen={true}
          onClose={() => setSharingSecret(null)}
          secret={sharingSecret}
        />
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={!!deletingSecret}
        onClose={() => setDeletingSecret(null)}
        onConfirm={confirmDeleteSecret}
        title="Delete Secret"
        message={`Are you sure you want to delete "${deletingSecret?.name}"? This action cannot be undone.`}
        confirmText="Delete"
        cancelText="Cancel"
        variant="danger"
        isLoading={isDeletingSecret}
      />

      {/* Access Logs Modal */}
      <Modal
        isOpen={showLogsModal}
        onClose={() => setShowLogsModal(false)}
        title="Vault Access Logs"
        size="xl"
      >
        <VaultAccessLogs onClose={() => setShowLogsModal(false)} />
      </Modal>
    </div>
  );
}
