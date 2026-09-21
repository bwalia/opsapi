'use client';

import React, { useEffect, useState, useCallback, useMemo } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Plus,
  Layers,
  RefreshCw,
  Pencil,
  Trash2,
  Calendar,
  ChevronRight,
  Loader2,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import Input from '@/components/ui/Input';
import Textarea from '@/components/ui/Textarea';
import Modal from '@/components/ui/Modal';
import { useKanbanStore } from '@/store/kanban.store';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  epicService,
  getEpicStatusColor,
  getEpicStatusLabel,
} from '@/services/epic.service';
import type {
  KanbanEpic,
  KanbanEpicStatus,
  CreateKanbanEpicDto,
} from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Constants
// ============================================

const EPIC_STATUSES: KanbanEpicStatus[] = ['open', 'in_progress', 'done', 'cancelled'];

const DEFAULT_EPIC_COLOR = '#7C3AED';

const EPIC_COLORS = [
  '#7C3AED', // violet
  '#2563EB', // blue
  '#059669', // emerald
  '#D97706', // amber
  '#DC2626', // red
  '#DB2777', // pink
  '#0891B2', // cyan
  '#4B5563', // slate
];

// ============================================
// Epic Form Modal
// ============================================

interface EpicFormValues {
  name: string;
  description: string;
  status: KanbanEpicStatus;
  color: string;
  start_date: string;
  due_date: string;
}

const EMPTY_FORM: EpicFormValues = {
  name: '',
  description: '',
  status: 'open',
  color: DEFAULT_EPIC_COLOR,
  start_date: '',
  due_date: '',
};

function toFormValues(epic: KanbanEpic): EpicFormValues {
  return {
    name: epic.name,
    description: epic.description || '',
    status: epic.status,
    color: epic.color || DEFAULT_EPIC_COLOR,
    // The API returns dates as YYYY-MM-DD; <input type="date"> wants exactly that.
    start_date: epic.start_date?.slice(0, 10) || '',
    due_date: epic.due_date?.slice(0, 10) || '',
  };
}

interface EpicFormModalProps {
  onClose: () => void;
  /** Present when editing, absent when creating. */
  epic?: KanbanEpic | null;
  onSubmit: (values: CreateKanbanEpicDto) => Promise<void>;
  isSubmitting: boolean;
}

/**
 * Mounted only while open (see the call site), so the form seeds itself from
 * `epic` on mount — no effect syncing props into state, and every open starts
 * from the saved values rather than whatever was typed last time.
 */
function EpicFormModal({ onClose, epic, onSubmit, isSubmitting }: EpicFormModalProps) {
  const [values, setValues] = useState<EpicFormValues>(() =>
    epic ? toFormValues(epic) : EMPTY_FORM
  );
  const [error, setError] = useState<string | null>(null);

  const set = <K extends keyof EpicFormValues>(key: K, value: EpicFormValues[K]) =>
    setValues((prev) => ({ ...prev, [key]: value }));

  const handleSubmit = async () => {
    const name = values.name.trim();
    if (!name) {
      setError('Name is required');
      return;
    }
    if (values.start_date && values.due_date && values.due_date < values.start_date) {
      setError('Due date cannot be before the start date');
      return;
    }

    setError(null);
    await onSubmit({
      name,
      description: values.description.trim() || undefined,
      status: values.status,
      color: values.color,
      start_date: values.start_date || undefined,
      due_date: values.due_date || undefined,
    });
  };

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={epic ? 'Edit epic' : 'New epic'}
      size="lg"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" size="sm" onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button variant="primary" size="sm" onClick={handleSubmit} disabled={isSubmitting}>
            {isSubmitting && <Loader2 size={14} className="mr-1 animate-spin" />}
            {epic ? 'Save changes' : 'Create epic'}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        <Input
          label="Name"
          value={values.name}
          onChange={(e) => set('name', e.target.value)}
          placeholder="e.g. Checkout overhaul"
          error={error && !values.name.trim() ? error : undefined}
          autoFocus
        />

        <Textarea
          label="Description"
          rows={3}
          value={values.description}
          onChange={(e) => set('description', e.target.value)}
          placeholder="What does this epic cover?"
        />

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Start date"
            type="date"
            value={values.start_date}
            onChange={(e) => set('start_date', e.target.value)}
          />
          <Input
            label="Due date"
            type="date"
            value={values.due_date}
            onChange={(e) => set('due_date', e.target.value)}
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-2">Status</label>
          <div className="flex flex-wrap gap-2">
            {EPIC_STATUSES.map((status) => (
              <button
                key={status}
                type="button"
                onClick={() => set('status', status)}
                className={cn(
                  'px-3 py-1.5 text-xs font-medium rounded-full border transition-colors',
                  values.status === status
                    ? 'border-primary-500 ring-2 ring-primary-200'
                    : 'border-transparent',
                  getEpicStatusColor(status)
                )}
              >
                {getEpicStatusLabel(status)}
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-2">Colour</label>
          <div className="flex flex-wrap gap-2">
            {EPIC_COLORS.map((color) => (
              <button
                key={color}
                type="button"
                aria-label={`Colour ${color}`}
                onClick={() => set('color', color)}
                style={{ backgroundColor: color }}
                className={cn(
                  'w-7 h-7 rounded-full border-2 transition-transform',
                  values.color === color
                    ? 'border-secondary-900 scale-110'
                    : 'border-transparent hover:scale-105'
                )}
              />
            ))}
          </div>
        </div>

        {error && values.name.trim() && <p className="text-sm text-red-600">{error}</p>}
      </div>
    </Modal>
  );
}

// ============================================
// Epic Card
// ============================================

interface EpicCardProps {
  epic: KanbanEpic;
  canEdit: boolean;
  onEdit: (epic: KanbanEpic) => void;
  onDelete: (epic: KanbanEpic) => void;
  onOpenTasks: (epic: KanbanEpic) => void;
}

function EpicCard({ epic, canEdit, onEdit, onDelete, onOpenTasks }: EpicCardProps) {
  const color = epic.color || DEFAULT_EPIC_COLOR;
  const remainingPoints = Math.max(0, epic.total_points - epic.completed_points);

  return (
    <Card className="p-4 border-l-4" style={{ borderLeftColor: color }}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h3 className="font-semibold text-secondary-900 truncate">{epic.name}</h3>
            <span
              className={cn(
                'px-2 py-0.5 text-[11px] font-medium rounded-full',
                getEpicStatusColor(epic.status)
              )}
            >
              {getEpicStatusLabel(epic.status)}
            </span>
          </div>
          {epic.description && (
            <p className="text-sm text-secondary-500 mt-1 line-clamp-2">{epic.description}</p>
          )}
        </div>

        {canEdit && (
          <div className="flex items-center gap-1 shrink-0">
            <Button variant="ghost" size="sm" onClick={() => onEdit(epic)} aria-label="Edit epic">
              <Pencil size={14} />
            </Button>
            <Button variant="ghost" size="sm" onClick={() => onDelete(epic)} aria-label="Delete epic">
              <Trash2 size={14} className="text-red-500" />
            </Button>
          </div>
        )}
      </div>

      {/* Progress */}
      <div className="mt-4">
        <div className="flex items-center justify-between text-xs text-secondary-500 mb-1">
          <span>
            {epic.completed_task_count} of {epic.task_count} tasks
          </span>
          <span className="font-medium text-secondary-700">{epic.progress}%</span>
        </div>
        <div className="h-2 w-full rounded-full bg-secondary-100 overflow-hidden">
          <div
            className="h-full rounded-full transition-[width]"
            style={{ width: `${Math.min(100, epic.progress)}%`, backgroundColor: color }}
          />
        </div>
      </div>

      {/* Rollups */}
      <div className="flex items-center flex-wrap gap-x-4 gap-y-1 mt-3 text-xs text-secondary-500">
        <span>
          <span className="font-medium text-secondary-700">{epic.completed_points}</span> /{' '}
          {epic.total_points} pts
        </span>
        {remainingPoints > 0 && <span>{remainingPoints} pts remaining</span>}
        {(epic.start_date || epic.due_date) && (
          <span className="inline-flex items-center gap-1">
            <Calendar size={12} />
            {epic.start_date?.slice(0, 10) || '—'} → {epic.due_date?.slice(0, 10) || '—'}
          </span>
        )}
      </div>

      <button
        type="button"
        onClick={() => onOpenTasks(epic)}
        className="inline-flex items-center gap-1 mt-3 text-xs font-medium text-primary-600 hover:text-primary-700"
      >
        View tasks on board
        <ChevronRight size={12} />
      </button>
    </Card>
  );
}

// ============================================
// Page
// ============================================

export default function ProjectEpicsPage() {
  const params = useParams();
  const router = useRouter();
  const projectUuid = params.uuid as string;

  const { currentProject, projectLoading, loadProject } = useKanbanStore();
  const { isNamespaceOwner, isAdmin: isPlatformAdmin, canManage } = usePermissions();

  const [epics, setEpics] = useState<KanbanEpic[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<KanbanEpicStatus | 'all'>('all');
  const [isFormOpen, setIsFormOpen] = useState(false);
  const [editingEpic, setEditingEpic] = useState<KanbanEpic | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // Creating/editing epics is admin-only on the backend (isAdmin), so mirror
  // that here rather than the broader editor check the board uses.
  const projectRole = currentProject?.current_user_role;
  const canEdit =
    projectRole === 'owner' ||
    projectRole === 'admin' ||
    isNamespaceOwner ||
    isPlatformAdmin ||
    canManage('projects');

  const loadEpics = useCallback(async () => {
    if (!projectUuid) return;
    setIsLoading(true);
    try {
      const res = await epicService.getEpics(projectUuid, { perPage: 100 });
      setEpics(res.data || []);
    } catch {
      toast.error('Failed to load epics');
      setEpics([]);
    } finally {
      setIsLoading(false);
    }
  }, [projectUuid]);

  useEffect(() => {
    if (projectUuid) loadProject(projectUuid);
  }, [projectUuid, loadProject]);

  useEffect(() => {
    loadEpics();
  }, [loadEpics]);

  const visibleEpics = useMemo(
    () => (statusFilter === 'all' ? epics : epics.filter((e) => e.status === statusFilter)),
    [epics, statusFilter]
  );

  const totals = useMemo(
    () =>
      epics.reduce(
        (acc, e) => ({
          tasks: acc.tasks + e.task_count,
          points: acc.points + e.total_points,
          completedPoints: acc.completedPoints + e.completed_points,
        }),
        { tasks: 0, points: 0, completedPoints: 0 }
      ),
    [epics]
  );

  const handleCreate = () => {
    setEditingEpic(null);
    setIsFormOpen(true);
  };

  const handleEdit = (epic: KanbanEpic) => {
    setEditingEpic(epic);
    setIsFormOpen(true);
  };

  const handleSubmit = async (values: CreateKanbanEpicDto) => {
    setIsSubmitting(true);
    try {
      if (editingEpic) {
        await epicService.updateEpic(editingEpic.uuid, values);
        toast.success('Epic updated');
      } else {
        await epicService.createEpic(projectUuid, values);
        toast.success('Epic created');
      }
      setIsFormOpen(false);
      setEditingEpic(null);
      await loadEpics();
    } catch {
      toast.error(editingEpic ? 'Failed to update epic' : 'Failed to create epic');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleDelete = async (epic: KanbanEpic) => {
    const message =
      epic.task_count > 0
        ? `Delete "${epic.name}"? Its ${epic.task_count} task(s) will be detached, not deleted.`
        : `Delete "${epic.name}"?`;
    if (!window.confirm(message)) return;

    try {
      await epicService.deleteEpic(epic.uuid);
      toast.success('Epic deleted');
      await loadEpics();
    } catch {
      toast.error('Failed to delete epic');
    }
  };

  const handleOpenTasks = (epic: KanbanEpic) => {
    router.push(`/dashboard/projects/${projectUuid}?epic=${epic.id}`);
  };

  return (
    <div className="h-full flex flex-col">
      {/* Top Bar */}
      <div className="flex items-center justify-between gap-3 px-6 py-3 border-b border-secondary-200 bg-surface">
        <div className="flex items-center gap-3 min-w-0">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/projects/${projectUuid}`)}
            aria-label="Back to board"
          >
            <ArrowLeft size={18} />
          </Button>
          <div className="min-w-0">
            <h1 className="text-lg font-bold text-secondary-900 truncate">
              {currentProject?.name || 'Loading...'}
            </h1>
            <p className="text-xs text-secondary-500">Epics</p>
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <Button variant="ghost" size="sm" onClick={loadEpics} disabled={isLoading}>
            <RefreshCw size={16} className={isLoading ? 'animate-spin' : ''} />
          </Button>
          {canEdit && (
            <Button variant="primary" size="sm" onClick={handleCreate}>
              <Plus size={14} className="mr-1" />
              New Epic
            </Button>
          )}
        </div>
      </div>

      {/* Summary + filter */}
      {epics.length > 0 && (
        <div className="flex items-center justify-between gap-3 flex-wrap px-6 py-3 border-b border-secondary-200 bg-secondary-50">
          <div className="flex items-center gap-4 text-sm text-secondary-600">
            <span>
              <span className="font-semibold text-secondary-900">{epics.length}</span> epics
            </span>
            <span>
              <span className="font-semibold text-secondary-900">{totals.tasks}</span> tasks
            </span>
            <span>
              <span className="font-semibold text-secondary-900">{totals.completedPoints}</span> /{' '}
              {totals.points} pts done
            </span>
          </div>

          <div className="flex items-center gap-1 flex-wrap">
            {(['all', ...EPIC_STATUSES] as const).map((status) => (
              <button
                key={status}
                type="button"
                onClick={() => setStatusFilter(status)}
                className={cn(
                  'px-3 py-1 text-xs font-medium rounded-full transition-colors',
                  statusFilter === status
                    ? 'bg-primary-600 text-white'
                    : 'bg-surface text-secondary-600 hover:bg-secondary-100'
                )}
              >
                {status === 'all' ? 'All' : getEpicStatusLabel(status)}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Content */}
      <div className="flex-1 overflow-y-auto p-6">
        {(isLoading || projectLoading) && epics.length === 0 && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            {[0, 1, 2, 3].map((i) => (
              <Card key={i} className="p-4 animate-pulse">
                <div className="h-4 w-1/3 bg-secondary-200 rounded" />
                <div className="h-3 w-2/3 bg-secondary-100 rounded mt-3" />
                <div className="h-2 w-full bg-secondary-100 rounded mt-6" />
              </Card>
            ))}
          </div>
        )}

        {!isLoading && epics.length === 0 && (
          <div className="flex flex-col items-center justify-center h-full text-center">
            <Layers size={48} className="text-secondary-300 mb-4" />
            <h2 className="text-lg font-semibold text-secondary-900 mb-2">No epics yet</h2>
            <p className="text-sm text-secondary-500 mb-4 max-w-md">
              Epics group related tasks so you can track a larger piece of work and see its
              progress roll up in one place.
            </p>
            {canEdit && (
              <Button variant="primary" size="sm" onClick={handleCreate}>
                <Plus size={14} className="mr-1" />
                Create first epic
              </Button>
            )}
          </div>
        )}

        {!isLoading && epics.length > 0 && visibleEpics.length === 0 && (
          <p className="text-sm text-secondary-500 text-center py-12">
            No epics with this status.
          </p>
        )}

        {visibleEpics.length > 0 && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            {visibleEpics.map((epic) => (
              <EpicCard
                key={epic.uuid}
                epic={epic}
                canEdit={canEdit}
                onEdit={handleEdit}
                onDelete={handleDelete}
                onOpenTasks={handleOpenTasks}
              />
            ))}
          </div>
        )}
      </div>

      {isFormOpen && (
        <EpicFormModal
          onClose={() => {
            setIsFormOpen(false);
            setEditingEpic(null);
          }}
          epic={editingEpic}
          onSubmit={handleSubmit}
          isSubmitting={isSubmitting}
        />
      )}
    </div>
  );
}
