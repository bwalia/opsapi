'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Plus,
  Edit,
  Trash2,
  Eye,
  GripVertical,
  Clock,
  RefreshCw,
} from 'lucide-react';
import { Table, Badge, Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  academyService,
  getCourseStatusVariant,
  type AcademyCourse,
  type AcademyLesson,
} from '@/services/academy.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

function formatSeconds(s?: number): string {
  if (!s || s <= 0) return '—';
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return `${m}:${sec.toString().padStart(2, '0')}`;
}

function CourseDetail() {
  const params = useParams();
  const router = useRouter();
  const uuid = params?.uuid as string;
  const { canCreate, canUpdate, canDelete } = usePermissions();

  const [course, setCourse] = useState<AcademyCourse | null>(null);
  const [lessons, setLessons] = useState<AcademyLesson[]>([]);
  const [loading, setLoading] = useState(true);
  const [deleteTarget, setDeleteTarget] = useState<AcademyLesson | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    if (!uuid) return;
    setLoading(true);
    try {
      const res = await academyService.getCourse(uuid);
      setCourse(res.course);
      setLessons(Array.isArray(res.lessons) ? res.lessons : []);
    } catch (err) {
      console.error('Load course failed:', err);
      toast.error('Failed to load course');
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await academyService.deleteLesson(deleteTarget.uuid);
      toast.success('Lesson deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      console.error('Delete lesson failed:', err);
      toast.error('Failed to delete lesson');
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<AcademyLesson>[] = [
    {
      key: 'position',
      header: '#',
      width: '60px',
      render: (l) => (
        <span className="inline-flex items-center gap-1 text-secondary-400">
          <GripVertical size={14} /> {l.position ?? '—'}
        </span>
      ),
    },
    {
      key: 'title',
      header: 'Lesson',
      render: (l) => (
        <div className="min-w-0">
          <p className="font-medium text-secondary-900 truncate">{l.title}</p>
          {l.description && <p className="text-xs text-secondary-500 truncate">{l.description}</p>}
        </div>
      ),
    },
    {
      key: 'duration_seconds',
      header: 'Duration',
      render: (l) => (
        <span className="inline-flex items-center gap-1 text-sm text-secondary-600">
          <Clock size={14} /> {formatSeconds(l.duration_seconds)}
        </span>
      ),
    },
    {
      key: 'is_preview',
      header: 'Preview',
      render: (l) => (l.is_preview ? <Badge variant="info">Preview</Badge> : <span className="text-secondary-400">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (l) => <Badge variant={l.status === 'published' ? 'success' : 'warning'} className="capitalize">{l.status}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (l) => (
        <div className="flex items-center justify-end gap-1" onClick={(e) => e.stopPropagation()}>
          {canUpdate('courses') && (
            <button title="Edit content" onClick={() => router.push(`/dashboard/academy/${uuid}/lessons/${l.uuid}`)} className="p-1.5 rounded-md text-secondary-500 hover:bg-secondary-100 hover:text-secondary-900">
              <Edit size={16} />
            </button>
          )}
          {canDelete('courses') && (
            <button title="Delete" onClick={() => setDeleteTarget(l)} className="p-1.5 rounded-md text-secondary-500 hover:bg-error-50 hover:text-error-600">
              <Trash2 size={16} />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <button onClick={() => router.push('/dashboard/academy')} className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-900">
        <ArrowLeft size={16} /> Back to courses
      </button>

      {/* Course header */}
      <div className="bg-surface rounded-xl border border-secondary-200 p-5">
        {loading && !course ? (
          <div className="animate-pulse h-16 bg-secondary-100 rounded" />
        ) : course ? (
          <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div className="min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <h1 className="text-xl font-bold text-secondary-900">{course.title}</h1>
                <Badge variant={getCourseStatusVariant(course.status)} className="capitalize">{course.status}</Badge>
                {course.is_free ? <Badge variant="success">Free</Badge> : <Badge variant="secondary">{course.currency} {course.price}</Badge>}
              </div>
              {course.description && <p className="text-sm text-secondary-600 mt-1.5 max-w-2xl">{course.description}</p>}
              <p className="text-xs text-secondary-400 mt-2">
                {course.instructor ? `By ${course.instructor} · ` : ''}{lessons.length} lesson{lessons.length === 1 ? '' : 's'} · Updated {formatDate(course.updated_at)}
              </p>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <Button variant="outline" leftIcon={<RefreshCw size={16} />} onClick={load}>Refresh</Button>
              {canCreate('courses') && (
                <Button leftIcon={<Plus size={16} />} onClick={() => router.push(`/dashboard/academy/${uuid}/lessons/new`)}>Add Lesson</Button>
              )}
            </div>
          </div>
        ) : (
          <p className="text-secondary-500">Course not found.</p>
        )}
      </div>

      {/* Lessons */}
      <div className="bg-surface rounded-xl border border-secondary-200 overflow-hidden">
        <div className="px-5 py-3 border-b border-secondary-200 flex items-center gap-2">
          <Eye size={16} className="text-secondary-400" />
          <h2 className="text-sm font-semibold text-secondary-800">Lessons</h2>
        </div>
        <Table
          columns={columns}
          data={lessons}
          keyExtractor={(l) => l.uuid}
          isLoading={loading}
          emptyMessage="No lessons yet. Add your first lesson and start authoring content."
          onRowClick={(l) => router.push(`/dashboard/academy/${uuid}/lessons/${l.uuid}`)}
        />
      </div>

      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={handleDelete}
        title="Delete lesson"
        message={`Delete "${deleteTarget?.title}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function CourseDetailPage() {
  return (
    <ProtectedPage module="courses" action="read" title="Academy">
      <CourseDetail />
    </ProtectedPage>
  );
}
