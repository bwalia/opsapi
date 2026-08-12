'use client';

import React, { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Save, Loader2 } from 'lucide-react';
import { Button, Input, Textarea, Select, Card } from '@/components/ui';
import { RichTextEditor } from '@/components/academy';
import { cmsService, type CmsPage, type PageInput, type PageStatus } from '@/services/cms.service';
import { renderTemplatesService, type RenderTemplate } from '@/services/render-templates.service';
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

// Gentle normalisation while typing in the slug field (keeps a trailing hyphen
// so hyphenated slugs are actually typable); full slugify runs on blur.
function normalizeSlugInput(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+/, '');
}

const STATUS_OPTIONS: { value: PageStatus; label: string }[] = [
  { value: 'draft', label: 'Draft' },
  { value: 'published', label: 'Published' },
  { value: 'archived', label: 'Archived' },
];

interface PageEditorProps {
  page?: CmsPage;
}

export default function PageEditor({ page }: PageEditorProps) {
  const router = useRouter();
  const isEdit = Boolean(page);

  const [saving, setSaving] = useState(false);
  const [title, setTitle] = useState(page?.title ?? '');
  const [slug, setSlug] = useState(page?.slug ?? '');
  const [slugTouched, setSlugTouched] = useState(isEdit);
  const [excerpt, setExcerpt] = useState(page?.excerpt ?? '');
  const [contentHtml, setContentHtml] = useState(page?.content_html ?? '');
  const [contentJson, setContentJson] = useState(page?.content_json ?? '');
  const [status, setStatus] = useState<PageStatus>(page?.status ?? 'draft');
  const [template, setTemplate] = useState(page?.template ?? 'default');
  const [pageTemplates, setPageTemplates] = useState<RenderTemplate[]>([]);

  // Load the namespace's page-layout templates for the picker.
  useEffect(() => {
    renderTemplatesService
      .list('cms_page')
      .then(setPageTemplates)
      .catch(() => setPageTemplates([]));
  }, []);
  const [menuOrder, setMenuOrder] = useState<number>(page?.menu_order ?? 0);
  const [showInNav, setShowInNav] = useState<boolean>(page?.show_in_nav ?? false);
  const [featuredImage, setFeaturedImage] = useState(page?.featured_image_url ?? '');

  const [seoTitle, setSeoTitle] = useState(page?.seo_title ?? '');
  const [seoDescription, setSeoDescription] = useState(page?.seo_description ?? '');
  const [seoKeywords, setSeoKeywords] = useState(page?.seo_keywords ?? '');
  const [showSeo, setShowSeo] = useState(false);

  // Auto-derive the slug from the title until the user edits the slug directly.
  const handleTitleChange = (v: string) => {
    setTitle(v);
    if (!slugTouched) setSlug(slugify(v));
  };
  const handleSlugChange = (v: string) => {
    setSlugTouched(true);
    setSlug(normalizeSlugInput(v));
  };
  const handleSlugBlur = () => setSlug((s) => slugify(s));

  const buildPayload = (): PageInput => ({
    title: title.trim(),
    slug: slug.trim() || undefined,
    excerpt: excerpt.trim() || undefined,
    content_html: contentHtml,
    content_json: contentJson,
    featured_image_url: featuredImage.trim() || undefined,
    status,
    template: template.trim() || 'default',
    menu_order: Number.isFinite(menuOrder) ? menuOrder : 0,
    show_in_nav: showInNav,
    seo_title: seoTitle.trim() || undefined,
    seo_description: seoDescription.trim() || undefined,
    seo_keywords: seoKeywords.trim() || undefined,
  });

  const save = async (overrideStatus?: PageStatus) => {
    if (!title.trim()) {
      toast.error('Title is required');
      return;
    }
    setSaving(true);
    try {
      const payload = buildPayload();
      if (overrideStatus) payload.status = overrideStatus;
      if (isEdit && page) {
        await cmsService.updatePage(page.uuid, payload);
        toast.success('Page updated');
      } else {
        await cmsService.createPage(payload);
        toast.success('Page created');
      }
      router.push('/dashboard/cms?tab=pages');
    } catch (err) {
      const serverMsg = (err as { response?: { data?: { error?: string } } })?.response?.data?.error;
      toast.error(serverMsg || (err instanceof Error ? err.message : 'Save failed'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="sm" onClick={() => router.push('/dashboard/cms?tab=pages')}>
            <ArrowLeft className="mr-1 h-4 w-4" /> Back
          </Button>
          <h1 className="text-xl font-bold text-secondary-900 sm:text-2xl">
            {isEdit ? 'Edit Page' : 'New Page'}
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
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <div className="space-y-4">
              <Input label="Title" value={title} onChange={(e) => handleTitleChange(e.target.value)} placeholder="About Us" />
              <Input
                label="Slug"
                value={slug}
                onChange={(e) => handleSlugChange(e.target.value)}
                onBlur={handleSlugBlur}
                helperText="Auto-generated from the title. Edit it to set your own URL."
                placeholder="about-us"
              />
              <Textarea
                label="Excerpt"
                value={excerpt}
                onChange={(e) => setExcerpt(e.target.value)}
                placeholder="Short summary (optional)."
                rows={2}
              />
            </div>
          </Card>

          <Card>
            <label className="mb-2 block text-sm font-medium text-secondary-700">Content</label>
            <RichTextEditor
              value={contentHtml}
              placeholder="Write your page content…"
              onChange={(html, json) => {
                setContentHtml(html);
                setContentJson(json);
              }}
            />
          </Card>

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

        <div className="space-y-4">
          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Publish</h3>
            <div className="space-y-3">
              <Select label="Status" value={status} onChange={(e) => setStatus(e.target.value as PageStatus)}>
                {STATUS_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </Select>
              <label className="flex cursor-pointer items-center gap-2 text-sm text-secondary-700">
                <input
                  type="checkbox"
                  checked={showInNav}
                  onChange={(e) => setShowInNav(e.target.checked)}
                  className="h-4 w-4 rounded border-secondary-300 text-primary-600"
                />
                Show in site navigation
              </label>
              <Input
                label="Menu order"
                type="number"
                value={String(menuOrder)}
                onChange={(e) => setMenuOrder(parseInt(e.target.value, 10) || 0)}
              />
            </div>
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Template</h3>
            <Select value={template} onChange={(e) => setTemplate(e.target.value)}>
              <option value="default">Default (raw content)</option>
              {pageTemplates.map((t) => (
                <option key={t.uuid} value={t.slug}>
                  {t.name}
                  {t.is_default ? ' (default)' : ''}
                </option>
              ))}
            </Select>
            <p className="mt-1.5 text-sm text-secondary-500">
              The layout the public site renders this page into.{' '}
              <a href="/dashboard/cms?tab=templates" className="text-primary-600 hover:underline">
                Manage templates
              </a>
            </p>
          </Card>

          <Card>
            <h3 className="mb-3 font-semibold text-secondary-900">Featured image</h3>
            <Input
              value={featuredImage}
              onChange={(e) => setFeaturedImage(e.target.value)}
              placeholder="https://…/image.jpg"
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
        </div>
      </div>
    </div>
  );
}
