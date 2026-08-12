'use client';

import React, { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { PageEditor } from '@/components/cms';
import { cmsService, type CmsPage } from '@/services/cms.service';
import { Button } from '@/components/ui';
import toast from 'react-hot-toast';

export default function EditCmsPage() {
  const params = useParams();
  const router = useRouter();
  const uuid = String(params?.uuid ?? '');

  const [page, setPage] = useState<CmsPage | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    let active = true;
    cmsService
      .getPage(uuid)
      .then((p) => {
        if (active) setPage(p);
      })
      .catch(() => {
        if (active) {
          setError(true);
          toast.error('Page not found');
        }
      })
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [uuid]);

  return (
    <ProtectedPage module="cms" action="update" title="Edit Page">
      {loading ? (
        <div className="flex items-center justify-center py-24">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : error || !page ? (
        <div className="flex flex-col items-center justify-center gap-4 py-24">
          <p className="text-secondary-600">This page could not be loaded.</p>
          <Button variant="outline" onClick={() => router.push('/dashboard/cms?tab=pages')}>
            Back to pages
          </Button>
        </div>
      ) : (
        <PageEditor page={page} />
      )}
    </ProtectedPage>
  );
}
