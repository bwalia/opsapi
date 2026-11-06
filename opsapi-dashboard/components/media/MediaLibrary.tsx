'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Check, Copy, Crop, ImageOff, Loader2, RefreshCw, Search, Trash2, Upload } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Modal, Pagination, confirmDialog } from '@/components/ui';
import {
  cmsService,
  type MediaAsset,
  type MediaConfig,
  type MediaSort,
  type MediaType,
} from '@/services/cms.service';
import {
  MAX_UPLOAD_BYTES,
  UPLOAD_ACCEPT,
  apiErrorText,
  displayUrl,
  formatBytes,
  prepareImage,
} from '@/lib/image-tools';
import { ImageEditor } from './ImageEditor';

const PER_PAGE = 24;
const NOT_SET_UP =
  "Uploading is switched off: this server has no image storage set up yet. Ask your administrator to set up file storage. You can still use images already in the library.";

// Storage is a server setting, the same for every workspace: ask once.
let configRequest: Promise<MediaConfig> | null = null;

export function useMediaConfig(): MediaConfig | null {
  const [config, setConfig] = useState<MediaConfig | null>(null);
  useEffect(() => {
    let cancelled = false;
    configRequest ??= cmsService.getMediaConfig().catch((e) => {
      configRequest = null;
      throw e;
    });
    configRequest
      .then((c) => !cancelled && setConfig(c))
      .catch(() => !cancelled && setConfig({ configured: false }));
    return () => {
      cancelled = true;
    };
  }, []);
  return config;
}

/** Resize/clean a picked file in the browser and add it to the library. Throws a plain-words Error. */
export async function uploadImageFile(file: File, extra: { alt_text?: string } = {}): Promise<MediaAsset> {
  if (!file.type.startsWith('image/')) {
    throw new Error(`"${file.name}" isn't an image. Choose a JPEG, PNG, WebP, GIF or SVG file.`);
  }
  const prepared = await prepareImage(file);
  if (prepared.blob.size > MAX_UPLOAD_BYTES) {
    throw new Error(`"${file.name}" is larger than 8 MB. Make it smaller and try again.`);
  }
  try {
    return await cmsService.uploadMedia(prepared.blob, {
      filename: prepared.filename,
      width: prepared.width,
      height: prepared.height,
      ...extra,
    });
  } catch (e) {
    throw new Error(apiErrorText(e, `"${file.name}" could not be uploaded.`));
  }
}

function Thumb({ asset, siteUrl, className }: { asset: MediaAsset; siteUrl?: string | null; className: string }) {
  const src = displayUrl(asset.url, siteUrl);
  const [failed, setFailed] = useState(false);
  if (!src || failed) {
    return (
      <div className={`flex flex-col items-center justify-center gap-1 text-secondary-400 ${className}`}>
        <ImageOff className="h-6 w-6" aria-hidden />
        <span className="px-2 text-center text-[11px]">{src ? 'Preview not available' : 'On your website'}</span>
      </div>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt={asset.alt_text || ''}
      loading="lazy"
      onError={() => setFailed(true)}
      className={`object-contain ${className}`}
    />
  );
}

type Props = {
  /** pick: choosing an image for content (shows "Use this image") */
  mode?: 'manage' | 'pick';
  onPick?: (asset: MediaAsset) => void;
};

/** The workspace's image library: browse, search, upload, edit, describe, delete — and pick. */
export function MediaLibrary({ mode = 'manage', onPick }: Props) {
  const config = useMediaConfig();
  const siteUrl = config?.site_url;
  const canUpload = Boolean(config?.configured);

  const [items, setItems] = useState<MediaAsset[]>([]);
  const [meta, setMeta] = useState({ page: 1, per_page: PER_PAGE, total: 0, total_pages: 1 });
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [type, setType] = useState<MediaType | ''>('');
  const [sort, setSort] = useState<MediaSort>('newest');
  const [loadedKey, setLoadedKey] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  const requestKey = JSON.stringify([query, type, sort, page, reloadKey]);
  const loading = loadedKey !== requestKey;

  const [selected, setSelected] = useState<MediaAsset | null>(null);
  const [altDraft, setAltDraft] = useState('');
  const [titleDraft, setTitleDraft] = useState('');
  const [savingInfo, setSavingInfo] = useState(false);
  const [editing, setEditing] = useState(false);
  const [uploading, setUploading] = useState<{ done: number; total: number } | null>(null);
  const [dragging, setDragging] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      setQuery(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let cancelled = false;
    const key = requestKey;
    cmsService
      .listMedia({ search: query || undefined, type, sort, page, per_page: PER_PAGE })
      .then((res) => {
        if (cancelled) return;
        setItems(res.items);
        setMeta(res.meta);
        setError(null);
      })
      .catch((e) => !cancelled && setError(apiErrorText(e, 'The library could not be loaded.')))
      .finally(() => !cancelled && setLoadedKey(key));
    return () => {
      cancelled = true;
    };
  }, [query, type, sort, page, reloadKey, requestKey]);

  const reload = () => setReloadKey((k) => k + 1);

  const select = useCallback(async (asset: MediaAsset) => {
    setSelected(asset);
    setAltDraft(asset.alt_text || '');
    setTitleDraft(asset.title || '');
    setEditing(false);
    try {
      const full = await cmsService.getMedia(asset.uuid);
      setSelected((cur) => (cur?.uuid === asset.uuid ? full : cur));
    } catch {
      // keep the list copy; "used in" just won't show
    }
  }, []);

  /** Show the newest images (where an upload lands), then select `asset`. */
  function showNewest(asset?: MediaAsset) {
    setSearch('');
    setQuery('');
    setType('');
    setSort('newest');
    setPage(1);
    reload();
    if (asset) void select(asset);
  }

  async function upload(files: File[]) {
    if (!files.length) return;
    if (!canUpload) {
      toast.error(NOT_SET_UP);
      return;
    }
    setUploading({ done: 0, total: files.length });
    let last: MediaAsset | undefined;
    let ok = 0;
    for (const [i, f] of files.entries()) {
      try {
        last = await uploadImageFile(f);
        ok += 1;
      } catch (e) {
        toast.error(e instanceof Error ? e.message : 'Upload failed.');
      }
      setUploading({ done: i + 1, total: files.length });
    }
    setUploading(null);
    if (fileRef.current) fileRef.current.value = '';
    if (ok) {
      toast.success(ok === 1 ? 'Image uploaded.' : `${ok} images uploaded.`);
      showNewest(last);
    }
  }

  async function saveInfo() {
    if (!selected) return;
    setSavingInfo(true);
    try {
      const updated = await cmsService.updateMedia(selected.uuid, { alt_text: altDraft, title: titleDraft });
      setSelected(updated);
      setItems((list) => list.map((i) => (i.uuid === updated.uuid ? { ...i, ...updated } : i)));
      toast.success('Saved.');
    } catch (e) {
      toast.error(apiErrorText(e, 'The details could not be saved.'));
    } finally {
      setSavingInfo(false);
    }
  }

  async function remove(asset: MediaAsset) {
    const used = asset.used_in ?? [];
    const link = asset.storage === 'link';
    const names = used
      .slice(0, 3)
      .map((u) => `"${u.title}"`)
      .join(', ');
    const where = used.length
      ? `It is used in ${used.length} ${used.length === 1 ? 'post or page' : 'posts and pages'} (${names}${
          used.length > 3 ? ', …' : ''
        }). `
      : '';
    const ok = await confirmDialog({
      title: link ? 'Remove this image from the library?' : 'Delete this image?',
      message: link
        ? `${where}The file stays where it is, so nothing that shows it changes. Only the library entry is removed.`
        : `${where}${used.length ? 'They will show a broken image. ' : ''}The file is removed for good. This can't be undone.`,
      confirmText: link ? 'Remove from library' : 'Delete image',
      danger: true,
    });
    if (!ok) return;
    try {
      await cmsService.deleteMedia(asset.uuid);
      toast.success(link ? 'Removed from the library.' : 'Image deleted.');
      setSelected(null);
      reload();
    } catch (e) {
      toast.error(apiErrorText(e, 'The image could not be deleted.'));
    }
  }

  async function copyLink(asset: MediaAsset) {
    const url = displayUrl(asset.url, siteUrl) || asset.url;
    try {
      await navigator.clipboard.writeText(url);
      toast.success('Link copied.');
    } catch {
      toast.error("Couldn't copy. Select the link and copy it yourself: " + url);
    }
  }

  const selectedSrc = selected ? displayUrl(selected.url, siteUrl) : null;

  if (editing && selected && selectedSrc) {
    return (
      <div>
        <h3 className="mb-3 text-sm font-semibold text-secondary-900">
          Edit “{selected.title || selected.filename || 'image'}”
        </h3>
        <ImageEditor
          asset={selected}
          src={selectedSrc}
          onCancel={() => setEditing(false)}
          onSaved={(copy) => showNewest(copy)}
        />
      </div>
    );
  }

  const infoChanged = selected && (altDraft !== (selected.alt_text || '') || titleDraft !== (selected.title || ''));

  return (
    <div
      className="relative"
      onDragOver={(e) => {
        if (!Array.from(e.dataTransfer.types).includes('Files')) return;
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setDragging(false);
      }}
      onDrop={(e) => {
        e.preventDefault();
        setDragging(false);
        void upload(Array.from(e.dataTransfer.files));
      }}
    >
      {dragging && (
        <div className="pointer-events-none absolute inset-0 z-10 flex items-center justify-center rounded-xl border-2 border-dashed border-primary-500 bg-primary-50/90 text-sm font-medium text-primary-700">
          Drop images here to upload them
        </div>
      )}

      {/* Toolbar */}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative min-w-48 flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" aria-hidden />
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search by name or description"
            aria-label="Search images"
            className="h-9 w-full rounded-lg border border-secondary-200 bg-surface pl-9 pr-3 text-sm"
          />
        </div>
        <select
          value={type}
          onChange={(e) => {
            setType(e.target.value as MediaType | '');
            setPage(1);
          }}
          aria-label="Image type"
          className="h-9 rounded-lg border border-secondary-200 bg-surface px-2 text-sm"
        >
          <option value="">All types</option>
          <option value="jpeg">JPEG photos</option>
          <option value="png">PNG</option>
          <option value="webp">WebP</option>
          <option value="gif">GIF</option>
          <option value="svg">SVG</option>
        </select>
        <select
          value={sort}
          onChange={(e) => {
            setSort(e.target.value as MediaSort);
            setPage(1);
          }}
          aria-label="Sort"
          className="h-9 rounded-lg border border-secondary-200 bg-surface px-2 text-sm"
        >
          <option value="newest">Newest first</option>
          <option value="oldest">Oldest first</option>
          <option value="name">Name</option>
          <option value="largest">Largest files</option>
        </select>
        <label
          className={`inline-flex h-9 cursor-pointer items-center gap-2 rounded-lg bg-primary-600 px-3 text-sm font-medium text-white hover:bg-primary-700 focus-within:ring-2 focus-within:ring-primary-400 ${
            uploading || !canUpload ? 'pointer-events-none opacity-60' : ''
          }`}
          title={canUpload ? undefined : NOT_SET_UP}
        >
          {uploading ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Upload className="h-4 w-4" aria-hidden />}
          {uploading ? `Uploading ${Math.min(uploading.done + 1, uploading.total)} of ${uploading.total}…` : 'Upload from computer'}
          <input
            ref={fileRef}
            type="file"
            multiple
            accept={UPLOAD_ACCEPT}
            className="sr-only"
            disabled={Boolean(uploading) || !canUpload}
            onChange={(e) => void upload(Array.from(e.target.files ?? []))}
          />
        </label>
      </div>

      {config && !canUpload && (
        <p className="mb-4 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">{NOT_SET_UP}</p>
      )}

      <div className="flex flex-col gap-4 lg:flex-row">
        {/* Grid */}
        <div className="min-w-0 flex-1">
          {error ? (
            <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
              {error}
              <Button variant="outline" size="sm" className="ml-3" onClick={reload} leftIcon={<RefreshCw className="h-4 w-4" />}>
                Try again
              </Button>
            </div>
          ) : loading && items.length === 0 ? (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4" aria-busy="true" aria-label="Loading images">
              {Array.from({ length: 8 }).map((_, i) => (
                <div key={i} className="aspect-square animate-pulse rounded-lg bg-secondary-100" />
              ))}
            </div>
          ) : items.length === 0 ? (
            <div className="rounded-xl border border-dashed border-secondary-300 p-10 text-center text-sm text-secondary-600">
              {query || type ? (
                'No images match. Try another search or type.'
              ) : (
                <>
                  <p className="font-medium text-secondary-900">No images yet</p>
                  <p className="mt-1">Upload images from your computer, or drag them here. They can then be used in any post or page.</p>
                </>
              )}
            </div>
          ) : (
            <>
              <ul className={`grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4 ${loading ? 'opacity-60' : ''}`}>
                {items.map((a) => {
                  const active = selected?.uuid === a.uuid;
                  return (
                    <li key={a.uuid}>
                      <button
                        type="button"
                        onClick={() => void select(a)}
                        onDoubleClick={() => mode === 'pick' && onPick?.(a)}
                        aria-pressed={active}
                        aria-label={a.title || a.alt_text || a.filename || 'Image'}
                        className={`group relative block aspect-square w-full overflow-hidden rounded-lg border bg-[repeating-conic-gradient(var(--color-secondary-100)_0_25%,transparent_0_50%)] bg-[length:16px_16px] focus:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 ${
                          active ? 'border-primary-600 ring-2 ring-primary-500' : 'border-secondary-200 hover:border-secondary-400'
                        }`}
                      >
                        <Thumb asset={a} siteUrl={siteUrl} className="h-full w-full" />
                        <span className="absolute inset-x-0 bottom-0 truncate bg-black/55 px-2 py-1 text-left text-xs text-white">
                          {a.title || a.filename || 'Image'}
                        </span>
                        {active && (
                          <span className="absolute right-1.5 top-1.5 rounded-full bg-primary-600 p-0.5 text-white">
                            <Check className="h-3.5 w-3.5" aria-hidden />
                          </span>
                        )}
                      </button>
                    </li>
                  );
                })}
              </ul>
              {meta.total_pages > 1 && (
                <Pagination
                  className="mt-4"
                  currentPage={meta.page}
                  totalPages={meta.total_pages}
                  totalItems={meta.total}
                  perPage={meta.per_page}
                  onPageChange={setPage}
                />
              )}
            </>
          )}
        </div>

        {/* Details */}
        <aside className="w-full shrink-0 lg:w-72" aria-label="Image details">
          {!selected ? (
            <div className="rounded-xl border border-secondary-200 p-4 text-sm text-secondary-500">
              {mode === 'pick' ? 'Click an image to choose it, or upload a new one.' : 'Click an image to see its details.'}
            </div>
          ) : (
            <div className="space-y-3 rounded-xl border border-secondary-200 p-4">
              <div className="overflow-hidden rounded-lg bg-secondary-50">
                <Thumb asset={selected} siteUrl={siteUrl} className="h-40 w-full" />
              </div>
              <div className="text-sm">
                <p className="break-all font-medium text-secondary-900">{selected.filename || 'Image'}</p>
                <p className="text-xs text-secondary-500">
                  {[
                    selected.mime_type?.replace('image/', '').replace('+xml', '').toUpperCase(),
                    formatBytes(selected.size_bytes),
                    selected.width && selected.height ? `${selected.width} × ${selected.height} px` : '',
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
                {selected.storage === 'link' && (
                  <p className="mt-1 text-xs text-secondary-500">Already on your website (added from your posts).</p>
                )}
                {selected.source_uuid && <p className="mt-1 text-xs text-secondary-500">An edited copy.</p>}
              </div>

              {mode === 'pick' && onPick && (
                <Button className="w-full" onClick={() => onPick(selected)} leftIcon={<Check className="h-4 w-4" />}>
                  Use this image
                </Button>
              )}

              <label className="block text-xs font-medium text-secondary-700">
                Description (alt text)
                <textarea
                  value={altDraft}
                  onChange={(e) => setAltDraft(e.target.value)}
                  rows={2}
                  maxLength={1000}
                  placeholder="What does the image show?"
                  className="mt-1 block w-full rounded-lg border border-secondary-200 bg-surface px-2 py-1.5 text-sm font-normal"
                />
                <span className="mt-0.5 block font-normal text-secondary-500">
                  Read out by screen readers and used by search engines.
                </span>
              </label>
              <label className="block text-xs font-medium text-secondary-700">
                Title
                <input
                  value={titleDraft}
                  onChange={(e) => setTitleDraft(e.target.value)}
                  maxLength={255}
                  className="mt-1 block h-8 w-full rounded-lg border border-secondary-200 bg-surface px-2 text-sm font-normal"
                />
              </label>
              {infoChanged && (
                <Button size="sm" variant="secondary" onClick={saveInfo} isLoading={savingInfo}>
                  Save details
                </Button>
              )}

              {selected.used_in && (
                <div className="text-xs text-secondary-600">
                  <p className="font-medium text-secondary-700">Used in</p>
                  {selected.used_in.length === 0 ? (
                    <p>Not used in any post or page yet.</p>
                  ) : (
                    <ul className="mt-1 space-y-0.5">
                      {selected.used_in.map((u) => (
                        <li key={`${u.kind}-${u.uuid}`}>
                          <Link
                            href={`/dashboard/cms/${u.kind === 'post' ? 'posts' : 'pages'}/${u.uuid}`}
                            className="text-primary-700 underline-offset-2 hover:underline"
                          >
                            {u.title || 'Untitled'}
                          </Link>{' '}
                          <span className="text-secondary-400">
                            ({u.kind}, {u.status})
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              )}

              <div className="flex flex-wrap gap-2 border-t border-secondary-100 pt-3">
                <Button size="sm" variant="outline" onClick={() => copyLink(selected)} leftIcon={<Copy className="h-4 w-4" />}>
                  Copy link
                </Button>
                {selectedSrc && canUpload && (
                  <Button size="sm" variant="outline" onClick={() => setEditing(true)} leftIcon={<Crop className="h-4 w-4" />}>
                    Crop / resize
                  </Button>
                )}
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-red-600 hover:bg-red-50"
                  onClick={() => remove(selected)}
                  leftIcon={<Trash2 className="h-4 w-4" />}
                >
                  {selected.storage === 'link' ? 'Remove' : 'Delete'}
                </Button>
              </div>
            </div>
          )}
        </aside>
      </div>
    </div>
  );
}

/** A dialog to choose an image from the library (or upload one) for content. */
export function MediaPicker({
  isOpen,
  onClose,
  onPick,
  title = 'Choose an image',
}: {
  isOpen: boolean;
  onClose: () => void;
  onPick: (asset: MediaAsset) => void;
  title?: string;
}) {
  return (
    <Modal isOpen={isOpen} onClose={onClose} title={title} size="3xl">
      {isOpen && (
        <MediaLibrary
          mode="pick"
          onPick={(asset) => {
            onPick(asset);
            onClose();
          }}
        />
      )}
    </Modal>
  );
}
