'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  Key,
  FileText,
  CreditCard,
  Globe,
  Shield,
  Eye,
  EyeOff,
  Copy,
  Edit2,
  Share2,
  Trash2,
  ExternalLink,
  X,
  Clock,
  Folder,
  Loader2,
  User,
} from 'lucide-react';
import { Button, Badge, Card, Modal } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultSecret, VaultSecretType, VaultFolder, VaultShare } from '@/types';
import toast from 'react-hot-toast';
import { format, formatDistanceToNow } from 'date-fns';
import { cn } from '@/lib/utils';

interface SecretDetailProps {
  secret: VaultSecret;
  folders: VaultFolder[];
  onClose: () => void;
  onEdit: (secret: VaultSecret) => void;
  onShare: (secret: VaultSecret) => void;
  onDelete: (secret: VaultSecret) => void;
}

type BadgeVariant = 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary';

const SECRET_TYPE_CONFIG: Record<
  VaultSecretType,
  { icon: React.ElementType; label: string; color: BadgeVariant }
> = {
  generic: { icon: Key, label: 'Generic', color: 'secondary' },
  password: { icon: Key, label: 'Password', color: 'info' },
  api_key: { icon: Shield, label: 'API Key', color: 'warning' },
  ssh_key: { icon: Key, label: 'SSH Key', color: 'info' },
  certificate: { icon: Shield, label: 'Certificate', color: 'success' },
  database: { icon: Globe, label: 'Database', color: 'warning' },
  oauth_token: { icon: Shield, label: 'OAuth Token', color: 'info' },
  credit_card: { icon: CreditCard, label: 'Credit Card', color: 'error' },
  credential: { icon: CreditCard, label: 'Credential', color: 'success' },
  note: { icon: FileText, label: 'Note', color: 'secondary' },
  env_variable: { icon: Globe, label: 'Env Variable', color: 'info' },
  license_key: { icon: Key, label: 'License Key', color: 'warning' },
  webhook_secret: { icon: Shield, label: 'Webhook Secret', color: 'info' },
  encryption_key: { icon: Key, label: 'Encryption Key', color: 'error' },
  other: { icon: Globe, label: 'Other', color: 'info' },
};

const SecretDetail: React.FC<SecretDetailProps> = ({
  secret,
  folders,
  onClose,
  onEdit,
  onShare,
  onDelete,
}) => {
  const [showValue, setShowValue] = useState(false);
  const [decryptedValue, setDecryptedValue] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [shares, setShares] = useState<VaultShare[]>([]);
  const [isLoadingShares, setIsLoadingShares] = useState(false);

  const typeConfig = SECRET_TYPE_CONFIG[secret.secret_type];
  const TypeIcon = typeConfig.icon;

  const getFolderPath = useCallback((): string => {
    if (!secret.folder_id) return 'Root';

    const path: string[] = [];
    let currentId: string | null = secret.folder_id;

    while (currentId) {
      const folder = folders.find((f) => f.id === currentId);
      if (folder) {
        path.unshift(folder.name);
        currentId = folder.parent_id || null;
      } else {
        break;
      }
    }

    return path.join(' / ') || 'Root';
  }, [secret.folder_id, folders]);

  const loadSecretValue = useCallback(async () => {
    setIsLoading(true);
    try {
      const fullSecret = await vaultService.readSecret(secret.id);
      setDecryptedValue(fullSecret.value || '');
      setShowValue(true);
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to decrypt secret');
    } finally {
      setIsLoading(false);
    }
  }, [secret.id]);

  const loadShares = useCallback(async () => {
    setIsLoadingShares(true);
    try {
      const shareData = await vaultService.getSecretShares(secret.id);
      setShares(shareData);
    } catch (err) {
      console.error('Failed to load shares:', err);
    } finally {
      setIsLoadingShares(false);
    }
  }, [secret.id]);

  useEffect(() => {
    loadShares();
  }, [loadShares]);

  const handleCopyValue = async () => {
    try {
      if (!decryptedValue) {
        const fullSecret = await vaultService.readSecret(secret.id);
        await navigator.clipboard.writeText(fullSecret.value || '');
      } else {
        await navigator.clipboard.writeText(decryptedValue);
      }
      toast.success('Value copied to clipboard');
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to copy value');
    }
  };

  const handleCopyField = async (field: string, value: string) => {
    try {
      await navigator.clipboard.writeText(value);
      toast.success(`${field} copied to clipboard`);
    } catch {
      toast.error('Failed to copy');
    }
  };

  const handleRevoke = async (shareId: string) => {
    try {
      await vaultService.revokeShare(shareId);
      toast.success('Share revoked successfully');
      loadShares();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to revoke share');
    }
  };

  return (
    <Modal isOpen={true} onClose={onClose} title="" size="lg" showClose={false}>
      <div className="space-y-6">
        {/* Header */}
        <div className="flex items-start justify-between">
          <div className="flex items-start gap-4">
            <div
              className={cn('p-3 rounded-xl', `bg-${typeConfig.color}-100`)}
            >
              <TypeIcon className={cn('w-6 h-6', `text-${typeConfig.color}-600`)} />
            </div>
            <div>
              <h2 className="text-xl font-bold text-secondary-900">{secret.name}</h2>
              <div className="flex items-center gap-2 mt-1">
                <Badge variant={typeConfig.color}>
                  {typeConfig.label}
                </Badge>
                {secret.is_shared && (
                  <Badge variant="info">Shared</Badge>
                )}
              </div>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 hover:bg-secondary-100 rounded-lg transition-colors"
          >
            <X className="w-5 h-5 text-secondary-400" />
          </button>
        </div>

        {/* Description */}
        {secret.description && (
          <p className="text-secondary-600">{secret.description}</p>
        )}

        {/* Secret Value */}
        <Card className="p-4">
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm font-medium text-secondary-700">
              {secret.secret_type === 'note' ? 'Note Content' : 'Secret Value'}
            </span>
            <div className="flex items-center gap-2">
              <button
                onClick={handleCopyValue}
                className="p-1.5 hover:bg-secondary-100 rounded-lg transition-colors"
                title="Copy value"
              >
                <Copy className="w-4 h-4 text-secondary-400" />
              </button>
              <button
                onClick={() => {
                  if (showValue) {
                    setShowValue(false);
                  } else {
                    loadSecretValue();
                  }
                }}
                className="p-1.5 hover:bg-secondary-100 rounded-lg transition-colors"
                title={showValue ? 'Hide value' : 'Show value'}
                disabled={isLoading}
              >
                {isLoading ? (
                  <Loader2 className="w-4 h-4 text-secondary-400 animate-spin" />
                ) : showValue ? (
                  <EyeOff className="w-4 h-4 text-secondary-400" />
                ) : (
                  <Eye className="w-4 h-4 text-secondary-400" />
                )}
              </button>
            </div>
          </div>

          {secret.secret_type === 'note' ? (
            <div className="bg-secondary-50 rounded-lg p-3">
              {showValue && decryptedValue ? (
                <p className="text-sm text-secondary-900 whitespace-pre-wrap">
                  {decryptedValue}
                </p>
              ) : (
                <p className="text-sm text-secondary-400 italic">
                  Click the eye icon to reveal content
                </p>
              )}
            </div>
          ) : (
            <div className="bg-secondary-50 rounded-lg p-3 font-mono text-sm">
              {showValue && decryptedValue ? (
                <span className="text-secondary-900 break-all">{decryptedValue}</span>
              ) : (
                <span className="text-secondary-400">••••••••••••••••</span>
              )}
            </div>
          )}
        </Card>

        {/* Metadata Fields */}
        {(secret.metadata?.url || secret.metadata?.username) && (
          <div className="grid grid-cols-2 gap-4">
            {secret.metadata?.username && (
              <Card className="p-4">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-sm font-medium text-secondary-700">Username</span>
                  <button
                    onClick={() => handleCopyField('Username', secret.metadata?.username || '')}
                    className="p-1 hover:bg-secondary-100 rounded transition-colors"
                  >
                    <Copy className="w-3.5 h-3.5 text-secondary-400" />
                  </button>
                </div>
                <p className="text-sm text-secondary-900">{secret.metadata.username}</p>
              </Card>
            )}
            {secret.metadata?.url && (
              <Card className="p-4">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-sm font-medium text-secondary-700">URL</span>
                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => handleCopyField('URL', secret.metadata?.url || '')}
                      className="p-1 hover:bg-secondary-100 rounded transition-colors"
                    >
                      <Copy className="w-3.5 h-3.5 text-secondary-400" />
                    </button>
                    <a
                      href={secret.metadata.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="p-1 hover:bg-secondary-100 rounded transition-colors"
                    >
                      <ExternalLink className="w-3.5 h-3.5 text-secondary-400" />
                    </a>
                  </div>
                </div>
                <p className="text-sm text-secondary-900 truncate">{secret.metadata.url}</p>
              </Card>
            )}
          </div>
        )}

        {/* Details */}
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div className="flex items-center gap-2 text-secondary-600">
            <Folder className="w-4 h-4" />
            <span>{getFolderPath()}</span>
          </div>
          <div className="flex items-center gap-2 text-secondary-600">
            <Clock className="w-4 h-4" />
            <span>
              Updated {formatDistanceToNow(new Date(secret.updated_at), { addSuffix: true })}
            </span>
          </div>
        </div>

        {/* Tags */}
        {secret.tags && secret.tags.length > 0 && (
          <div>
            <span className="text-sm font-medium text-secondary-700 block mb-2">Tags</span>
            <div className="flex flex-wrap gap-2">
              {secret.tags.map((tag, i) => (
                <span
                  key={i}
                  className="px-2 py-1 text-xs bg-secondary-100 text-secondary-600 rounded-full"
                >
                  {tag}
                </span>
              ))}
            </div>
          </div>
        )}

        {/* Shares */}
        {shares.length > 0 && (
          <div>
            <span className="text-sm font-medium text-secondary-700 block mb-2">
              Shared With
            </span>
            {isLoadingShares ? (
              <div className="flex items-center justify-center py-4">
                <Loader2 className="w-5 h-5 text-primary-500 animate-spin" />
              </div>
            ) : (
              <div className="space-y-2">
                {shares.map((share) => (
                  <div
                    key={share.id}
                    className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg"
                  >
                    <div className="flex items-center gap-3">
                      <div className="p-2 bg-white rounded-full">
                        <User className="w-4 h-4 text-secondary-400" />
                      </div>
                      <div>
                        <p className="text-sm font-medium text-secondary-900">
                          {share.shared_with_email || 'Unknown user'}
                        </p>
                        <p className="text-xs text-secondary-500">
                          {share.permission === 'read' ? 'Read only' : 'Can edit'} •{' '}
                          {share.expires_at
                            ? `Expires ${format(new Date(share.expires_at), 'MMM d, yyyy')}`
                            : 'No expiration'}
                        </p>
                      </div>
                    </div>
                    <button
                      onClick={() => handleRevoke(share.id)}
                      className="text-xs text-error-600 hover:text-error-700"
                    >
                      Revoke
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-3 pt-4 border-t border-secondary-200">
          <Button
            variant="ghost"
            onClick={() => onEdit(secret)}
            className="flex-1"
          >
            <Edit2 className="w-4 h-4 mr-2" />
            Edit
          </Button>
          <Button
            variant="ghost"
            onClick={() => onShare(secret)}
            className="flex-1"
          >
            <Share2 className="w-4 h-4 mr-2" />
            Share
          </Button>
          <Button
            variant="danger"
            onClick={() => onDelete(secret)}
            className="flex-1"
          >
            <Trash2 className="w-4 h-4 mr-2" />
            Delete
          </Button>
        </div>

        {/* Timestamps */}
        <div className="text-xs text-secondary-400 text-center">
          Created {format(new Date(secret.created_at), 'MMM d, yyyy \'at\' h:mm a')}
        </div>
      </div>
    </Modal>
  );
};

export default SecretDetail;
