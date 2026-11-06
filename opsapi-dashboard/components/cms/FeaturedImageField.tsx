'use client';

import React, { useState } from 'react';
import { ImageIcon, Link2, X } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import { MediaPicker, useMediaConfig } from '@/components/media';
import { displayUrl } from '@/lib/image-tools';

type Props = {
  value: string;
  onChange: (url: string) => void;
};

/** Featured image: pick (or upload and crop) from the media library, or paste a link. */
export function FeaturedImageField({ value, onChange }: Props) {
  const [pickerOpen, setPickerOpen] = useState(false);
  const [showLink, setShowLink] = useState(false);
  const [previewFailed, setPreviewFailed] = useState<string | null>(null);
  const config = useMediaConfig();
  const preview = value ? displayUrl(value, config?.site_url) : null;

  return (
    <>
      <h3 className="mb-3 font-semibold text-secondary-900">Featured image</h3>
      {value ? (
        preview && previewFailed !== value ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={preview}
            alt="Featured image preview"
            className="mb-3 h-36 w-full rounded-lg bg-secondary-50 object-cover"
            onError={() => setPreviewFailed(value)}
          />
        ) : (
          <p className="mb-3 break-all rounded-lg bg-secondary-50 p-3 text-xs text-secondary-600">
            No preview here. The image is: {value}
          </p>
        )
      ) : null}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" onClick={() => setPickerOpen(true)} leftIcon={<ImageIcon className="h-4 w-4" />}>
          {value ? 'Change image' : 'Choose image'}
        </Button>
        {value && (
          <Button size="sm" variant="ghost" onClick={() => onChange('')} leftIcon={<X className="h-4 w-4" />}>
            Remove
          </Button>
        )}
        <Button size="sm" variant="ghost" onClick={() => setShowLink((s) => !s)} leftIcon={<Link2 className="h-4 w-4" />}>
          Paste a link
        </Button>
      </div>
      {showLink && (
        <div className="mt-3">
          <Input value={value} onChange={(e) => onChange(e.target.value)} placeholder="https://… or /img/…" aria-label="Featured image link" />
        </div>
      )}
      <p className="mt-2 text-xs text-secondary-500">
        Upload, crop and reuse images from the media library. Save the post to keep your choice.
      </p>
      <MediaPicker
        isOpen={pickerOpen}
        onClose={() => setPickerOpen(false)}
        title="Choose a featured image"
        onPick={(asset) => onChange(asset.url)}
      />
    </>
  );
}
