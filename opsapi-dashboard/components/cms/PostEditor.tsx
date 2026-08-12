'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Save, X, Eye, Star, Loader2 } from 'lucide-react';
import { Button, Input, Textarea, Select, Card } from '@/components/ui';
import { RichTextEditor } from '@/components/academy';
import {
  cmsService,
  type CmsPost,
  type CmsCategory,
  type PostInput,
  type PostStatus,
  type PostVisibility,
} from '@/services/cms.service';
import toast from 'react-hot-toast';

function slugify(text: string): string {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

// Gentle normalisation while the user is typing IN the slug field: keeps a
// trailing hyphen so "my-post" can actually be typed (full slugify strips it and
// makes hyphens impossible to enter). The final clean happens on blur.
function normalizeSlugInput(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+/, '');
}

const STATUS_OPTIONS: { value: PostStatus; label: string }[] = [
  { value: 'draft', label: 'Draft' },
  { value: 'published', label: 'Published' },
  { value: 'scheduled', label: 'Scheduled' },
  { value: 'archived', label: 'Archived' },
];

interface PostEditorProps {
  /** Existing post (edit mode). Omit for create mode. */
  post?: CmsPost;
}

export default function PostEditor({ post }: PostEditorProps) {
  const router = useRouter();
  const isEdit = Boolean(post);

  const [categories, setCategories] = useState<CmsCategory[]>([]);
  const [saving, setSaving] = useState(false);

  const [title, setTitle] = useState(post?.title ?? '');
  const [slug, setSlug] = useState(post?.slug ?? '');
  const [slugTouched, setSlugTouched] = useState(isEdit);
  const [excerpt, setExcerpt] = useState(post?.excerpt ?? '');
  const [contentHtml, setContentHtml] = useState(post?.content_html ?? '');
  const [contentJson, setContentJson] = useState(post?.content_json ?? '');
  const [status, setStatus] = useState<PostStatus>(post?.status ?? 'draft');
  const [visibility, setVisibility] = useState<PostVisibility>(post?.visibility ?? 'public');
  const [isFeatured, setIsFeatured] = useState<boolean>(post?.is_featured ?? false);
  const [categoryUuid, setCategoryUuid] = useState<string>(post?.category?.uuid ?? '');
  const [featuredImage, setFeaturedImage] = useState(post?.featured_image_url ?? '');
  const [authorName, setAuthorName] = useState(post?.author_name ?? '');
  const [scheduledAt, setScheduledAt] = useState(post?.scheduled_at ?? '');

  const [tags, setTags] = useState<string[]>(post?.tags?.map((t) => t.name) ?? []);
  const [tagInput, setTagInput] = useState('');

  const [seoTitle, setSeoTitle] = useState(post?.seo_title ?? '');
  const [seoDescription, setSeoDescription] = useState(post?.seo_description ?? '');
  const [seoKeywords, setSeoKeywords] = useState(post?.seo_keywords ?? '');
  const [showSeo, setShowSeo] = useState(false);

  useEffect(() => {
    cmsService
      .getCategories()
      .then(setCategories)
      .catch(() => setCategories([]));
  }, []);

  // Auto-derive the slug from the title until the user edits the slug directly.
  // Done inline (not in an effect) so it's predictable and avoids a re-render loop.
  const handleTitleChange = (v: string) => {
    setTitle(v);
    if (!slugTouched) setSlug(slugify(v));
  };
  const handleSlugChange = (v: string) => {
    setSlugTouched(true);
    setSlug(normalizeSlugInput(v));
  };
  const handleSlugBlur = () => setSlug((s) => slugify(s));

  const addTag = useCallback(
    (raw: string) => {
      const name = raw.trim();
      if (!name) return;
      setTags((prev) => (prev.some((t) => t.toLowerCase() === name.toLowerCase()) ? prev : [...prev, name]));
      setTagInput('');
    },
    [],
  );

  const removeTag = useCallback((name: string) => {
    setTags((prev) => prev.filter((t) => t !== name));
  }, []);

  const onTagKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      addTag(tagInput);
    } else if (e.key === 'Backspace' && !tagInput && tags.length) {
      removeTag(tags[tags.length - 1]);
    }
  };

  const categoryOptions = useMemo(
    () => [{ value: '', label: 'No category' }, ...categories.map((c) => ({ value: c.uuid, label: c.name }))],
    [categories],
  );

  const buildPayload = (): PostInput => ({
    title: title.trim(),
    slug: slug.trim() || undefined,
    excerpt: excerpt.trim() || undefined,
    content_html: contentHtml,
    content_json: contentJson,
    featured_image_url: featuredImage.trim() || undefined,
    status,
    visibility,
    is_featured: isFeatured,
    category_uuid: categoryUuid || '',
    tags,
    author_name: authorName.trim() || undefined,
    scheduled_at: status === 'scheduled' ? scheduledAt || undefined : undefined,
    seo_title: seoTitle.trim() || undefined,
    seo_description: seoDescription.trim() || undefined,
    seo_keywords: seoKeywords.trim() || undefined,
  });

  const save = async (overrideStatus?: PostStatus) => {
    if (!title.trim()) {
      toast.error('Title is required');
      return;
    }
    setSaving(true);
    try {
      const payload = buildPayload();
      if (overrideStatus) payload.status = overrideStatus;
      if (isEdit && post) {
        await cmsService.updatePost(post.uuid, payload);
        toast.success('Post updated');
      } else {
        await cmsService.createPost(payload);
        toast.success('Post created');
      }
      router.push('/dashboard/cms?tab=posts');
    } catch (err) {
      const serverMsg = (err as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(serverMsg || (err instanceof Error ? err.message : 'Save failed'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Top bar */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="sm" onClick={() => router.push('/dashboard/cms?tab=posts')}>
            <ArrowLeft className="mr-1 h-4 w-4" /> Back
          </Button>
          <h1 className="text-xl font-bold text-secondary-900 sm:text-2xl">
            {isEdit ? 'Edit Post' : 'New Post'}
          </h1>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => save('draft')} disabled={saving}>
            Save draft
          </Button>
          <Button size="sm" onClick={() => save()} disabled={saving}>
            {saving ? <Loader2 className="mr-1 h-4 w-4 animate-spin" /> : <Save className="mr-1 h-4 w-4" />}
            {status === 'published' ? 'Publish' : 'Save'}
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        {/* Main column */}
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <div className="space-y-4">
              <Input
                label="Title"
                value={title}
                onChange={(e) => handleTitleChange(e.target.value)}
                placeholder="Your post title"
              />
              <Input
                label="Slug"
                value={slug}
                onChange={(e) => handleSlugChange(e.target.value)}
                onBlur={handleSlugBlur}
                helperText="Auto-generated from the title. Edit it to set your own URL."
                placeholder="your-post-title"
              />
              <Textarea
                label="Excerpt"
                value={excerpt}
                onChange={(e) => setExcerpt(e.target.value)}
                placeholder="Short summary shown in listings and search results."
                rows={3}
              />
            </div>
          </Card>

          <Card>
            <label className="mb-2 block text-sm font-medium text-secondary-700">Content</label>
            <RichTextEditor
              value={contentHtml}
              placeholder="Write your article…"
              onChange={(html, json) => {
                setContentHtml(html);
                setContentJson(json);
              }}
            />
          </Card>

          {/* SEO */}
          <Card>
            <button
              type="button"
              onClick={() => setShowSeo((s) => !s)}
              className="flex w-full items-center justify-between text-left"
            >
              <span className="font-semibold text-secondary-900">SEO settings</span>
              <span className="text-sm text-secondary-500">{showSeo ? 'Hide' : 'Show'}</span>
            </button>
            {showSeo && (
              <div className="mt-4 space-y-4">
                <Input label="SEO title" value={seoTitle} onChange={(e) => setSeoTitle(e.target.value)} />
                <Textarea
                  label="Meta description"
                  value={seoDescription}
                  onChange={(e) => setSeoDescription(e.target.value)}
                  rows={2}
                />
                <Input
                  label="Keywords"
                  value={seoKeywords}
                  onChange={(e) => setSeoKeywords(e.target.value)}
                  helperText="Comma-separated"
                />
              </div>
            )}
          </Card>
        </div>

        {/* Sidebar */}
        <div className="space-y-4">
          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Publish</h3>
            <div className="space-y-3">
              <Select label="Status" value={status} onChange={(e) => setStatus(e.target.value as PostStatus)}>
                {STATUS_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </Select>
              {status === 'scheduled' && (
                <Input
                  label="Publish date"
                  type="datetime-local"
                  value={scheduledAt ? scheduledAt.slice(0, 16) : ''}
                  onChange={(e) => setScheduledAt(e.target.value)}
                />
              )}
              <Select
                label="Visibility"
                value={visibility}
                onChange={(e) => setVisibility(e.target.value as PostVisibility)}
              >
                <option value="public">Public</option>
                <option value="private">Private</option>
              </Select>
              <label className="flex cursor-pointer items-center gap-2 text-sm text-secondary-700">
                <input
                  type="checkbox"
                  checked={isFeatured}
                  onChange={(e) => setIsFeatured(e.target.checked)}
                  className="h-4 w-4 rounded border-secondary-300 text-primary-600"
                />
                <Star className="h-4 w-4" /> Featured post
              </label>
            </div>
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Category</h3>
            <Select value={categoryUuid} onChange={(e) => setCategoryUuid(e.target.value)}>
              {categoryOptions.map((o) => (
                <option key={o.value || 'none'} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Tags</h3>
            <Input
              value={tagInput}
              onChange={(e) => setTagInput(e.target.value)}
              onKeyDown={onTagKeyDown}
              onBlur={() => addTag(tagInput)}
              placeholder="Type a tag and press Enter"
            />
            {tags.length > 0 && (
              <div className="mt-3 flex flex-wrap gap-2">
                {tags.map((t) => (
                  <span
                    key={t}
                    className="inline-flex items-center gap-1 rounded-full bg-primary-500/10 px-2.5 py-1 text-xs font-medium text-primary-600"
                  >
                    {t}
                    <button type="button" onClick={() => removeTag(t)} aria-label={`Remove ${t}`}>
                      <X className="h-3 w-3" />
                    </button>
                  </span>
                ))}
              </div>
            )}
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Featured image</h3>
            <Input
              value={featuredImage}
              onChange={(e) => setFeaturedImage(e.target.value)}
              placeholder="https://…/image.jpg"
              leftIcon={<Eye className="h-4 w-4" />}
            />
            {featuredImage && (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                src={featuredImage}
                alt="Featured preview"
                className="mt-3 h-32 w-full rounded-lg object-cover"
                onError={(e) => ((e.target as HTMLImageElement).style.display = 'none')}
              />
            )}
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Author</h3>
            <Input
              value={authorName}
              onChange={(e) => setAuthorName(e.target.value)}
              placeholder="Defaults to you"
            />
          </Card>
        </div>
      </div>
    </div>
  );
}
