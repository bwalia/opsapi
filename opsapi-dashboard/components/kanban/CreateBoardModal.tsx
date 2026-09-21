'use client';

import React, { memo, useState } from 'react';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';
import type { CreateKanbanBoardDto } from '@/types';

export interface CreateBoardModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: CreateKanbanBoardDto) => Promise<void>;
  isLoading?: boolean;
}

/**
 * Create a new board within a project. The backend endpoint already exists
 * (POST /kanban/projects/:uuid/boards); this replaces the old "coming soon"
 * stub. New boards are seeded with the default columns.
 */
const CreateBoardModal = memo(function CreateBoardModal({
  isOpen,
  onClose,
  onSubmit,
  isLoading,
}: CreateBoardModalProps) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');

  const reset = () => {
    setName('');
    setDescription('');
    setError('');
  };

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      setError('Board name is required');
      return;
    }
    await onSubmit({
      name: name.trim(),
      description: description.trim() || undefined,
      create_default_columns: true,
    });
    reset();
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Create New Board" size="md">
      <form onSubmit={handleSubmit} className="space-y-5">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">
            Board Name <span className="text-red-500">*</span>
          </label>
          <Input
            name="name"
            value={name}
            onChange={(e) => {
              setName(e.target.value);
              if (error) setError('');
            }}
            placeholder="e.g. Sprint 2, Bugs, Roadmap"
            className={error ? 'border-red-500' : ''}
            disabled={isLoading}
            autoFocus
          />
          {error && <p className="mt-1 text-sm text-red-500">{error}</p>}
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
          <textarea
            name="description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="What's this board for?"
            className="w-full px-4 py-2 border border-secondary-300 rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500"
            rows={3}
            disabled={isLoading}
          />
        </div>

        <p className="text-xs text-secondary-500">
          The board starts with the default columns (Backlog, To Do, In Progress, Review, Done).
        </p>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button type="button" variant="outline" onClick={handleClose} disabled={isLoading}>
            Cancel
          </Button>
          <Button type="submit" isLoading={isLoading} disabled={!name.trim()}>
            Create Board
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default CreateBoardModal;
