'use client';

import React, { useEffect, useRef, useState } from 'react';
import { Eye, Loader2, Upload } from 'lucide-react';
import { Input } from '@/components/ui';
import { cmsService } from '@/services/cms.service';
import toast from 'react-hot-toast';

type Props = {
  value: string;
  onChange: (url: string) => void;
  /** Post/page slug — when set, object lands at /img/blog/<slug>/cover.* on www. */
  slug?: string;
};

/**
 * Featured image URL + optional direct upload to the public www S3 bucket
 * (POST /api/v2/cms/media). Upload is hidden when the ring has no CMS_PUBLIC_S3_* creds.
 */
export function FeaturedImageField({ value, onChange, slug }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [configured, setConfigured] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    cmsService
      .getMediaConfig()
      .then((c) => {
        if (!cancelled) setConfigured(Boolean(c.configured));
      })
      .catch(() => {
        if (!cancelled) setConfigured(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function onFile(file: File | undefined) {
    if (!file) return;
    if (!file.type.startsWith('image/')) {
      toast.error('Choose an image file (jpeg, png, webp, gif, svg).');
      return;
    }
    setUploading(true);
    try {
      const res = await cmsService.uploadMedia(file, { slug: slug || undefined });
      onChange(res.url);
      toast.success('Image uploaded — save the post to keep it as the featured image.');
    } catch (e) {
      const msg =
        (e as { response?: { data?: { error?: string; message?: string } } })?.response?.data
          ?.error ||
        (e as { response?: { data?: { message?: string } } })?.response?.data?.message ||
        (e instanceof Error ? e.message : 'Upload failed');
      toast.error(String(msg));
    } finally {
      setUploading(false);
      if (inputRef.current) inputRef.current.value = '';
    }
  }

  return (
    <>
      <h3 className="mb-3 font-semibold text-secondary-900">Featured image</h3>
      <Input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder="https://www.workstation.co.uk/img/blog/…/cover.jpg"
        leftIcon={<Eye className="h-4 w-4" />}
      />
      {configured && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <label
            className={`inline-flex h-9 cursor-pointer items-center gap-2 rounded-lg border border-secondary-200 bg-white px-3 text-sm font-medium text-secondary-800 hover:bg-secondary-50 ${
              uploading ? 'pointer-events-none opacity-60' : ''
            }`}
          >
            {uploading ? (
              <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
            ) : (
              <Upload className="h-4 w-4" aria-hidden />
            )}
            {uploading ? 'Uploading…' : 'Upload image'}
            <input
              ref={inputRef}
              type="file"
              accept="image/jpeg,image/png,image/webp,image/gif,image/svg+xml"
              className="sr-only"
              disabled={uploading}
              onChange={(e) => onFile(e.target.files?.[0])}
            />
          </label>
          <p className="text-xs text-secondary-500">
            Publishes to www.workstation.co.uk immediately (S3). Then save the post.
          </p>
        </div>
      )}
      {configured === false && (
        <p className="mt-2 text-xs text-secondary-500">
          Paste a public image URL. Direct upload needs CMS_PUBLIC_S3_* in Vault for this ring.
        </p>
      )}
      {value ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={value}
          alt="Featured preview"
          className="mt-3 h-32 w-full rounded-lg object-cover"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = 'none';
          }}
        />
      ) : null}
    </>
  );
}
