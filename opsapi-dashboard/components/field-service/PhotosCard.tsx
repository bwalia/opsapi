'use client';

/**
 * PhotosCard — site/fault photos for a job. On a phone the "Add" button opens
 * the camera (capture="environment"); on desktop it's a file picker. Photos go
 * to MinIO via the API and show as a thumbnail grid.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Trash2, Camera, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui';
import { fieldService, type FsJobPhoto } from '@/services/field-service.service';
import { SectionCard, apiError } from './shared';

export function PhotosCard({ jobUuid, visitUuid, canEdit }: { jobUuid: string; visitUuid?: string; canEdit: boolean }) {
  const [photos, setPhotos] = useState<FsJobPhoto[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    try {
      setPhotos(await fieldService.getJobPhotos(jobUuid));
    } catch {
      /* ignore — empty */
    } finally {
      setLoading(false);
    }
  }, [jobUuid]);

  useEffect(() => {
    load();
  }, [load]);

  const onFiles = async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    setUploading(true);
    try {
      for (const f of Array.from(files)) {
        await fieldService.uploadJobPhoto(jobUuid, f, { visit_uuid: visitUuid });
      }
      toast.success(files.length > 1 ? 'Photos added' : 'Photo added');
      await load();
    } catch (err) {
      toast.error(apiError(err, 'Upload failed'));
    } finally {
      setUploading(false);
      if (inputRef.current) inputRef.current.value = '';
    }
  };

  const remove = async (uuid: string) => {
    try {
      await fieldService.deleteJobPhoto(uuid);
      setPhotos((p) => p.filter((x) => x.uuid !== uuid));
    } catch (err) {
      toast.error(apiError(err, 'Could not remove the photo'));
    }
  };

  return (
    <SectionCard
      title="Photos"
      actions={
        canEdit ? (
          <Button size="sm" variant="ghost" leftIcon={<Camera className="w-4 h-4" />} onClick={() => inputRef.current?.click()} isLoading={uploading}>
            Add
          </Button>
        ) : undefined
      }
    >
      <input ref={inputRef} type="file" accept="image/*" capture="environment" multiple hidden onChange={(e) => onFiles(e.target.files)} />
      {loading ? (
        <div className="flex items-center gap-2 text-sm text-secondary-500"><Loader2 className="w-4 h-4 animate-spin" /> Loading…</div>
      ) : photos.length === 0 ? (
        <p className="text-sm text-secondary-500">{canEdit ? 'Tap Add to take or attach a photo.' : 'No photos.'}</p>
      ) : (
        <div className="grid grid-cols-3 sm:grid-cols-4 gap-2">
          {photos.map((p) => (
            <div key={p.uuid} className="relative group aspect-square">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={p.url} alt={p.caption || 'Job photo'} loading="lazy" className="w-full h-full object-cover rounded-lg border border-secondary-200 bg-secondary-100" />
              {canEdit && (
                <button
                  type="button"
                  onClick={() => remove(p.uuid)}
                  aria-label="Remove photo"
                  className="absolute top-1 right-1 rounded-full bg-black/60 text-white p-1 opacity-0 group-hover:opacity-100 transition"
                >
                  <Trash2 className="w-3.5 h-3.5" />
                </button>
              )}
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  );
}

export default PhotosCard;
