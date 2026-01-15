'use client';

import React, { useState } from 'react';
import {
  Folder,
  FolderOpen,
  ChevronRight,
  ChevronDown,
  Plus,
  MoreVertical,
  Edit2,
  Trash2,
  FolderPlus,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button, Input, Modal } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultFolder } from '@/types';
import toast from 'react-hot-toast';

interface FolderTreeProps {
  folders: VaultFolder[];
  selectedFolderId: string | null;
  onSelectFolder: (folderId: string | null) => void;
  onFoldersChange: () => void;
}

interface FolderNodeProps {
  folder: VaultFolder;
  folders: VaultFolder[];
  depth: number;
  selectedFolderId: string | null;
  onSelectFolder: (folderId: string | null) => void;
  onEdit: (folder: VaultFolder) => void;
  onDelete: (folder: VaultFolder) => void;
  onAddSubfolder: (parentId: string) => void;
}

const FolderNode: React.FC<FolderNodeProps> = ({
  folder,
  folders,
  depth,
  selectedFolderId,
  onSelectFolder,
  onEdit,
  onDelete,
  onAddSubfolder,
}) => {
  const [isExpanded, setIsExpanded] = useState(true);
  const [showMenu, setShowMenu] = useState(false);
  const children = folders.filter((f) => f.parent_id === folder.id);
  const hasChildren = children.length > 0;
  const isSelected = selectedFolderId === folder.id;

  const getIcon = () => {
    const iconClasses = cn(
      'w-4 h-4 flex-shrink-0',
      folder.icon ? '' : isSelected ? 'text-primary-600' : 'text-secondary-500'
    );

    if (folder.icon) {
      return <span className="text-sm">{folder.icon}</span>;
    }

    return isExpanded && hasChildren ? (
      <FolderOpen className={iconClasses} />
    ) : (
      <Folder className={iconClasses} />
    );
  };

  return (
    <div>
      <div
        className={cn(
          'group flex items-center gap-1 px-2 py-1.5 rounded-lg cursor-pointer transition-colors',
          isSelected ? 'bg-primary-100 text-primary-700' : 'hover:bg-secondary-100'
        )}
        style={{ paddingLeft: `${depth * 16 + 8}px` }}
        onClick={() => onSelectFolder(folder.id)}
      >
        {hasChildren ? (
          <button
            onClick={(e) => {
              e.stopPropagation();
              setIsExpanded(!isExpanded);
            }}
            className="p-0.5 hover:bg-secondary-200 rounded"
          >
            {isExpanded ? (
              <ChevronDown className="w-3.5 h-3.5 text-secondary-500" />
            ) : (
              <ChevronRight className="w-3.5 h-3.5 text-secondary-500" />
            )}
          </button>
        ) : (
          <span className="w-4" />
        )}

        {getIcon()}

        <span
          className={cn(
            'flex-1 text-sm truncate',
            isSelected ? 'font-medium' : ''
          )}
        >
          {folder.name}
        </span>

        {folder.secret_count !== undefined && folder.secret_count > 0 && (
          <span className="text-xs text-secondary-400 mr-1">
            {folder.secret_count}
          </span>
        )}

        <div className="relative">
          <button
            onClick={(e) => {
              e.stopPropagation();
              setShowMenu(!showMenu);
            }}
            className="p-1 opacity-0 group-hover:opacity-100 hover:bg-secondary-200 rounded transition-opacity"
          >
            <MoreVertical className="w-3.5 h-3.5 text-secondary-500" />
          </button>

          {showMenu && (
            <>
              <div
                className="fixed inset-0 z-10"
                onClick={(e) => {
                  e.stopPropagation();
                  setShowMenu(false);
                }}
              />
              <div className="absolute right-0 top-full mt-1 bg-white border border-secondary-200 rounded-lg shadow-lg z-20 py-1 min-w-[140px]">
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setShowMenu(false);
                    onAddSubfolder(folder.id);
                  }}
                  className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                >
                  <FolderPlus className="w-4 h-4" />
                  Add Subfolder
                </button>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setShowMenu(false);
                    onEdit(folder);
                  }}
                  className="w-full px-3 py-2 text-sm text-left hover:bg-secondary-50 flex items-center gap-2"
                >
                  <Edit2 className="w-4 h-4" />
                  Rename
                </button>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setShowMenu(false);
                    onDelete(folder);
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

      {isExpanded && hasChildren && (
        <div>
          {children.map((child) => (
            <FolderNode
              key={child.id}
              folder={child}
              folders={folders}
              depth={depth + 1}
              selectedFolderId={selectedFolderId}
              onSelectFolder={onSelectFolder}
              onEdit={onEdit}
              onDelete={onDelete}
              onAddSubfolder={onAddSubfolder}
            />
          ))}
        </div>
      )}
    </div>
  );
};

const FolderTree: React.FC<FolderTreeProps> = ({
  folders,
  selectedFolderId,
  onSelectFolder,
  onFoldersChange,
}) => {
  const [isAddModalOpen, setIsAddModalOpen] = useState(false);
  const [isEditModalOpen, setIsEditModalOpen] = useState(false);
  const [isDeleteModalOpen, setIsDeleteModalOpen] = useState(false);
  const [selectedFolder, setSelectedFolder] = useState<VaultFolder | null>(null);
  const [parentId, setParentId] = useState<string | null>(null);
  const [folderName, setFolderName] = useState('');
  const [folderIcon, setFolderIcon] = useState('');
  const [isLoading, setIsLoading] = useState(false);

  const rootFolders = folders.filter((f) => !f.parent_id);

  const handleAddFolder = async () => {
    if (!folderName.trim()) {
      toast.error('Folder name is required');
      return;
    }

    setIsLoading(true);
    try {
      await vaultService.createFolder({
        name: folderName.trim(),
        parent_id: parentId || undefined,
        icon: folderIcon || undefined,
      });
      toast.success('Folder created successfully');
      setIsAddModalOpen(false);
      setFolderName('');
      setFolderIcon('');
      setParentId(null);
      onFoldersChange();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to create folder');
    } finally {
      setIsLoading(false);
    }
  };

  const handleEditFolder = async () => {
    if (!selectedFolder || !folderName.trim()) {
      toast.error('Folder name is required');
      return;
    }

    setIsLoading(true);
    try {
      await vaultService.updateFolder(selectedFolder.id, {
        name: folderName.trim(),
        icon: folderIcon || undefined,
      });
      toast.success('Folder updated successfully');
      setIsEditModalOpen(false);
      setSelectedFolder(null);
      setFolderName('');
      setFolderIcon('');
      onFoldersChange();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to update folder');
    } finally {
      setIsLoading(false);
    }
  };

  const handleDeleteFolder = async () => {
    if (!selectedFolder) return;

    setIsLoading(true);
    try {
      await vaultService.deleteFolder(selectedFolder.id);
      toast.success('Folder deleted successfully');
      setIsDeleteModalOpen(false);
      setSelectedFolder(null);
      if (selectedFolderId === selectedFolder.id) {
        onSelectFolder(null);
      }
      onFoldersChange();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to delete folder');
    } finally {
      setIsLoading(false);
    }
  };

  const openEditModal = (folder: VaultFolder) => {
    setSelectedFolder(folder);
    setFolderName(folder.name);
    setFolderIcon(folder.icon || '');
    setIsEditModalOpen(true);
  };

  const openDeleteModal = (folder: VaultFolder) => {
    setSelectedFolder(folder);
    setIsDeleteModalOpen(true);
  };

  const openAddSubfolderModal = (parentFolderId: string) => {
    setParentId(parentFolderId);
    setFolderName('');
    setFolderIcon('');
    setIsAddModalOpen(true);
  };

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center justify-between px-3 py-2 border-b border-secondary-200">
        <span className="text-xs font-semibold text-secondary-500 uppercase tracking-wider">
          Folders
        </span>
        <button
          onClick={() => {
            setParentId(null);
            setFolderName('');
            setFolderIcon('');
            setIsAddModalOpen(true);
          }}
          className="p-1 hover:bg-secondary-100 rounded transition-colors"
          title="Add folder"
        >
          <Plus className="w-4 h-4 text-secondary-500" />
        </button>
      </div>

      <div className="flex-1 overflow-y-auto py-2">
        {/* All Secrets option */}
        <div
          className={cn(
            'flex items-center gap-2 px-3 py-1.5 mx-2 rounded-lg cursor-pointer transition-colors',
            selectedFolderId === null
              ? 'bg-primary-100 text-primary-700'
              : 'hover:bg-secondary-100'
          )}
          onClick={() => onSelectFolder(null)}
        >
          <Folder
            className={cn(
              'w-4 h-4',
              selectedFolderId === null ? 'text-primary-600' : 'text-secondary-500'
            )}
          />
          <span
            className={cn(
              'text-sm',
              selectedFolderId === null ? 'font-medium' : ''
            )}
          >
            All Secrets
          </span>
        </div>

        {/* Folder tree */}
        <div className="mt-1 px-2">
          {rootFolders.map((folder) => (
            <FolderNode
              key={folder.id}
              folder={folder}
              folders={folders}
              depth={0}
              selectedFolderId={selectedFolderId}
              onSelectFolder={onSelectFolder}
              onEdit={openEditModal}
              onDelete={openDeleteModal}
              onAddSubfolder={openAddSubfolderModal}
            />
          ))}
        </div>

        {folders.length === 0 && (
          <div className="px-3 py-4 text-center">
            <p className="text-sm text-secondary-500">No folders yet</p>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setIsAddModalOpen(true)}
              className="mt-2"
            >
              <Plus className="w-4 h-4 mr-1" />
              Create folder
            </Button>
          </div>
        )}
      </div>

      {/* Add Folder Modal */}
      <Modal
        isOpen={isAddModalOpen}
        onClose={() => setIsAddModalOpen(false)}
        title={parentId ? 'Add Subfolder' : 'Add Folder'}
        size="sm"
      >
        <div className="space-y-4">
          <Input
            label="Folder Name"
            value={folderName}
            onChange={(e) => setFolderName(e.target.value)}
            placeholder="Enter folder name"
            autoFocus
          />
          <Input
            label="Icon (optional)"
            value={folderIcon}
            onChange={(e) => setFolderIcon(e.target.value)}
            placeholder="Emoji or icon"
            maxLength={4}
          />
          <div className="flex gap-3">
            <Button
              variant="ghost"
              onClick={() => setIsAddModalOpen(false)}
              className="flex-1"
            >
              Cancel
            </Button>
            <Button
              onClick={handleAddFolder}
              isLoading={isLoading}
              className="flex-1"
            >
              Create
            </Button>
          </div>
        </div>
      </Modal>

      {/* Edit Folder Modal */}
      <Modal
        isOpen={isEditModalOpen}
        onClose={() => setIsEditModalOpen(false)}
        title="Rename Folder"
        size="sm"
      >
        <div className="space-y-4">
          <Input
            label="Folder Name"
            value={folderName}
            onChange={(e) => setFolderName(e.target.value)}
            placeholder="Enter folder name"
            autoFocus
          />
          <Input
            label="Icon (optional)"
            value={folderIcon}
            onChange={(e) => setFolderIcon(e.target.value)}
            placeholder="Emoji or icon"
            maxLength={4}
          />
          <div className="flex gap-3">
            <Button
              variant="ghost"
              onClick={() => setIsEditModalOpen(false)}
              className="flex-1"
            >
              Cancel
            </Button>
            <Button
              onClick={handleEditFolder}
              isLoading={isLoading}
              className="flex-1"
            >
              Save
            </Button>
          </div>
        </div>
      </Modal>

      {/* Delete Confirmation Modal */}
      <Modal
        isOpen={isDeleteModalOpen}
        onClose={() => setIsDeleteModalOpen(false)}
        title="Delete Folder"
        size="sm"
      >
        <div className="space-y-4">
          <p className="text-secondary-600">
            Are you sure you want to delete the folder &quot;{selectedFolder?.name}&quot;?
            {folders.some((f) => f.parent_id === selectedFolder?.id) && (
              <span className="block mt-2 text-warning-600">
                This folder contains subfolders that will also be deleted.
              </span>
            )}
          </p>
          <div className="flex gap-3">
            <Button
              variant="ghost"
              onClick={() => setIsDeleteModalOpen(false)}
              className="flex-1"
            >
              Cancel
            </Button>
            <Button
              variant="danger"
              onClick={handleDeleteFolder}
              isLoading={isLoading}
              className="flex-1"
            >
              Delete
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
};

export default FolderTree;
