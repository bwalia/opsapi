'use client';

import React, { useEffect, useState, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import {
  Plus,
  Search,
  LayoutGrid,
  List,
  Star,
  FolderKanban,
  RefreshCw,
  Calendar,
  Users,
  CheckCircle2,
  Clock,
  Archive,
  Pause,
  MoreHorizontal,
  Trash2,
  Settings,
  ExternalLink,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import { CreateProjectModal } from '@/components/kanban';
import { useKanbanStore } from '@/store/kanban.store';
import type { KanbanProject, CreateKanbanProjectDto, KanbanProjectStatus } from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Status Configuration
// ============================================

const STATUS_CONFIG: Record<KanbanProjectStatus, { label: string; icon: React.ElementType; color: string; bgColor: string }> = {
  active: { label: 'Active', icon: CheckCircle2, color: 'text-green-600', bgColor: 'bg-green-50' },
  on_hold: { label: 'On Hold', icon: Pause, color: 'text-yellow-600', bgColor: 'bg-yellow-50' },
  completed: { label: 'Completed', icon: CheckCircle2, color: 'text-blue-600', bgColor: 'bg-blue-50' },
  archived: { label: 'Archived', icon: Archive, color: 'text-gray-500', bgColor: 'bg-gray-100' },
  cancelled: { label: 'Cancelled', icon: Clock, color: 'text-red-500', bgColor: 'bg-red-50' },
};

const FILTER_TABS: { value: KanbanProjectStatus | 'all' | 'starred'; label: string; icon?: React.ElementType }[] = [
  { value: 'all', label: 'All' },
  { value: 'starred', label: 'Starred', icon: Star },
  { value: 'active', label: 'Active', icon: CheckCircle2 },
  { value: 'on_hold', label: 'On Hold', icon: Pause },
  { value: 'completed', label: 'Completed', icon: CheckCircle2 },
  { value: 'archived', label: 'Archived', icon: Archive },
];

// ============================================
// Project Card Component
// ============================================

interface ProjectCardItemProps {
  project: KanbanProject;
  isStarred: boolean;
  onProjectClick: (project: KanbanProject) => void;
  onStarProject: (project: KanbanProject) => void;
  onEditProject: (project: KanbanProject) => void;
  onArchiveProject: (project: KanbanProject) => void;
  onDeleteProject: (project: KanbanProject) => void;
  viewMode: 'grid' | 'list';
}

const ProjectCardItem = React.memo(function ProjectCardItem({
  project,
  isStarred,
  onProjectClick,
  onStarProject,
  onEditProject,
  onArchiveProject,
  onDeleteProject,
  viewMode,
}: ProjectCardItemProps) {
  const [showMenu, setShowMenu] = useState(false);
  const statusConfig = STATUS_CONFIG[project.status] || STATUS_CONFIG.active;
  const StatusIcon = statusConfig.icon;

  const formatDate = (dateStr?: string) => {
    if (!dateStr) return null;
    return new Date(dateStr).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  };

  const handleCardClick = (e: React.MouseEvent) => {
    if ((e.target as HTMLElement).closest('[data-action]')) return;
    onProjectClick(project);
  };

  if (viewMode === 'list') {
    return (
      <div
        onClick={handleCardClick}
        className="group bg-white rounded-xl border border-gray-200 hover:border-primary-300 hover:shadow-md transition-all cursor-pointer"
      >
        <div className="flex items-center gap-4 p-4">
          {/* Color indicator */}
          <div
            className="w-1 h-12 rounded-full flex-shrink-0"
            style={{ backgroundColor: project.color || '#6366f1' }}
          />

          {/* Project info */}
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2">
              <h3 className="font-semibold text-gray-900 truncate">{project.name}</h3>
              <span className={cn('px-2 py-0.5 text-xs font-medium rounded-full', statusConfig.bgColor, statusConfig.color)}>
                {statusConfig.label}
              </span>
            </div>
            {project.description && (
              <p className="text-sm text-gray-500 truncate mt-1">{project.description}</p>
            )}
          </div>

          {/* Stats */}
          <div className="hidden md:flex items-center gap-6 text-sm text-gray-500">
            <div className="flex items-center gap-1.5">
              <Users size={14} />
              <span>{project.member_count || 0}</span>
            </div>
            <div className="flex items-center gap-1.5">
              <CheckCircle2 size={14} />
              <span>{project.task_count || 0} tasks</span>
            </div>
            {project.due_date && (
              <div className="flex items-center gap-1.5">
                <Calendar size={14} />
                <span>{formatDate(project.due_date)}</span>
              </div>
            )}
          </div>

          {/* Actions */}
          <div className="flex items-center gap-1" data-action="true">
            <button
              onClick={(e) => { e.stopPropagation(); onStarProject(project); }}
              className={cn(
                'p-2 rounded-lg transition-colors',
                isStarred ? 'text-yellow-500 hover:bg-yellow-50' : 'text-gray-400 hover:text-yellow-500 hover:bg-gray-50'
              )}
            >
              <Star size={18} fill={isStarred ? 'currentColor' : 'none'} />
            </button>
            <div className="relative">
              <button
                onClick={(e) => { e.stopPropagation(); setShowMenu(!showMenu); }}
                className="p-2 rounded-lg text-gray-400 hover:text-gray-600 hover:bg-gray-50 transition-colors"
              >
                <MoreHorizontal size={18} />
              </button>
              {showMenu && (
                <>
                  <div className="fixed inset-0 z-10" onClick={() => setShowMenu(false)} />
                  <div className="absolute right-0 top-full mt-1 w-48 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
                    <button
                      onClick={(e) => { e.stopPropagation(); onEditProject(project); setShowMenu(false); }}
                      className="flex items-center gap-2 w-full px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                    >
                      <Settings size={14} /> Settings
                    </button>
                    <button
                      onClick={(e) => { e.stopPropagation(); onArchiveProject(project); setShowMenu(false); }}
                      className="flex items-center gap-2 w-full px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                    >
                      <Archive size={14} /> Archive
                    </button>
                    <hr className="my-1" />
                    <button
                      onClick={(e) => { e.stopPropagation(); onDeleteProject(project); setShowMenu(false); }}
                      className="flex items-center gap-2 w-full px-3 py-2 text-sm text-red-600 hover:bg-red-50"
                    >
                      <Trash2 size={14} /> Delete
                    </button>
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    );
  }

  // Grid view
  return (
    <div
      onClick={handleCardClick}
      className="group bg-white rounded-xl border border-gray-200 hover:border-primary-300 hover:shadow-lg transition-all cursor-pointer overflow-hidden"
    >
      {/* Color header */}
      <div
        className="h-2"
        style={{ backgroundColor: project.color || '#6366f1' }}
      />

      <div className="p-5">
        {/* Header */}
        <div className="flex items-start justify-between mb-3">
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              {project.icon && <span className="text-lg">{project.icon}</span>}
              <h3 className="font-semibold text-gray-900 truncate">{project.name}</h3>
            </div>
            <span className={cn('inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full', statusConfig.bgColor, statusConfig.color)}>
              <StatusIcon size={12} />
              {statusConfig.label}
            </span>
          </div>
          <button
            onClick={(e) => { e.stopPropagation(); onStarProject(project); }}
            data-action="true"
            className={cn(
              'p-1.5 rounded-lg transition-colors',
              isStarred ? 'text-yellow-500' : 'text-gray-300 opacity-0 group-hover:opacity-100 hover:text-yellow-500'
            )}
          >
            <Star size={16} fill={isStarred ? 'currentColor' : 'none'} />
          </button>
        </div>

        {/* Description */}
        {project.description && (
          <p className="text-sm text-gray-500 line-clamp-2 mb-4">{project.description}</p>
        )}

        {/* Progress bar (if tasks exist) */}
        {project.task_count && project.task_count > 0 && (
          <div className="mb-4">
            <div className="flex items-center justify-between text-xs text-gray-500 mb-1">
              <span>Progress</span>
              <span>{project.completed_task_count || 0}/{project.task_count} tasks</span>
            </div>
            <div className="h-1.5 bg-gray-100 rounded-full overflow-hidden">
              <div
                className="h-full bg-primary-500 rounded-full transition-all"
                style={{ width: `${((project.completed_task_count || 0) / project.task_count) * 100}%` }}
              />
            </div>
          </div>
        )}

        {/* Stats row */}
        <div className="flex items-center gap-4 text-sm text-gray-500 mb-4">
          <div className="flex items-center gap-1">
            <Users size={14} />
            <span>{project.member_count || 0}</span>
          </div>
          <div className="flex items-center gap-1">
            <FolderKanban size={14} />
            <span>{project.board_count || 0} boards</span>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between pt-3 border-t border-gray-100">
          {project.due_date ? (
            <div className="flex items-center gap-1.5 text-xs text-gray-500">
              <Calendar size={12} />
              <span>Due {formatDate(project.due_date)}</span>
            </div>
          ) : (
            <div />
          )}

          {/* Actions menu */}
          <div className="relative" data-action="true">
            <button
              onClick={(e) => { e.stopPropagation(); setShowMenu(!showMenu); }}
              className="p-1.5 rounded-lg text-gray-400 hover:text-gray-600 hover:bg-gray-50 opacity-0 group-hover:opacity-100 transition-all"
            >
              <MoreHorizontal size={16} />
            </button>
            {showMenu && (
              <>
                <div className="fixed inset-0 z-10" onClick={() => setShowMenu(false)} />
                <div className="absolute right-0 bottom-full mb-1 w-48 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
                  <button
                    onClick={(e) => { e.stopPropagation(); onProjectClick(project); setShowMenu(false); }}
                    className="flex items-center gap-2 w-full px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                  >
                    <ExternalLink size={14} /> Open
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); onEditProject(project); setShowMenu(false); }}
                    className="flex items-center gap-2 w-full px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                  >
                    <Settings size={14} /> Settings
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); onArchiveProject(project); setShowMenu(false); }}
                    className="flex items-center gap-2 w-full px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                  >
                    <Archive size={14} /> Archive
                  </button>
                  <hr className="my-1" />
                  <button
                    onClick={(e) => { e.stopPropagation(); onDeleteProject(project); setShowMenu(false); }}
                    className="flex items-center gap-2 w-full px-3 py-2 text-sm text-red-600 hover:bg-red-50"
                  >
                    <Trash2 size={14} /> Delete
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
});

// ============================================
// Empty State Component
// ============================================

const EmptyState = React.memo(function EmptyState({
  onCreateProject,
  filterActive,
  onClearFilter,
  canCreate,
}: {
  onCreateProject: () => void;
  filterActive?: boolean;
  onClearFilter?: () => void;
  canCreate?: boolean;
}) {
  if (filterActive) {
    return (
      <div className="flex flex-col items-center justify-center py-16 px-4">
        <div className="w-16 h-16 mb-4 rounded-full bg-gray-100 flex items-center justify-center">
          <Search size={28} className="text-gray-400" />
        </div>
        <h3 className="text-lg font-semibold text-gray-900 mb-2">No projects found</h3>
        <p className="text-gray-500 text-center max-w-sm mb-4">
          No projects match your current filters. Try adjusting your search or filter criteria.
        </p>
        <Button variant="outline" onClick={onClearFilter}>
          Clear filters
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center justify-center py-16 px-4">
      <div className="w-20 h-20 mb-6 rounded-2xl bg-gradient-to-br from-primary-100 to-primary-50 flex items-center justify-center">
        <FolderKanban size={36} className="text-primary-600" />
      </div>
      <h3 className="text-xl font-semibold text-gray-900 mb-2">No projects yet</h3>
      <p className="text-gray-500 text-center max-w-md mb-6">
        {canCreate
          ? 'Create your first project to start organizing your work with Kanban boards, tasks, and team collaboration.'
          : 'You don\'t have any projects yet. Contact your administrator to get access.'}
      </p>
      {canCreate && (
        <Button onClick={onCreateProject} size="lg">
          <Plus size={20} className="mr-2" />
          Create your first project
        </Button>
      )}
    </div>
  );
});

// ============================================
// Loading Skeleton
// ============================================

const LoadingSkeleton = ({ viewMode }: { viewMode: 'grid' | 'list' }) => {
  if (viewMode === 'list') {
    return (
      <div className="space-y-3">
        {[1, 2, 3, 4, 5].map((i) => (
          <div key={i} className="bg-white rounded-xl border border-gray-200 p-4 animate-pulse">
            <div className="flex items-center gap-4">
              <div className="w-1 h-12 bg-gray-200 rounded-full" />
              <div className="flex-1">
                <div className="h-5 bg-gray-200 rounded w-48 mb-2" />
                <div className="h-4 bg-gray-200 rounded w-96" />
              </div>
              <div className="flex gap-4">
                <div className="h-4 bg-gray-200 rounded w-16" />
                <div className="h-4 bg-gray-200 rounded w-20" />
              </div>
            </div>
          </div>
        ))}
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
      {[1, 2, 3, 4, 5, 6, 7, 8].map((i) => (
        <div key={i} className="bg-white rounded-xl border border-gray-200 overflow-hidden animate-pulse">
          <div className="h-2 bg-gray-200" />
          <div className="p-5">
            <div className="h-5 bg-gray-200 rounded w-3/4 mb-2" />
            <div className="h-4 bg-gray-200 rounded w-20 mb-4" />
            <div className="h-4 bg-gray-200 rounded w-full mb-2" />
            <div className="h-4 bg-gray-200 rounded w-2/3 mb-4" />
            <div className="flex gap-4 mb-4">
              <div className="h-4 bg-gray-200 rounded w-12" />
              <div className="h-4 bg-gray-200 rounded w-16" />
            </div>
            <div className="h-4 bg-gray-200 rounded w-24" />
          </div>
        </div>
      ))}
    </div>
  );
};

// ============================================
// Main Projects Page Component
// ============================================

export default function ProjectsPage() {
  const router = useRouter();
  const {
    projects,
    projectsLoading,
    projectsError,
    loadProjects,
    createProject,
    updateProject,
    deleteProject,
    toggleProjectStar,
    isCreatingProject,
    projectPermissions,
  } = useKanbanStore();

  const [showCreateModal, setShowCreateModal] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [activeTab, setActiveTab] = useState<string>('all');
  const [viewMode, setViewMode] = useState<'grid' | 'list'>('grid');
  const [starredProjects, setStarredProjects] = useState<Set<string>>(new Set());

  // Load projects on mount
  useEffect(() => {
    loadProjects();
  }, [loadProjects]);

  // Initialize starred projects from API response
  useEffect(() => {
    const starred = new Set<string>();
    projects.forEach((p) => {
      if (p.is_starred) starred.add(p.uuid);
    });
    setStarredProjects(starred);
  }, [projects]);

  // Filter projects based on search and tab
  const filteredProjects = useMemo(() => {
    let filtered = projects;

    // Search filter
    if (searchQuery) {
      const query = searchQuery.toLowerCase();
      filtered = filtered.filter(
        (p) =>
          p.name.toLowerCase().includes(query) ||
          p.description?.toLowerCase().includes(query) ||
          p.slug?.toLowerCase().includes(query)
      );
    }

    // Tab filter
    if (activeTab === 'starred') {
      filtered = filtered.filter((p) => starredProjects.has(p.uuid));
    } else if (activeTab !== 'all') {
      filtered = filtered.filter((p) => p.status === activeTab);
    }

    return filtered;
  }, [projects, searchQuery, activeTab, starredProjects]);

  // Stats for header
  const stats = useMemo(() => ({
    total: projects.length,
    active: projects.filter((p) => p.status === 'active').length,
    completed: projects.filter((p) => p.status === 'completed').length,
    starred: starredProjects.size,
  }), [projects, starredProjects]);

  const handleProjectClick = useCallback((project: KanbanProject) => {
    router.push(`/dashboard/projects/${project.uuid}`);
  }, [router]);

  const handleStarProject = useCallback(async (project: KanbanProject) => {
    setStarredProjects((prev) => {
      const next = new Set(prev);
      if (next.has(project.uuid)) {
        next.delete(project.uuid);
      } else {
        next.add(project.uuid);
      }
      return next;
    });
    await toggleProjectStar(project.uuid);
  }, [toggleProjectStar]);

  const handleEditProject = useCallback((project: KanbanProject) => {
    router.push(`/dashboard/projects/${project.uuid}/settings`);
  }, [router]);

  const handleArchiveProject = useCallback(async (project: KanbanProject) => {
    if (window.confirm(`Are you sure you want to archive "${project.name}"?`)) {
      const result = await updateProject(project.uuid, { status: 'archived' });
      if (result) {
        toast.success('Project archived');
      } else {
        toast.error('Failed to archive project');
      }
    }
  }, [updateProject]);

  const handleDeleteProject = useCallback(async (project: KanbanProject) => {
    if (window.confirm(`Are you sure you want to delete "${project.name}"? This action cannot be undone.`)) {
      const success = await deleteProject(project.uuid);
      if (success) {
        toast.success('Project deleted');
      } else {
        toast.error('Failed to delete project');
      }
    }
  }, [deleteProject]);

  const handleCreateProject = useCallback(async (data: CreateKanbanProjectDto) => {
    const project = await createProject(data);
    if (project) {
      toast.success('Project created');
      setShowCreateModal(false);
      router.push(`/dashboard/projects/${project.uuid}`);
    } else {
      toast.error('Failed to create project');
    }
  }, [createProject, router]);

  const handleClearFilters = useCallback(() => {
    setSearchQuery('');
    setActiveTab('all');
  }, []);

  const isFiltered = Boolean(searchQuery) || activeTab !== 'all';

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Projects</h1>
          <p className="text-gray-500 mt-1">
            Manage your projects and track progress with Kanban boards
          </p>
        </div>
        {projectPermissions.can_create && (
          <Button onClick={() => setShowCreateModal(true)} className="w-full sm:w-auto">
            <Plus size={18} className="mr-2" />
            New Project
          </Button>
        )}
      </div>

      {/* Stats Cards - Only show when there are projects */}
      {projects.length > 0 && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <div className="text-2xl font-bold text-gray-900">{stats.total}</div>
            <div className="text-sm text-gray-500">Total Projects</div>
          </div>
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <div className="text-2xl font-bold text-green-600">{stats.active}</div>
            <div className="text-sm text-gray-500">Active</div>
          </div>
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <div className="text-2xl font-bold text-blue-600">{stats.completed}</div>
            <div className="text-sm text-gray-500">Completed</div>
          </div>
          <div className="bg-white rounded-xl border border-gray-200 p-4">
            <div className="text-2xl font-bold text-yellow-600">{stats.starred}</div>
            <div className="text-sm text-gray-500">Starred</div>
          </div>
        </div>
      )}

      {/* Filters & Controls */}
      <div className="bg-white rounded-xl border border-gray-200 p-4">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
          {/* Filter Tabs - Scrollable on mobile */}
          <div className="flex items-center gap-1 overflow-x-auto pb-2 lg:pb-0 -mx-1 px-1">
            {FILTER_TABS.map((tab) => {
              const Icon = tab.icon;
              return (
                <button
                  key={tab.value}
                  onClick={() => setActiveTab(tab.value)}
                  className={cn(
                    'flex items-center gap-1.5 px-3 py-2 text-sm font-medium rounded-lg whitespace-nowrap transition-colors',
                    activeTab === tab.value
                      ? 'bg-primary-50 text-primary-700'
                      : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'
                  )}
                >
                  {Icon && <Icon size={14} />}
                  {tab.label}
                </button>
              );
            })}
          </div>

          {/* Search & View Controls */}
          <div className="flex flex-col sm:flex-row items-stretch sm:items-center gap-3">
            {/* Search */}
            <div className="relative flex-1 sm:flex-initial">
              <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" />
              <input
                type="text"
                placeholder="Search projects..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="w-full sm:w-64 pl-9 pr-4 py-2 text-sm border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              />
            </div>

            {/* View Mode & Refresh */}
            <div className="flex items-center gap-2">
              {/* View Mode Toggle */}
              <div className="flex items-center bg-gray-100 p-1 rounded-lg">
                <button
                  onClick={() => setViewMode('grid')}
                  className={cn(
                    'p-2 rounded-md transition-colors',
                    viewMode === 'grid'
                      ? 'bg-white text-gray-900 shadow-sm'
                      : 'text-gray-500 hover:text-gray-700'
                  )}
                  title="Grid view"
                >
                  <LayoutGrid size={16} />
                </button>
                <button
                  onClick={() => setViewMode('list')}
                  className={cn(
                    'p-2 rounded-md transition-colors',
                    viewMode === 'list'
                      ? 'bg-white text-gray-900 shadow-sm'
                      : 'text-gray-500 hover:text-gray-700'
                  )}
                  title="List view"
                >
                  <List size={16} />
                </button>
              </div>

              {/* Refresh */}
              <button
                onClick={() => loadProjects()}
                disabled={projectsLoading}
                className="p-2 rounded-lg text-gray-500 hover:text-gray-700 hover:bg-gray-100 disabled:opacity-50 transition-colors"
                title="Refresh"
              >
                <RefreshCw size={16} className={cn(projectsLoading && 'animate-spin')} />
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Error State */}
      {projectsError && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-4">
          <p className="text-red-700 mb-2">{projectsError}</p>
          <Button variant="outline" size="sm" onClick={() => loadProjects()}>
            Try Again
          </Button>
        </div>
      )}

      {/* Loading State */}
      {projectsLoading && projects.length === 0 && (
        <LoadingSkeleton viewMode={viewMode} />
      )}

      {/* Empty State */}
      {!projectsLoading && projects.length === 0 && (
        <Card className="border-dashed">
          <EmptyState
            onCreateProject={() => setShowCreateModal(true)}
            canCreate={projectPermissions.can_create}
          />
        </Card>
      )}

      {/* No Results State */}
      {!projectsLoading && projects.length > 0 && filteredProjects.length === 0 && (
        <Card className="border-dashed">
          <EmptyState
            onCreateProject={() => setShowCreateModal(true)}
            filterActive={isFiltered}
            onClearFilter={handleClearFilters}
            canCreate={projectPermissions.can_create}
          />
        </Card>
      )}

      {/* Projects Grid/List */}
      {filteredProjects.length > 0 && (
        viewMode === 'list' ? (
          <div className="space-y-3">
            {filteredProjects.map((project) => (
              <ProjectCardItem
                key={project.uuid}
                project={project}
                isStarred={starredProjects.has(project.uuid)}
                onProjectClick={handleProjectClick}
                onStarProject={handleStarProject}
                onEditProject={handleEditProject}
                onArchiveProject={handleArchiveProject}
                onDeleteProject={handleDeleteProject}
                viewMode={viewMode}
              />
            ))}
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
            {filteredProjects.map((project) => (
              <ProjectCardItem
                key={project.uuid}
                project={project}
                isStarred={starredProjects.has(project.uuid)}
                onProjectClick={handleProjectClick}
                onStarProject={handleStarProject}
                onEditProject={handleEditProject}
                onArchiveProject={handleArchiveProject}
                onDeleteProject={handleDeleteProject}
                viewMode={viewMode}
              />
            ))}
          </div>
        )
      )}

      {/* Create Project Modal */}
      <CreateProjectModal
        isOpen={showCreateModal}
        onClose={() => setShowCreateModal(false)}
        onSubmit={handleCreateProject}
        isLoading={isCreatingProject}
      />
    </div>
  );
}
