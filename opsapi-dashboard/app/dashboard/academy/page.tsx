'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { Search, Plus, Trash2, Edit, BookOpen, RefreshCw, Layers, CreditCard, Banknote, GraduationCap, ArrowRight } from 'lucide-react';
import { Table, Badge, Pagination, Modal, Button, ConfirmDialog, Select } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  academyService,
  getCourseStatusVariant,
  formatCourseDuration,
  type AcademyCourse,
  type CourseInput,
  type CourseLevel,
  type CourseStatus,
} from '@/services/academy.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const PER_PAGE = 20;

const LEVEL_OPTIONS: { value: string; label: string }[] = [
  { value: 'all', label: 'All Levels' },
  { value: 'beginner', label: 'Beginner' },
  { value: 'intermediate', label: 'Intermediate' },
  { value: 'advanced', label: 'Advanced' },
];

const STATUS_OPTIONS: { value: string; label: string }[] = [
  { value: 'all', label: 'All Status' },
  { value: 'draft', label: 'Draft' },
  { value: 'published', label: 'Published' },
  { value: 'archived', label: 'Archived' },
];

const EMPTY_FORM: CourseInput = {
  title: '',
  slug: '',
  description: '',
  instructor: '',
  thumbnail_url: '',
  category: 'general',
  level: 'beginner',
  is_free: true,
  price: 0,
  currency: 'USD',
  status: 'draft',
};

// ============================================================
// Course create / edit modal
// ============================================================

interface CourseModalProps {
  isOpen: boolean;
  course: AcademyCourse | null;
  onClose: () => void;
  onSuccess: () => void;
}

const CourseModal: React.FC<CourseModalProps> = ({ isOpen, course, onClose, onSuccess }) => {
  const [form, setForm] = useState<CourseInput>(EMPTY_FORM);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (course) {
      setForm({
        title: course.title,
        slug: course.slug,
        description: course.description ?? '',
        instructor: course.instructor ?? '',
        thumbnail_url: course.thumbnail_url ?? '',
        category: course.category ?? 'general',
        level: course.level,
        is_free: course.is_free,
        price: course.price,
        currency: course.currency,
        status: course.status,
      });
    } else {
      setForm(EMPTY_FORM);
    }
  }, [course, isOpen]);

  const set = <K extends keyof CourseInput>(key: K, value: CourseInput[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const inputClass =
    'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim()) {
      toast.error('Title is required');
      return;
    }
    setSubmitting(true);
    try {
      const payload: CourseInput = {
        ...form,
        price: form.is_free ? 0 : Number(form.price) || 0,
      };
      if (course) {
        await academyService.updateCourse(course.uuid, payload);
        toast.success('Course updated');
      } else {
        await academyService.createCourse(payload);
        toast.success('Course created');
      }
      onSuccess();
      onClose();
    } catch (err) {
      console.error('Save course failed:', err);
      toast.error('Failed to save course');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={course ? 'Edit Course' : 'Create Course'} size="2xl">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Title *</label>
            <input className={inputClass} value={form.title} onChange={(e) => set('title', e.target.value)} placeholder="e.g. Introduction to TypeScript" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <textarea className={inputClass} rows={3} value={form.description} onChange={(e) => set('description', e.target.value)} placeholder="Short course summary" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Instructor</label>
            <input className={inputClass} value={form.instructor} onChange={(e) => set('instructor', e.target.value)} placeholder="Instructor name" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Category</label>
            <input className={inputClass} value={form.category} onChange={(e) => set('category', e.target.value)} placeholder="e.g. programming" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Level</label>
            <select className={inputClass} value={form.level} onChange={(e) => set('level', e.target.value as CourseLevel)}>
              <option value="beginner">Beginner</option>
              <option value="intermediate">Intermediate</option>
              <option value="advanced">Advanced</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Status</label>
            <select className={inputClass} value={form.status} onChange={(e) => set('status', e.target.value as CourseStatus)}>
              <option value="draft">Draft</option>
              <option value="published">Published</option>
              <option value="archived">Archived</option>
            </select>
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Thumbnail URL</label>
            <input className={inputClass} value={form.thumbnail_url} onChange={(e) => set('thumbnail_url', e.target.value)} placeholder="https://…/thumb.jpg" />
          </div>
          <div className="col-span-2 flex items-center gap-3">
            <input id="is_free" type="checkbox" checked={form.is_free} onChange={(e) => set('is_free', e.target.checked)} className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500" />
            <label htmlFor="is_free" className="text-sm font-medium text-secondary-700">This is a free course</label>
          </div>
          {!form.is_free && (
            <>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Price</label>
                <input className={inputClass} type="number" min={0} value={form.price} onChange={(e) => set('price', Number(e.target.value))} />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
                <input className={inputClass} value={form.currency} onChange={(e) => set('currency', e.target.value)} placeholder="USD" />
              </div>
            </>
          )}
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" isLoading={submitting}>{course ? 'Save Changes' : 'Create Course'}</Button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================================
// Page
// ============================================================

function AcademyCoursesPage() {
  const router = useRouter();
  const { canCreate, canUpdate, canDelete, isAdmin } = usePermissions();

  const [courses, setCourses] = useState<AcademyCourse[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [levelFilter, setLevelFilter] = useState('all');
  const [statusFilter, setStatusFilter] = useState('all');

  const [modalOpen, setModalOpen] = useState(false);
  const [editing, setEditing] = useState<AcademyCourse | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<AcademyCourse | null>(null);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await academyService.getCourses({
        page,
        perPage: PER_PAGE,
        search: search.trim() || undefined,
        level: levelFilter,
        status: statusFilter,
      });
      setCourses(res.data);
      setTotal(res.pagination.total);
    } catch (err) {
      console.error('Load courses failed:', err);
      toast.error('Failed to load courses');
    } finally {
      setLoading(false);
    }
  }, [page, search, levelFilter, statusFilter]);

  useEffect(() => {
    load();
  }, [load]);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await academyService.deleteCourse(deleteTarget.uuid);
      toast.success('Course deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      console.error('Delete course failed:', err);
      toast.error('Failed to delete course');
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<AcademyCourse>[] = [
    {
      key: 'title',
      header: 'Course',
      render: (c) => (
        <div className="min-w-0">
          <p className="font-medium text-secondary-900 truncate">{c.title}</p>
          <p className="text-xs text-secondary-500 truncate">/{c.slug}</p>
        </div>
      ),
    },
    {
      key: 'category',
      header: 'Category',
      render: (c) => <span className="text-sm text-secondary-600 capitalize">{c.category || '—'}</span>,
    },
    {
      key: 'level',
      header: 'Level',
      render: (c) => <span className="text-sm capitalize text-secondary-600">{c.level}</span>,
    },
    {
      key: 'is_free',
      header: 'Pricing',
      render: (c) =>
        c.is_free ? (
          <Badge variant="success">Free</Badge>
        ) : (
          <span className="text-sm font-medium text-secondary-700">{c.currency} {c.price}</span>
        ),
    },
    {
      key: 'lesson_count',
      header: 'Lessons',
      render: (c) => (
        <span className="inline-flex items-center gap-1 text-sm text-secondary-600">
          <Layers size={14} /> {c.lesson_count ?? 0}
          <span className="text-secondary-400">· {formatCourseDuration(c.duration_minutes)}</span>
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (c) => <Badge variant={getCourseStatusVariant(c.status)} className="capitalize">{c.status}</Badge>,
    },
    {
      key: 'updated_at',
      header: 'Updated',
      render: (c) => <span className="text-sm text-secondary-500">{formatDate(c.updated_at)}</span>,
    },
    {
      key: 'actions',
      header: '',
      render: (c) => (
        <div className="flex items-center justify-end gap-1" onClick={(e) => e.stopPropagation()}>
          {canUpdate('courses') && (
            <button title="Edit" onClick={() => { setEditing(c); setModalOpen(true); }} className="p-1.5 rounded-md text-secondary-500 hover:bg-secondary-100 hover:text-secondary-900">
              <Edit size={16} />
            </button>
          )}
          {canDelete('courses') && (
            <button title="Delete" onClick={() => setDeleteTarget(c)} className="p-1.5 rounded-md text-secondary-500 hover:bg-error-50 hover:text-error-600">
              <Trash2 size={16} />
            </button>
          )}
        </div>
      ),
    },
  ];

  const totalPages = Math.max(1, Math.ceil(total / PER_PAGE));

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-xl bg-primary-50 text-primary-600 flex items-center justify-center">
            <BookOpen size={22} />
          </div>
          <div>
            <h1 className="text-xl font-bold text-secondary-900">Academy</h1>
            <p className="text-sm text-secondary-500">Manage courses and rich lesson content</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isAdmin && (
            <Button variant="outline" leftIcon={<Banknote size={16} />} onClick={() => router.push('/dashboard/academy/admin')}>Payouts</Button>
          )}
          <Button variant="outline" leftIcon={<CreditCard size={16} />} onClick={() => router.push('/dashboard/academy/creator')}>Monetization</Button>
          <Button variant="outline" leftIcon={<RefreshCw size={16} />} onClick={load}>Refresh</Button>
          {canCreate('courses') && (
            <Button leftIcon={<Plus size={16} />} onClick={() => { setEditing(null); setModalOpen(true); }}>New Course</Button>
          )}
        </div>
      </div>

      {/* Filters */}
      <div className="bg-surface rounded-xl border border-secondary-200 p-4 flex flex-col sm:flex-row gap-3">
        <div className="relative flex-1">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-secondary-400" />
          <input
            value={search}
            onChange={(e) => { setSearch(e.target.value); setPage(1); }}
            placeholder="Search courses…"
            className="w-full pl-9 pr-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
          />
        </div>
        <div className="w-full sm:w-44">
          <Select value={levelFilter} onChange={(e) => { setLevelFilter(e.target.value); setPage(1); }}>
            {LEVEL_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
        </div>
        <div className="w-full sm:w-44">
          <Select value={statusFilter} onChange={(e) => { setStatusFilter(e.target.value); setPage(1); }}>
            {STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
        </div>
      </div>

      {/* Table */}
      <div className="bg-surface rounded-xl border border-secondary-200 overflow-hidden">
        <Table
          columns={columns}
          data={courses}
          keyExtractor={(c) => c.uuid}
          isLoading={loading}
          emptyMessage="No courses yet. Create your first course to get started."
          onRowClick={(c) => router.push(`/dashboard/academy/${c.uuid}`)}
        />
        {totalPages > 1 && (
          <div className="border-t border-secondary-200 p-3">
            <Pagination currentPage={page} totalPages={totalPages} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
          </div>
        )}
      </div>

      <CourseModal
        isOpen={modalOpen}
        course={editing}
        onClose={() => setModalOpen(false)}
        onSuccess={load}
      />

      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={handleDelete}
        title="Delete course"
        message={`Delete "${deleteTarget?.title}"? This also removes its lessons. This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

// Shown to authenticated users who aren't instructors yet (no "courses" access):
// an onboarding CTA into the become-an-instructor flow rather than a dead end.
function BecomeInstructorPrompt() {
  const router = useRouter();
  return (
    <div className="min-h-[400px] flex items-center justify-center p-8">
      <div className="text-center max-w-md">
        <div className="w-16 h-16 mx-auto mb-6 bg-primary-50 text-primary-600 rounded-full flex items-center justify-center">
          <GraduationCap className="w-8 h-8" />
        </div>
        <h2 className="text-xl font-semibold text-secondary-900 mb-2">Start teaching on Academy</h2>
        <p className="text-secondary-600 mb-6">
          You&apos;re not an instructor yet. Become one to create and sell your own courses.
        </p>
        <button
          onClick={() => router.push('/dashboard/academy/join')}
          className="inline-flex items-center gap-2 px-4 py-2 bg-primary-500 text-white rounded-lg hover:bg-primary-600 transition-colors"
        >
          Become an Instructor
          <ArrowRight className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
}

export default function AcademyPage() {
  return (
    <ProtectedPage module="courses" action="read" title="Academy" fallback={<BecomeInstructorPrompt />}>
      <AcademyCoursesPage />
    </ProtectedPage>
  );
}
