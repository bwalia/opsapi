'use client';

import React, { useRef, useState } from 'react';
import { ImageIcon, ImageOff, Trash2, Upload } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input } from '@/components/ui';
import { MediaPicker, useMediaConfig } from '@/components/media';
import { cmsService } from '@/services/cms.service';
import { displayUrl, productPhotoPair } from '@/lib/image-tools';
import { SHOP_SEO_LOCALES, type ShopPhoto, type ShopSeoLocale } from '@/types/shop';
import { IconButton, ReorderButtons, moveItem } from './editor-fields';

const LANG: Record<ShopSeoLocale, string> = { en: 'Alt text (English)', fr: 'Alt (français)', nl: 'Alt (Nederlands)' };

/** Default alt text the shop uses when one is left empty: "{name} – {key spec}, photo {n}". */
export function defaultAlt(name: string, keySpec: string | undefined, n: number): string {
  return `${name}${keySpec ? ` – ${keySpec}` : ''}, photo ${n}`;
}

/**
 * Product photos (first = main photo, used for sharing and Google). Upload makes a WebP and a JPEG copy
 * in the media library; picking an existing library image uses it as it is. Alt text per language.
 */
export function ProductPhotosEditor({
  photos,
  onChange,
  name,
  keySpec,
}: {
  photos: ShopPhoto[];
  onChange: (p: ShopPhoto[]) => void;
  name: string;
  keySpec?: string;
}) {
  const config = useMediaConfig();
  const [pickerOpen, setPickerOpen] = useState(false);
  const [uploading, setUploading] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const upload = async (files: FileList | null) => {
    if (!files?.length) return;
    setUploading(true);
    const added: ShopPhoto[] = [];
    try {
      for (const file of Array.from(files)) {
        if (!file.type.startsWith('image/') || file.type === 'image/svg+xml' || file.type === 'image/gif') {
          toast.error(`"${file.name}": choose a JPEG, PNG or WebP photo`);
          continue;
        }
        const pair = await productPhotoPair(file);
        const [webp, jpeg] = await Promise.all([
          cmsService.uploadMedia(pair.webp, { filename: `${pair.base}.webp`, width: pair.width, height: pair.height, title: name }),
          cmsService.uploadMedia(pair.jpeg, { filename: `${pair.base}.jpg`, width: pair.width, height: pair.height, title: name }),
        ]);
        added.push({ url: webp.url, fallback_url: jpeg.url, width: pair.width, height: pair.height, alt: {} });
      }
      if (added.length) {
        onChange([...photos, ...added]);
        toast.success(`${added.length} photo${added.length === 1 ? '' : 's'} added. Save the product to keep them.`);
      }
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'The photo could not be uploaded');
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const setAlt = (i: number, loc: ShopSeoLocale, v: string) =>
    onChange(photos.map((p, j) => (j === i ? { ...p, alt: { ...p.alt, [loc]: v } } : p)));

  return (
    <div className="space-y-3">
      {photos.length === 0 && (
        <p className="text-sm text-secondary-500">
          No photos yet. The shop shows the drawing from Images below and makes a share image with the name and price. Use your own photos, or ones you have the right to use.
        </p>
      )}
      {photos.map((p, i) => {
        const src = displayUrl(p.url, config?.site_url);
        return (
          <div key={`${p.url}-${i}`} className="flex flex-col gap-3 rounded-lg border border-secondary-200 p-3 sm:flex-row">
            <div className="flex h-24 w-32 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-secondary-50">
              {src ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={src} alt="" className="h-full w-full object-contain" />
              ) : (
                <ImageOff className="h-5 w-5 text-secondary-300" aria-hidden />
              )}
            </div>
            <div className="flex-1 space-y-2">
              <p className="text-xs text-secondary-500">
                {i === 0 ? 'Main photo · ' : ''}
                {p.width && p.height ? `${p.width} × ${p.height} px` : 'size unknown'}
                {p.fallback_url ? ' · WebP + JPEG' : ''}
              </p>
              {SHOP_SEO_LOCALES.map((loc) => (
                <Input
                  key={loc}
                  aria-label={`${LANG[loc]}, photo ${i + 1}`}
                  placeholder={`${LANG[loc]}: ${loc === 'en' ? defaultAlt(name, keySpec, i + 1) : 'empty = English or the default'}`}
                  value={p.alt?.[loc] ?? ''}
                  maxLength={250}
                  onChange={(e) => setAlt(i, loc, e.target.value)}
                />
              ))}
            </div>
            <div className="flex shrink-0 items-start">
              <ReorderButtons index={i} count={photos.length} onMove={(d) => onChange(moveItem(photos, i, d))} />
              <IconButton label="Remove photo" danger onClick={() => onChange(photos.filter((_, j) => j !== i))}>
                <Trash2 className="h-4 w-4" />
              </IconButton>
            </div>
          </div>
        );
      })}
      <div className="flex flex-wrap gap-2">
        <input
          ref={fileRef}
          type="file"
          accept="image/jpeg,image/png,image/webp"
          multiple
          className="hidden"
          onChange={(e) => upload(e.target.files)}
        />
        <Button type="button" size="sm" variant="outline" leftIcon={<Upload className="h-4 w-4" />} isLoading={uploading} onClick={() => fileRef.current?.click()}>
          Upload photos
        </Button>
        <Button type="button" size="sm" variant="ghost" leftIcon={<ImageIcon className="h-4 w-4" />} onClick={() => setPickerOpen(true)}>
          Choose from the media library
        </Button>
      </div>
      <p className="text-xs text-secondary-500">
        Alt text describes the photo for people who can&apos;t see it, e.g. &ldquo;{defaultAlt(name || 'Product', keySpec, 1).replace('photo 1', 'front view')}&rdquo;.
      </p>
      <MediaPicker
        isOpen={pickerOpen}
        onClose={() => setPickerOpen(false)}
        title="Choose a product photo"
        onPick={(a) =>
          onChange([...photos, { url: a.url, fallback_url: null, width: a.width ?? null, height: a.height ?? null, alt: a.alt_text ? { en: a.alt_text } : {} }])
        }
      />
    </div>
  );
}
