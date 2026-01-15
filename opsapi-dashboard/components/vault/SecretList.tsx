'use client';

import React, { useState, useCallback } from 'react';
import {
  Key,
  FileText,
  CreditCard,
  Globe,
  Shield,
  Search,
  Plus,
  MoreVertical,
  Eye,
  Share2,
  Edit2,
  Trash2,
  Copy,
  ExternalLink,
  Loader2,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button, Input, Badge, Card } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultSecret, VaultSecretType, VaultFolder } from '@/types';
import toast from 'react-hot-toast';
import { formatDistanceToNow } from 'date-fns';

interface SecretListProps {
  secrets: VaultSecret[];
  folders: VaultFolder[];
  isLoading: boolean;
  selectedFolderId: string | null;
  onAddSecret: () => void;
  onViewSecret: (secret: VaultSecret) => void;
  onEditSecret: (secret: VaultSecret) => void;
  onShareSecret: (secret: VaultSecret) => void;
  onDeleteSecret: (secret: VaultSecret) => void;
  onRefresh: () => void;
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

const SecretList: React.FC<SecretListProps> = ({
  secrets,
  folders,
  isLoading,
  selectedFolderId,
  onAddSecret,
  onViewSecret,
  onEditSecret,
  onShareSecret,
  onDeleteSecret,
  onRefresh,
}) => {
  const [searchQuery, setSearchQuery] = useState('');
  const [filterType, setFilterType] = useState<VaultSecretType | 'all'>('all');
  const [openMenuId, setOpenMenuId] = useState<string | null>(null);
  const [copyingId, setCopyingId] = useState<string | null>(null);

  const getFolderName = useCallback(
    (folderId: string | null | undefined): string => {
      if (!folderId) return 'Uncategorized';
      const folder = folders.find((f) => f.id === folderId);
      return folder?.name || 'Unknown';
    },
    [folders]
  );

  const filteredSecrets = secrets.filter((secret) => {
    if (filterType !== 'all' && secret.secret_type !== filterType) return false;
    if (searchQuery) {
      const query = searchQuery.toLowerCase();
      return (
        secret.name.toLowerCase().includes(query) ||
        secret.description?.toLowerCase().includes(query) ||
        secret.tags?.some((tag) => tag.toLowerCase().includes(query))
      );
    }
    return true;
  });

  const handleCopyValue = async (secret: VaultSecret) => {
    setCopyingId(secret.id);
    try {
      const fullSecret = await vaultService.readSecret(secret.id);
      await navigator.clipboard.writeText(fullSecret.value || '');
      toast.success('Secret value copied to clipboard');
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to copy secret');
    } finally {
      setCopyingId(null);
    }
  };

  const handleOpenUrl = async (secret: VaultSecret) => {
    try {
      const fullSecret = await vaultService.readSecret(secret.id);
      const url = fullSecret.metadata?.url;
      if (url) {
        window.open(url, '_blank', 'noopener,noreferrer');
      } else {
        toast.error('No URL associated with this secret');
      }
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to read secret');
    }
  };

  if (isLoading) {
    return (
      <div className="flex-1 flex items-center justify-center">
        <div className="text-center">
          <Loader2 className="w-8 h-8 text-primary-500 animate-spin mx-auto mb-3" />
          <p className="text-secondary-500">Loading secrets...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex-1 flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center justify-between gap-4 mb-4">
        <div className="flex-1 flex items-center gap-3">
          <div className="relative flex-1 max-w-md">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" />
            <input
              type="text"
              placeholder="Search secrets..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="w-full pl-9 pr-4 py-2 text-sm border border-secondary-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
            />
          </div>

          <select
            value={filterType}
            onChange={(e) => setFilterType(e.target.value as VaultSecretType | 'all')}
            className="px-3 py-2 text-sm border border-secondary-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Types</option>
            {Object.entries(SECRET_TYPE_CONFIG).map(([type, config]) => (
              <option key={type} value={type}>
                {config.label}
              </option>
            ))}
          </select>
        </div>

        <Button onClick={onAddSecret}>
          <Plus className="w-4 h-4 mr-2" />
          Add Secret
        </Button>
      </div>

      {/* Secret List */}
      <div className="flex-1 overflow-y-auto">
        {filteredSecrets.length === 0 ? (
          <Card className="p-12 text-center">
            <Key className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
            <h3 className="text-lg font-medium text-secondary-900 mb-2">
              {searchQuery || filterType !== 'all'
                ? 'No secrets found'
                : selectedFolderId
                  ? 'No secrets in this folder'
                  : 'No secrets yet'}
            </h3>
            <p className="text-secondary-500 mb-4">
              {searchQuery || filterType !== 'all'
                ? 'Try adjusting your search or filter'
                : 'Get started by adding your first secret'}
            </p>
            {!searchQuery && filterType === 'all' && (
              <Button onClick={onAddSecret}>
                <Plus className="w-4 h-4 mr-2" />
                Add Secret
              </Button>
            )}
          </Card>
        ) : (
          <div className="space-y-2">
            {filteredSecrets.map((secret) => {
              const typeConfig = SECRET_TYPE_CONFIG[secret.secret_type];
              const TypeIcon = typeConfig.icon;

              return (
                <Card
                  key={secret.id}
                  className="p-4 hover:bg-secondary-50 transition-colors cursor-pointer"
                  onClick={() => onViewSecret(secret)}
                >
                  <div className="flex items-start gap-4">
                    <div
                      className={cn(
                        'p-2 rounded-lg',
                        `bg-${typeConfig.color}-100`
                      )}
                    >
                      <TypeIcon
                        className={cn('w-5 h-5', `text-${typeConfig.color}-600`)}
                      />
                    </div>

                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-1">
                        <h4 className="font-medium text-secondary-900 truncate">
                          {secret.name}
                        </h4>
                        {secret.is_shared && (
                          <Badge variant="info" size="sm">
                            Shared
                          </Badge>
                        )}
                      </div>

                      {secret.description && (
                        <p className="text-sm text-secondary-500 truncate mb-2">
                          {secret.description}
                        </p>
                      )}

                      <div className="flex items-center gap-3 text-xs text-secondary-400">
                        <span className="flex items-center gap-1">
                          <Badge variant={typeConfig.color} size="sm">
                            {typeConfig.label}
                          </Badge>
                        </span>
                        {!selectedFolderId && secret.folder_id && (
                          <span>in {getFolderName(secret.folder_id)}</span>
                        )}
                        <span>
                          Updated{' '}
                          {formatDistanceToNow(new Date(secret.updated_at), {
                            addSuffix: true,
                          })}
                        </span>
                      </div>

                      {secret.tags && secret.tags.length > 0 && (
                        <div className="flex flex-wrap gap-1 mt-2">
                          {secret.tags.map((tag, i) => (
                            <span
                              key={i}
                              className="px-2 py-0.5 text-xs bg-secondary-100 text-secondary-600 rounded-full"
                            >
                              {tag}
                            </span>
                          ))}
                        </div>
                      )}
                    </div>

                    <div className="relative flex-shrink-0">
                      <div className="flex items-center gap-1">
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            handleCopyValue(secret);
                          }}
                          className="p-2 hover:bg-secondary-100 rounded-lg transition-colors"
                          title="Copy value"
                          disabled={copyingId === secret.id}
                        >
                          {copyingId === secret.id ? (
                            <Loader2 className="w-4 h-4 text-secondary-400 animate-spin" />
                          ) : (
                            <Copy className="w-4 h-4 text-secondary-400" />
                          )}
                        </button>

                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            setOpenMenuId(openMenuId === secret.id ? null : secret.id);
                          }}
                          className="p-2 hover:bg-secondary-100 rounded-lg transition-colors"
                        >
                          <MoreVertical className="w-4 h-4 text-secondary-400" />
                        </button>
                      </div>

                      {openMenuId === secret.id && (
                        <>
                          <div
                            className="fixed inset-0 z-10"
                            onClick={(e) => {
                              e.stopPropagation();
                              setOpenMenuId(null);
                            }}
                          />
                          <div className="absolute right-0 top-full mt-1 bg-white border border-secondary-200 rounded-lg shadow-lg z-20 py-1 min-w-[160px]">
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                setOpenMenuId(null);
                                onViewSecret(secret);
                              }}
                              className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                            >
                              <Eye className="w-4 h-4" />
                              View
                            </button>
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                setOpenMenuId(null);
                                onEditSecret(secret);
                              }}
                              className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                            >
                              <Edit2 className="w-4 h-4" />
                              Edit
                            </button>
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                setOpenMenuId(null);
                                onShareSecret(secret);
                              }}
                              className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                            >
                              <Share2 className="w-4 h-4" />
                              Share
                            </button>
                            {secret.metadata?.url && (
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  setOpenMenuId(null);
                                  handleOpenUrl(secret);
                                }}
                                className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                              >
                                <ExternalLink className="w-4 h-4" />
                                Open URL
                              </button>
                            )}
                            <hr className="my-1 border-secondary-200" />
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                setOpenMenuId(null);
                                onDeleteSecret(secret);
                              }}
                              className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 text-error-600 flex items-center gap-2"
                            >
                              <Trash2 className="w-4 h-4" />
                              Delete
                            </button>
                          </div>
                        </>
                      )}
                    </div>
                  </div>
                </Card>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
};

export default SecretList;
