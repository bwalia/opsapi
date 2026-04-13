'use client';

import React, { useState, useEffect } from 'react';
import {
  Key,
  FileText,
  CreditCard,
  Globe,
  Shield,
  Eye,
  EyeOff,
  Plus,
  X,
  RefreshCw,
} from 'lucide-react';
import { Button, Input, Textarea, Select, Modal } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultSecret, VaultSecretType, VaultFolder, CreateVaultSecretDto, UpdateVaultSecretDto } from '@/types';
import toast from 'react-hot-toast';
import { cn } from '@/lib/utils';

interface AddSecretModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: () => void;
  folders: VaultFolder[];
  editSecret?: VaultSecret | null;
  defaultFolderId?: string | null;
}

const SECRET_TYPES: { value: VaultSecretType; label: string; icon: React.ElementType }[] = [
  { value: 'password', label: 'Password', icon: Key },
  { value: 'api_key', label: 'API Key', icon: Shield },
  { value: 'credential', label: 'Credential', icon: CreditCard },
  { value: 'note', label: 'Secure Note', icon: FileText },
  { value: 'other', label: 'Other', icon: Globe },
];

const generatePassword = (length: number = 16): string => {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*';
  let password = '';
  for (let i = 0; i < length; i++) {
    password += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return password;
};

const AddSecretModal: React.FC<AddSecretModalProps> = ({
  isOpen,
  onClose,
  onSuccess,
  folders,
  editSecret,
  defaultFolderId,
}) => {
  const [secretType, setSecretType] = useState<VaultSecretType>('password');
  const [name, setName] = useState('');
  const [value, setValue] = useState('');
  const [description, setDescription] = useState('');
  const [folderId, setFolderId] = useState<string>('');
  const [showValue, setShowValue] = useState(false);
  const [tags, setTags] = useState<string[]>([]);
  const [tagInput, setTagInput] = useState('');
  const [url, setUrl] = useState('');
  const [username, setUsername] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingSecret, setIsLoadingSecret] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});

  const isEditing = !!editSecret;

  // Reset form when modal opens/closes
  useEffect(() => {
    if (isOpen) {
      if (editSecret) {
        setSecretType(editSecret.secret_type);
        setName(editSecret.name);
        setDescription(editSecret.description || '');
        setFolderId(editSecret.folder_id ?? '');
        setTags(editSecret.tags || []);
        setUrl(editSecret.metadata?.url ?? '');
        setUsername(editSecret.metadata?.username ?? '');
        // Load the actual secret value
        loadSecretValue(editSecret.id);
      } else {
        setSecretType('password');
        setName('');
        setValue('');
        setDescription('');
        setFolderId(defaultFolderId ?? '');
        setTags([]);
        setTagInput('');
        setUrl('');
        setUsername('');
      }
      setShowValue(false);
      setErrors({});
    }
  }, [isOpen, editSecret, defaultFolderId]);

  const loadSecretValue = async (secretId: string) => {
    setIsLoadingSecret(true);
    try {
      const fullSecret = await vaultService.readSecret(secretId);
      setValue(fullSecret.value || '');
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to load secret value');
    } finally {
      setIsLoadingSecret(false);
    }
  };

  const validate = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!name.trim()) {
      newErrors.name = 'Name is required';
    }

    if (!value.trim() && secretType !== 'note') {
      newErrors.value = 'Value is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async () => {
    if (!validate()) return;

    setIsLoading(true);
    try {
      const metadata: Record<string, string> = {};
      if (url) metadata.url = url;
      if (username) metadata.username = username;

      if (isEditing && editSecret) {
        const updateData: UpdateVaultSecretDto = {
          name: name.trim(),
          value: value.trim(),
          description: description.trim() || undefined,
          folder_id: folderId || undefined,
          secret_type: secretType,
          tags: tags.length > 0 ? tags : undefined,
          metadata: Object.keys(metadata).length > 0 ? metadata : undefined,
        };

        await vaultService.updateSecret(editSecret.id, updateData);
        toast.success('Secret updated successfully');
      } else {
        const createData: CreateVaultSecretDto = {
          name: name.trim(),
          value: value.trim(),
          description: description.trim() || undefined,
          folder_id: folderId || undefined,
          secret_type: secretType,
          tags: tags.length > 0 ? tags : undefined,
          metadata: Object.keys(metadata).length > 0 ? metadata : undefined,
        };

        await vaultService.createSecret(createData);
        toast.success('Secret created successfully');
      }

      onSuccess();
      onClose();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || `Failed to ${isEditing ? 'update' : 'create'} secret`);
    } finally {
      setIsLoading(false);
    }
  };

  const handleAddTag = () => {
    const tag = tagInput.trim().toLowerCase();
    if (tag && !tags.includes(tag)) {
      setTags([...tags, tag]);
      setTagInput('');
    }
  };

  const handleRemoveTag = (tagToRemove: string) => {
    setTags(tags.filter((t) => t !== tagToRemove));
  };

  const handleTagKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleAddTag();
    }
  };

  const getFolderOptions = () => {
    const buildOptions = (
      parentId: string | null = null,
      depth: number = 0
    ): { value: string; label: string }[] => {
      const children = folders.filter((f) => {
        // Handle both null and undefined as "no parent"
        const folderParentId = f.parent_id ?? null;
        return folderParentId === parentId;
      });
      let options: { value: string; label: string }[] = [];

      for (const folder of children) {
        const prefix = '\u00A0\u00A0'.repeat(depth);
        options.push({
          value: folder.id,
          label: `${prefix}${folder.icon || '📁'} ${folder.name}`,
        });
        options = options.concat(buildOptions(folder.id, depth + 1));
      }

      return options;
    };

    return [{ value: '', label: 'No folder (root)' }, ...buildOptions()];
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditing ? 'Edit Secret' : 'Add Secret'}
      size="lg"
    >
      <div className="space-y-4">
        {/* Secret Type Selection */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-2">
            Secret Type
          </label>
          <div className="grid grid-cols-5 gap-2">
            {SECRET_TYPES.map((type) => {
              const Icon = type.icon;
              return (
                <button
                  key={type.value}
                  type="button"
                  onClick={() => setSecretType(type.value)}
                  className={cn(
                    'flex flex-col items-center gap-1 p-3 rounded-lg border-2 transition-colors',
                    secretType === type.value
                      ? 'border-primary-500 bg-primary-50'
                      : 'border-secondary-200 hover:border-secondary-300'
                  )}
                >
                  <Icon
                    className={cn(
                      'w-5 h-5',
                      secretType === type.value
                        ? 'text-primary-600'
                        : 'text-secondary-400'
                    )}
                  />
                  <span
                    className={cn(
                      'text-xs',
                      secretType === type.value
                        ? 'text-primary-700 font-medium'
                        : 'text-secondary-500'
                    )}
                  >
                    {type.label}
                  </span>
                </button>
              );
            })}
          </div>
        </div>

        {/* Name */}
        <Input
          label="Name"
          value={name}
          onChange={(e) => {
            setName(e.target.value);
            setErrors((prev) => ({ ...prev, name: '' }));
          }}
          placeholder="e.g., GitHub Personal Access Token"
          error={errors.name}
        />

        {/* Value */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="block text-sm font-medium text-secondary-700">
              {secretType === 'note' ? 'Note Content' : 'Secret Value'}
            </label>
            {secretType === 'password' && (
              <button
                type="button"
                onClick={() => setValue(generatePassword())}
                className="text-xs text-primary-600 hover:text-primary-700 flex items-center gap-1"
              >
                <RefreshCw className="w-3 h-3" />
                Generate
              </button>
            )}
          </div>
          {isLoadingSecret ? (
            <div className="h-10 flex items-center justify-center bg-secondary-50 rounded-lg border border-secondary-200">
              <span className="text-sm text-secondary-500">Loading secret value...</span>
            </div>
          ) : secretType === 'note' ? (
            <Textarea
              value={value}
              onChange={(e) => {
                setValue(e.target.value);
                setErrors((prev) => ({ ...prev, value: '' }));
              }}
              placeholder="Enter your secure note..."
              rows={4}
              error={errors.value}
            />
          ) : (
            <Input
              type={showValue ? 'text' : 'password'}
              value={value}
              onChange={(e) => {
                setValue(e.target.value);
                setErrors((prev) => ({ ...prev, value: '' }));
              }}
              placeholder="Enter secret value"
              error={errors.value}
              rightIcon={
                <button
                  type="button"
                  onClick={() => setShowValue(!showValue)}
                  className="focus:outline-none"
                >
                  {showValue ? (
                    <EyeOff className="w-4 h-4" />
                  ) : (
                    <Eye className="w-4 h-4" />
                  )}
                </button>
              }
            />
          )}
        </div>

        {/* URL (for password/credential types) */}
        {(secretType === 'password' || secretType === 'credential') && (
          <Input
            label="URL (optional)"
            type="url"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://example.com/login"
          />
        )}

        {/* Username (for password/credential types) */}
        {(secretType === 'password' || secretType === 'credential') && (
          <Input
            label="Username (optional)"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="your_username"
          />
        )}

        {/* Description */}
        <Textarea
          label="Description (optional)"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Add notes about this secret..."
          rows={2}
        />

        {/* Folder */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">
            Folder
          </label>
          <Select
            value={folderId}
            onChange={(e) => setFolderId(e.target.value)}
          >
            {getFolderOptions().map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </div>

        {/* Tags */}
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">
            Tags (optional)
          </label>
          <div className="flex flex-wrap gap-2 mb-2">
            {tags.map((tag) => (
              <span
                key={tag}
                className="inline-flex items-center gap-1 px-2 py-1 bg-secondary-100 text-secondary-700 rounded-full text-sm"
              >
                {tag}
                <button
                  type="button"
                  onClick={() => handleRemoveTag(tag)}
                  className="p-0.5 hover:bg-secondary-200 rounded-full"
                >
                  <X className="w-3 h-3" />
                </button>
              </span>
            ))}
          </div>
          <div className="flex gap-2">
            <Input
              value={tagInput}
              onChange={(e) => setTagInput(e.target.value)}
              onKeyDown={handleTagKeyDown}
              placeholder="Add a tag..."
              className="flex-1"
            />
            <Button
              type="button"
              variant="ghost"
              onClick={handleAddTag}
              disabled={!tagInput.trim()}
            >
              <Plus className="w-4 h-4" />
            </Button>
          </div>
        </div>

        {/* Actions */}
        <div className="flex gap-3 pt-4 border-t border-secondary-200">
          <Button variant="ghost" onClick={onClose} className="flex-1">
            Cancel
          </Button>
          <Button
            onClick={handleSubmit}
            isLoading={isLoading}
            className="flex-1"
          >
            {isEditing ? 'Update Secret' : 'Add Secret'}
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default AddSecretModal;
