'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { Search, Plus, Trash2, Edit, BookOpen, RefreshCw, Layers, CreditCard, Banknote, GraduationCap, ArrowRight, User, X, ClipboardCheck, CheckCircle2, XCircle, Send } from 'lucide-react';
import { Table, Badge, Pagination, Modal, Button, ConfirmDialog, Select, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useAuthStore } from '@/store/auth.store';
import { BackToAcademy } from '@/components/academy';
import {
  academyService,
  getCourseStatusVariant,
  getCourseStatusLabel,
  academyErrorMessage,
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
  { value: 'pending_review', label: 'Pending review' },
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
  tags: [],
  level: 'beginner',
  is_free: true,
  price: 0,
  currency: 'USD',
  tier: 1,
  status: 'draft',
};

// ============================================================
// Course create / edit modal
// ============================================================

interface CourseModalProps {
  isOpen: boolean;
  course: AcademyCourse | null;
  // Reviewers (platform admin / namespace owner) may publish directly; everyone
  // else can only submit for review, so the status control adapts to the role.
  canPublishDirectly: boolean;
  onClose: () => void;
  onSuccess: () => void;
}

const CourseModal: React.FC<CourseModalProps> = ({ isOpen, course, canPublishDirectly, onClose, onSuccess }) => {
  const [form, setForm] = useState<CourseInput>(EMPTY_FORM);
  const [submitting, setSubmitting] = useState(false);
  const [categories, setCategories] = useState<string[]>([]);
  const [tagDraft, setTagDraft] = useState('');

  const { user } = useAuthStore();
  // The creator is the instructor — no free-text field. Derive a display name
  // (full name → username → email local-part) for the read-only credit and as
  // the default `instructor` value on a new course.
  const currentUserName =
    [user?.first_name, user?.last_name].filter(Boolean).join(' ').trim() ||
    user?.username ||
    (user?.email ? user.email.split('@')[0] : '') ||
    'You';

  useEffect(() => {
    if (course) {
      setForm({
        title: course.title,
        slug: course.slug,
        description: course.description ?? '',
        instructor: course.instructor ?? '',
        thumbnail_url: course.thumbnail_url ?? '',
        category: course.category ?? 'general',
        tags: course.tags ?? [],
        level: course.level,
        is_free: course.is_free,
        // Stored in minor units (pence/cents); edit in major units.
        price: (course.price ?? 0) / 100,
        currency: course.currency,
        tier: course.tier ?? 1,
        status: course.status,
      });
    } else {
      setForm({ ...EMPTY_FORM, instructor: currentUserName });
    }
    setTagDraft('');
  }, [course, isOpen, currentUserName]);

  // Fetch the existing category values whenever the modal opens, so the
  // create-or-select control can offer them (falls back to none on error).
  useEffect(() => {
    if (!isOpen) return;
    let active = true;
    academyService
      .getCategories()
      .then((cats) => { if (active) setCategories(cats); })
      .catch(() => { if (active) setCategories([]); });
    return () => { active = false; };
  }, [isOpen]);

  const set = <K extends keyof CourseInput>(key: K, value: CourseInput[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  // Tag chips: add on Enter or comma, de-duped case-insensitively, capped and
  // trimmed to match the backend (max 20 tags, <= 40 chars each).
  const addTag = (raw: string) => {
    const value = raw.trim().slice(0, 40);
    if (!value) return;
    setForm((prev) => {
      const existing = prev.tags ?? [];
      if (existing.length >= 20) return prev;
      if (existing.some((t) => t.toLowerCase() === value.toLowerCase())) return prev;
      return { ...prev, tags: [...existing, value] };
    });
    setTagDraft('');
  };

  const removeTag = (tag: string) =>
    setForm((prev) => ({ ...prev, tags: (prev.tags ?? []).filter((t) => t !== tag) }));

  const handleTagKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      addTag(tagDraft);
    } else if (e.key === 'Backspace' && tagDraft === '' && (form.tags ?? []).length > 0) {
      removeTag((form.tags ?? [])[(form.tags ?? []).length - 1]);
    }
  };

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
        // Convert major units (what the user typed) back to minor units for the API.
        price: form.is_free ? 0 : Math.round((Number(form.price) || 0) * 100),
      };
      const saved = course
        ? await academyService.updateCourse(course.uuid, payload)
        : await academyService.createCourse(payload);
      // The backend gate silently turns an instructor's `published` into
      // `pending_review`. Tell the truth: if that happened, say it's awaiting
      // review, not that it was published.
      if (saved.status === 'pending_review') {
        toast.success('Submitted for review — an admin will approve it before it goes live');
      } else {
        toast.success(course ? 'Course updated' : 'Course created');
      }
      onSuccess();
      onClose();
    } catch (err) {
      console.error('Save course failed:', err);
      toast.error(academyErrorMessage(err, 'Failed to save course'));
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
            {/* The creator IS the instructor (backend sets owner_user_uuid to the
                current user; the public page credits their profile name). So this
                is a read-only credit, not a field to fill in. */}
            <div className="w-full px-3 py-2 border border-secondary-200 rounded-lg text-sm bg-secondary-50 text-secondary-700 truncate">
              {form.instructor?.trim() || currentUserName}
            </div>
            <p className="mt-1 text-xs text-secondary-500">You&apos;re the instructor. Change your public name in My Profile.</p>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Category</label>
            {/* Searchable combobox: pick an existing namespace category or create a new one. */}
            <SearchableSelect
              options={categories.map((c) => ({ value: c, label: c }))}
              value={form.category}
              onChange={(v) => set('category', v)}
              creatable
              clearable
              placeholder="Pick existing or create new"
              searchPlaceholder="Search or type a new category…"
              emptyMessage="No categories yet — type to create one"
            />
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
            {canPublishDirectly ? (
              // Reviewers (admin / owner) publish directly.
              <select className={inputClass} value={form.status} onChange={(e) => set('status', e.target.value as CourseStatus)}>
                <option value="draft">Draft</option>
                {form.status === 'pending_review' && <option value="pending_review">Pending review</option>}
                <option value="published">Published</option>
                <option value="archived">Archived</option>
              </select>
            ) : (
              // Instructors cannot self-publish. The publish choice is honestly
              // labelled "Submit for review" and carries value `published`, which
              // the backend gate converts to `pending_review`. A course already
              // pending review maps onto this same option so it reads truthfully.
              <>
                <select
                  className={inputClass}
                  value={form.status === 'pending_review' ? 'published' : form.status}
                  onChange={(e) => set('status', e.target.value as CourseStatus)}
                >
                  <option value="draft">Save as draft</option>
                  <option value="published">Submit for review</option>
                  <option value="archived">Archived</option>
                </select>
                {form.status === 'pending_review' ? (
                  <p className="mt-1 text-xs text-warning-600">Awaiting admin review. Resubmitting keeps it in the queue.</p>
                ) : form.status === 'published' ? (
                  <p className="mt-1 text-xs text-secondary-500">An admin approves it before it appears on the public site.</p>
                ) : null}
              </>
            )}
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Thumbnail URL</label>
            <input className={inputClass} value={form.thumbnail_url} onChange={(e) => set('thumbnail_url', e.target.value)} placeholder="https://…/thumb.jpg" />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium text-secondary-700 mb-1">Tags</label>
            {/* Input stays full-width on top; added tags wrap as chips BELOW it so
                typing never gets pushed around by existing chips. */}
            <input
              className={inputClass}
              value={tagDraft}
              onChange={(e) => setTagDraft(e.target.value)}
              onKeyDown={handleTagKeyDown}
              onBlur={() => addTag(tagDraft)}
              placeholder="Add tags (Enter or comma)…"
            />
            {(form.tags ?? []).length > 0 && (
              <div className="mt-2 flex flex-wrap gap-1.5">
                {(form.tags ?? []).map((tag) => (
                  <span
                    key={tag}
                    className="inline-flex items-center gap-1 pl-2.5 pr-1.5 py-1 rounded-full bg-primary-50 text-primary-700 text-xs font-medium"
                  >
                    {tag}
                    <button
                      type="button"
                      onClick={() => removeTag(tag)}
                      className="rounded-full p-0.5 text-primary-400 hover:bg-primary-100 hover:text-primary-700"
                      aria-label={`Remove ${tag}`}
                    >
                      <X className="w-3 h-3" />
                    </button>
                  </span>
                ))}
              </div>
            )}
            <p className="mt-1 text-xs text-secondary-500">Press Enter or comma to add. Used for sorting and filtering. Up to 20 tags.</p>
          </div>
          <div className="col-span-2 flex items-center gap-3">
            <input id="is_free" type="checkbox" checked={form.is_free} onChange={(e) => set('is_free', e.target.checked)} className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500" />
            <label htmlFor="is_free" className="text-sm font-medium text-secondary-700">This is a free course</label>
          </div>
          {!form.is_free && (
            <>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Price</label>
                <input className={inputClass} type="number" min={0} step={0.01} value={form.price} onChange={(e) => set('price', Number(e.target.value))} placeholder="e.g. 9.99" />
                <p className="mt-1 text-xs text-secondary-500">Amount charged to the learner, e.g. 9.99 for {form.currency} 9.99.</p>
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
                <select className={inputClass} value={form.currency} onChange={(e) => set('currency', e.target.value)}>
                  {['USD', 'GBP', 'EUR', 'INR', 'AUD', 'CAD', 'SGD', 'AED', 'JPY', 'NZD'].map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
              </div>
              <div className="col-span-2">
                <label className="block text-sm font-medium text-secondary-700 mb-1">Membership tier</label>
                <input className={inputClass} type="number" min={1} step={1} value={form.tier ?? 1} onChange={(e) => set('tier', Math.max(1, Math.floor(Number(e.target.value) || 1)))} />
                <p className="mt-1 text-xs text-secondary-500">A subscriber can watch this course if their membership tier is this number or higher. Tier 1 = your entry-level plan. Buyers always get access regardless of tier.</p>
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
// Admin review queue — the approval gate's front end.
// Only rendered for reviewers (platform admin / namespace owner). Lists every
// course an instructor submitted, with Approve (→ published) and Reject
// (→ draft) actions, each confirmed before it fires.
// ============================================================

interface PendingReviewPanelProps {
  // Bumped by the parent whenever the main list changes, to keep the queue fresh
  // (e.g. after a course is edited into pending_review elsewhere).
  refreshKey: number;
  onReviewed: () => void;
}

type ReviewAction = { course: AcademyCourse; kind: 'approve' | 'reject' };

const PendingReviewPanel: React.FC<PendingReviewPanelProps> = ({ refreshKey, onReviewed }) => {
  const router = useRouter();
  const [pending, setPending] = useState<AcademyCourse[]>([]);
  const [loading, setLoading] = useState(true);
  const [action, setAction] = useState<ReviewAction | null>(null);
  const [working, setWorking] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setPending(await academyService.getPendingCourses());
    } catch (err) {
      console.error('Load pending courses failed:', err);
      toast.error(academyErrorMessage(err, 'Failed to load pending courses'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const runAction = async () => {
    if (!action) return;
    setWorking(true);
    try {
      if (action.kind === 'approve') {
        await academyService.approveCourse(action.course.uuid);
        toast.success(`"${action.course.title}" approved and published`);
      } else {
        await academyService.rejectCourse(action.course.uuid);
        toast.success(`"${action.course.title}" sent back to the instructor as a draft`);
      }
      setAction(null);
      await load();
      onReviewed();
    } catch (err) {
      console.error('Review action failed:', err);
      toast.error(academyErrorMessage(err, 'Failed to update course'));
    } finally {
      setWorking(false);
    }
  };

  return (
    <div className="bg-surface rounded-xl border border-warning-200 overflow-hidden">
      <div className="flex items-center gap-2 px-4 py-3 border-b border-secondary-200 bg-warning-500/5">
        <ClipboardCheck size={18} className="text-warning-600" />
        <h2 className="text-sm font-semibold text-secondary-800">Pending review</h2>
        {!loading && (
          <Badge variant="warning">{pending.length}</Badge>
        )}
        <span className="text-xs text-secondary-500 ml-1">Courses instructors submitted, awaiting your approval.</span>
      </div>

      {loading ? (
        <div className="p-4"><div className="h-16 animate-pulse rounded bg-secondary-100" /></div>
      ) : pending.length === 0 ? (
        <p className="px-4 py-6 text-sm text-secondary-500">Nothing waiting for review right now.</p>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {pending.map((c) => (
            <li key={c.uuid} className="flex flex-col sm:flex-row sm:items-center gap-3 px-4 py-3">
              <div className="min-w-0 flex-1">
                <button
                  onClick={() => router.push(`/dashboard/academy/${c.uuid}`)}
                  className="font-medium text-secondary-900 truncate hover:text-primary-600 text-left"
                >
                  {c.title}
                </button>
                <p className="text-xs text-secondary-500 truncate">
                  /{c.slug}
                  {c.instructor ? ` · ${c.instructor}` : ''}
                  {` · ${c.lesson_count ?? 0} lesson${(c.lesson_count ?? 0) === 1 ? '' : 's'}`}
                </p>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <Button
                  size="sm"
                  variant="outline"
                  leftIcon={<XCircle size={16} />}
                  onClick={() => setAction({ course: c, kind: 'reject' })}
                >
                  Reject
                </Button>
                <Button
                  size="sm"
                  leftIcon={<CheckCircle2 size={16} />}
                  onClick={() => setAction({ course: c, kind: 'approve' })}
                >
                  Approve
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}

      <ConfirmDialog
        isOpen={!!action}
        onClose={() => setAction(null)}
        onConfirm={runAction}
        title={action?.kind === 'approve' ? 'Approve course' : 'Reject course'}
        message={
          action?.kind === 'approve'
            ? `Publish "${action?.course.title}"? It will become visible on the public site immediately.`
            : `Send "${action?.course.title}" back to draft? The instructor can revise and resubmit it.`
        }
        confirmText={action?.kind === 'approve' ? 'Approve & publish' : 'Reject'}
        variant={action?.kind === 'approve' ? 'info' : 'danger'}
        isLoading={working}
      />
    </div>
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
  // Instructor "Submit for review" — a prominent, one-click alternative to
  // digging the status control out of the edit modal.
  const [submitTarget, setSubmitTarget] = useState<AcademyCourse | null>(null);
  const [submittingReview, setSubmittingReview] = useState(false);

  // A reviewer (platform admin OR namespace owner) may publish directly and sees
  // the approval queue. `isAdmin` covers the platform admin; ownership comes from
  // the instructor-status endpoint, mirroring the backend's can_manage_all.
  const [isOwner, setIsOwner] = useState(false);
  const [reviewRefresh, setReviewRefresh] = useState(0);
  const isReviewer = isAdmin || isOwner;

  useEffect(() => {
    let active = true;
    academyService
      .getInstructorStatus()
      .then((s) => { if (active) setIsOwner(!!s.is_owner); })
      .catch(() => { if (active) setIsOwner(false); });
    return () => { active = false; };
  }, []);

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

  // Send a course into the approval queue. Instructors can't self-publish: the
  // backend gate turns a `published` request into `pending_review`, so we send
  // `published` and report the status the server actually persisted.
  const handleSubmitForReview = async () => {
    if (!submitTarget) return;
    setSubmittingReview(true);
    try {
      const saved = await academyService.updateCourse(submitTarget.uuid, { status: 'published' });
      if (saved.status === 'pending_review') {
        toast.success('Submitted for review — an admin will approve it before it goes live');
      } else if (saved.status === 'published') {
        toast.success('Course published');
      } else {
        toast.success('Course updated');
      }
      setSubmitTarget(null);
      load();
      setReviewRefresh((n) => n + 1);
    } catch (err) {
      console.error('Submit for review failed:', err);
      toast.error(academyErrorMessage(err, 'Failed to submit for review'));
    } finally {
      setSubmittingReview(false);
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
      render: (c) => <Badge variant={getCourseStatusVariant(c.status)}>{getCourseStatusLabel(c.status)}</Badge>,
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
          {/* Instructors (non-reviewers) get an explicit go-live action so it's
              not buried in the edit modal. Reviewers publish via the modal /
              approval queue instead. */}
          {!isReviewer && canUpdate('courses') && (c.status === 'draft' || c.status === 'archived') && (
            <button
              title="Submit for admin review"
              onClick={() => setSubmitTarget(c)}
              className="inline-flex items-center gap-1 px-2 py-1 rounded-md text-xs font-medium text-primary-600 hover:bg-primary-50"
            >
              <Send size={14} /> Submit for review
            </button>
          )}
          {!isReviewer && c.status === 'pending_review' && (
            <span className="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium text-warning-600" title="Awaiting admin approval">
              <ClipboardCheck size={14} /> In review
            </span>
          )}
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

  // The trap instructors fall into: they publish a LESSON and assume the course
  // is live. It isn't — lessons only go public once the COURSE is approved. Nudge
  // them toward "Submit for review" when they have draft courses that hold lessons.
  const unsubmittedWithLessons = !isReviewer
    ? courses.filter((c) => c.status === 'draft' && (c.lesson_count ?? 0) > 0)
    : [];

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
          {/* Only shown to instructors who arrived via the academy site handoff. */}
          <BackToAcademy />
          {isAdmin && (
            <Button variant="outline" leftIcon={<Banknote size={16} />} onClick={() => router.push('/dashboard/academy/admin')}>Payouts</Button>
          )}
          <Button variant="outline" leftIcon={<User size={16} />} onClick={() => router.push('/dashboard/academy/profile')}>My Profile</Button>
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

      {/* Instructor nudge: lessons aren't public until the course is approved. */}
      {unsubmittedWithLessons.length > 0 && (
        <div className="flex items-start gap-3 rounded-xl border border-primary-200 bg-primary-50/50 px-4 py-3">
          <ClipboardCheck size={18} className="text-primary-600 mt-0.5 shrink-0" />
          <div className="text-sm text-secondary-700">
            <p className="font-medium text-secondary-900">Your lessons aren&apos;t live yet</p>
            <p className="mt-0.5">
              Publishing a lesson only adds it to the course draft — it does <strong>not</strong> put the course on the public site.
              When a course is ready, click <strong>Submit for review</strong>; an admin approves it before it goes live.
              {` You have ${unsubmittedWithLessons.length} course${unsubmittedWithLessons.length === 1 ? '' : 's'} with lessons still in draft.`}
            </p>
          </div>
        </div>
      )}

      {/* Approval queue — reviewers only (platform admin / namespace owner) */}
      {isReviewer && (
        <PendingReviewPanel
          refreshKey={reviewRefresh}
          onReviewed={load}
        />
      )}

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
        canPublishDirectly={isReviewer}
        onClose={() => setModalOpen(false)}
        onSuccess={() => { load(); setReviewRefresh((n) => n + 1); }}
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

      <ConfirmDialog
        isOpen={!!submitTarget}
        onClose={() => setSubmitTarget(null)}
        onConfirm={handleSubmitForReview}
        title="Submit for review"
        message={`Submit "${submitTarget?.title}" for review? An admin approves it before it appears on the public site — your lessons are not public until then.`}
        confirmText="Submit for review"
        variant="info"
        isLoading={submittingReview}
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
