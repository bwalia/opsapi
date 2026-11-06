'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Cropper, { type Area } from 'react-easy-crop';
import { Loader2, RotateCcw, RotateCw } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button } from '@/components/ui';
import { cmsService, type MediaAsset } from '@/services/cms.service';
import { apiErrorText, loadImage, renderEdit } from '@/lib/image-tools';

const SHAPES: { key: string; label: string; ratio?: number }[] = [
  { key: 'original', label: 'Original shape' },
  { key: 'square', label: 'Square', ratio: 1 },
  { key: '4:3', label: '4:3', ratio: 4 / 3 },
  { key: '16:9', label: 'Wide 16:9', ratio: 16 / 9 },
  { key: 'social', label: 'Featured / social 1.91:1', ratio: 1200 / 630 },
];

type Props = {
  asset: MediaAsset;
  /** A URL the browser can load for this image */
  src: string;
  onCancel: () => void;
  onSaved: (copy: MediaAsset) => void;
};

/**
 * Crop, rotate and resize an image in the browser, then upload the result as
 * a NEW library image linked to the original (posts using the original keep it).
 */
export function ImageEditor({ asset, src, onCancel, onSaved }: Props) {
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [rotation, setRotation] = useState(0);
  const [shape, setShape] = useState('original');
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  const [area, setArea] = useState<Area | null>(null);
  const [width, setWidth] = useState('');
  const [widthTouched, setWidthTouched] = useState(false);
  const [saving, setSaving] = useState(false);
  // null = checking, false = this site doesn't let us read the pixels
  const [editable, setEditable] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    loadImage(src, true)
      .then(() => !cancelled && setEditable(true))
      .catch(() => !cancelled && setEditable(false));
    return () => {
      cancelled = true;
    };
  }, [src]);

  const sideways = rotation % 180 !== 0;
  const originalRatio = natural ? (sideways ? natural.h / natural.w : natural.w / natural.h) : 1;
  const aspect = SHAPES.find((s) => s.key === shape)?.ratio ?? originalRatio;

  const onCropComplete = useCallback(
    (_: Area, pixels: Area) => {
      setArea(pixels);
      if (!widthTouched) setWidth(String(Math.round(pixels.width)));
    },
    [widthTouched],
  );

  const outWidth = Number(width);
  const widthOk = Number.isFinite(outWidth) && outWidth >= 16 && outWidth <= 8000;
  const outHeight = area && widthOk ? Math.round((outWidth * area.height) / area.width) : null;

  async function save() {
    if (!area || !widthOk) return;
    setSaving(true);
    try {
      const out = await renderEdit(src, area, rotation, outWidth, asset.mime_type || 'image/png');
      const base = (asset.filename || 'image').replace(/\.[a-z0-9]+$/i, '');
      const ext = out.type === 'image/jpeg' ? 'jpg' : out.type.split('/')[1];
      const copy = await cmsService.uploadMedia(out.blob, {
        filename: `${base}-edited.${ext}`,
        alt_text: asset.alt_text || undefined,
        title: asset.title ? `${asset.title} (edited)` : undefined,
        width: out.width,
        height: out.height,
        source_uuid: asset.uuid,
      });
      toast.success('Saved as a new image. The original is unchanged.');
      onSaved(copy);
    } catch (e) {
      toast.error(apiErrorText(e, 'The edited image could not be saved.'));
    } finally {
      setSaving(false);
    }
  }

  if (editable === false) {
    return (
      <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-6 text-sm text-secondary-700">
        <p className="font-medium text-secondary-900">This image can&apos;t be edited here</p>
        <p className="mt-1">
          It is stored on another website, which doesn&apos;t let the editor read it. Save the image to your
          computer, upload it to the library, and then edit the uploaded copy.
        </p>
        <Button variant="outline" className="mt-4" onClick={onCancel}>
          Back to the library
        </Button>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="relative h-72 overflow-hidden rounded-lg bg-secondary-900 sm:h-96">
        {editable === null ? (
          <div className="flex h-full items-center justify-center text-secondary-200">
            <Loader2 className="h-6 w-6 animate-spin" aria-label="Loading image" />
          </div>
        ) : (
          <Cropper
            image={src}
            crop={crop}
            zoom={zoom}
            rotation={rotation}
            aspect={aspect}
            onCropChange={setCrop}
            onZoomChange={setZoom}
            onCropComplete={onCropComplete}
            onMediaLoaded={(m) => setNatural({ w: m.naturalWidth, h: m.naturalHeight })}
            mediaProps={{ crossOrigin: 'anonymous' } as React.ImgHTMLAttributes<HTMLElement>}
          />
        )}
      </div>

      <div className="flex flex-wrap gap-2" role="group" aria-label="Crop shape">
        {SHAPES.map((s) => (
          <button
            key={s.key}
            type="button"
            onClick={() => setShape(s.key)}
            aria-pressed={shape === s.key}
            className={`rounded-full border px-3 py-1.5 text-sm ${
              shape === s.key
                ? 'border-primary-600 bg-primary-50 font-medium text-primary-700'
                : 'border-secondary-200 bg-surface text-secondary-700 hover:bg-secondary-50'
            }`}
          >
            {s.label}
          </button>
        ))}
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <label className="block text-sm text-secondary-700">
          Zoom
          <input
            type="range"
            min={1}
            max={4}
            step={0.05}
            value={zoom}
            onChange={(e) => setZoom(Number(e.target.value))}
            className="mt-2 block w-full accent-primary-600"
          />
        </label>
        <div className="text-sm text-secondary-700">
          Rotate
          <div className="mt-1 flex gap-2">
            <Button variant="outline" size="sm" onClick={() => setRotation((r) => (r + 270) % 360)} aria-label="Rotate left">
              <RotateCcw className="h-4 w-4" />
            </Button>
            <Button variant="outline" size="sm" onClick={() => setRotation((r) => (r + 90) % 360)} aria-label="Rotate right">
              <RotateCw className="h-4 w-4" />
            </Button>
          </div>
        </div>
        <label className="block text-sm text-secondary-700">
          Width in pixels
          <input
            type="number"
            inputMode="numeric"
            min={16}
            max={8000}
            value={width}
            onChange={(e) => {
              setWidth(e.target.value);
              setWidthTouched(true);
            }}
            className="mt-1 block h-9 w-full rounded-lg border border-secondary-200 bg-surface px-3 text-sm"
          />
          <span className={`mt-1 block text-xs ${widthOk ? 'text-secondary-500' : 'text-red-600'}`}>
            {widthOk ? (outHeight ? `Height follows: ${outHeight} px` : '') : 'Use a width from 16 to 8000.'}
          </span>
        </label>
      </div>

      <p className="text-xs text-secondary-500">
        Saving makes a new image. The original stays as it is, so posts that already use it don&apos;t change.
        {asset.mime_type === 'image/gif' || asset.mime_type === 'image/svg+xml'
          ? ' GIF and SVG images are saved as PNG (animation is lost).'
          : ''}
      </p>

      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={onCancel} disabled={saving}>
          Cancel
        </Button>
        <Button onClick={save} disabled={saving || !area || !widthOk} isLoading={saving}>
          Save as a new image
        </Button>
      </div>
    </div>
  );
}
