'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { ArrowLeft, Save, Eye } from 'lucide-react';
import { Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { RichTextEditor } from '@/components/academy';
import {
  academyService,
  type LessonInput,
  type LessonStatus,
} from '@/services/academy.service';
import toast from 'react-hot-toast';

interface LessonForm {
  title: string;
  description: string;
  status: LessonStatus;
  duration_seconds: number;
  is_preview: boolean;
  s3_key: string;
  content_html: string;
  content_json: string;
}

const EMPTY: LessonForm = {
  title: '',
  description: '',
  status: 'draft',
  duration_seconds: 0,
  is_preview: false,
  s3_key: '',
  content_html: '',
  content_json: '',
};

function LessonEditor() {
  const params = useParams();
  const router = useRouter();
  const courseUuid = params?.uuid as string;
  const lessonId = params?.lessonId as string;
  const isNew = lessonId === 'new';

  const [form, setForm] = useState<LessonForm>(EMPTY);
  const [loading, setLoading] = useState(!isNew);
  const [saving, setSaving] = useState(false);

  const set = <K extends keyof LessonForm>(key: K, value: LessonForm[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const load = useCallback(async () => {
    if (isNew) return;
    setLoading(true);
    try {
      const l = await academyService.getLesson(lessonId);
      setForm({
        title: l.title ?? '',
        description: l.description ?? '',
        status: l.status ?? 'draft',
        duration_seconds: l.duration_seconds ?? 0,
        is_preview: !!l.is_preview,
        s3_key: l.s3_key ?? '',
        content_html: l.content_html ?? '',
        content_json: l.content_json ?? '',
      });
    } catch (err) {
      console.error('Load lesson failed:', err);
      toast.error('Failed to load lesson');
    } finally {
      setLoading(false);
    }
  }, [isNew, lessonId]);

  useEffect(() => {
    load();
  }, [load]);

  const onEditorChange = useCallback((html: string, json: string) => {
    setForm((prev) => ({ ...prev, content_html: html, content_json: json }));
  }, []);

  const handleSave = async () => {
    if (!form.title.trim()) {
      toast.error('Lesson title is required');
      return;
    }
    setSaving(true);
    try {
      const payload: LessonInput = {
        title: form.title.trim(),
        description: form.description,
        status: form.status,
        duration_seconds: Number(form.duration_seconds) || 0,
        is_preview: form.is_preview,
        s3_key: form.s3_key,
        content_html: form.content_html,
        content_json: form.content_json,
      };
      if (isNew) {
        await academyService.createLesson(courseUuid, payload);
        toast.success('Lesson created');
      } else {
        await academyService.updateLesson(lessonId, payload);
        toast.success('Lesson saved');
      }
      router.push(`/dashboard/academy/${courseUuid}`);
    } catch (err) {
      console.error('Save lesson failed:', err);
      toast.error('Failed to save lesson');
    } finally {
      setSaving(false);
    }
  };

  const inputClass =
    'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

  if (loading) {
    return (
      <div className="animate-pulse space-y-4">
        <div className="h-8 bg-secondary-200 rounded w-1/3" />
        <div className="h-96 bg-secondary-100 rounded" />
      </div>
    );
  }

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <button onClick={() => router.push(`/dashboard/academy/${courseUuid}`)} className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-900">
          <ArrowLeft size={16} /> Back to course
        </button>
        <div className="flex items-center gap-2">
          <Button variant="outline" onClick={() => router.push(`/dashboard/academy/${courseUuid}`)}>Cancel</Button>
          <Button leftIcon={<Save size={16} />} isLoading={saving} onClick={handleSave}>
            {isNew ? 'Create Lesson' : 'Save Lesson'}
          </Button>
        </div>
      </div>

      <h1 className="text-xl font-bold text-secondary-900">{isNew ? 'New Lesson' : 'Edit Lesson'}</h1>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        {/* Main: title + content */}
        <div className="lg:col-span-2 space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Title *</label>
            <input className={inputClass} value={form.title} onChange={(e) => set('title', e.target.value)} placeholder="Lesson title" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Short description</label>
            <input className={inputClass} value={form.description} onChange={(e) => set('description', e.target.value)} placeholder="One-line summary shown in the lesson list" />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">Content</label>
            <RichTextEditor value={form.content_html} onChange={onEditorChange} />
            <p className="text-xs text-secondary-400 mt-1.5">Rich content is saved as sanitized HTML and rendered on the learner site.</p>
          </div>
        </div>

        {/* Sidebar: settings */}
        <div className="space-y-4">
          <div className="bg-surface rounded-xl border border-secondary-200 p-4 space-y-4">
            <h3 className="text-sm font-semibold text-secondary-800">Lesson settings</h3>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Status</label>
              <select className={inputClass} value={form.status} onChange={(e) => set('status', e.target.value as LessonStatus)}>
                <option value="draft">Draft</option>
                <option value="published">Published</option>
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Duration (seconds)</label>
              <input className={inputClass} type="number" min={0} value={form.duration_seconds} onChange={(e) => set('duration_seconds', Number(e.target.value))} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Video S3 key (optional)</label>
              <input className={inputClass} value={form.s3_key} onChange={(e) => set('s3_key', e.target.value)} placeholder="courses/intro/lesson-1.mp4" />
            </div>
            <label className="flex items-center gap-2.5 cursor-pointer">
              <input type="checkbox" checked={form.is_preview} onChange={(e) => set('is_preview', e.target.checked)} className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500" />
              <span className="inline-flex items-center gap-1 text-sm font-medium text-secondary-700"><Eye size={14} /> Free preview lesson</span>
            </label>
          </div>
        </div>
      </div>
    </div>
  );
}

export default function LessonEditorPage() {
  return (
    <ProtectedPage module="courses" action="update" title="Academy">
      <LessonEditor />
    </ProtectedPage>
  );
}
