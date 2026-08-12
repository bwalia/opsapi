'use client';

import React, { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { PostEditor } from '@/components/cms';
import { cmsService, type CmsPost } from '@/services/cms.service';
import { Button } from '@/components/ui';
import toast from 'react-hot-toast';

export default function EditPostPage() {
  const params = useParams();
  const router = useRouter();
  const uuid = String(params?.uuid ?? '');

  const [post, setPost] = useState<CmsPost | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    let active = true;
    cmsService
      .getPost(uuid)
      .then((p) => {
        if (active) setPost(p);
      })
      .catch(() => {
        if (active) {
          setError(true);
          toast.error('Post not found');
        }
      })
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [uuid]);

  return (
    <ProtectedPage module="cms" action="update" title="Edit Post">
      {loading ? (
        <div className="flex items-center justify-center py-24">
          <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
        </div>
      ) : error || !post ? (
        <div className="flex flex-col items-center justify-center gap-4 py-24">
          <p className="text-secondary-600">This post could not be loaded.</p>
          <Button variant="outline" onClick={() => router.push('/dashboard/cms?tab=posts')}>
            Back to posts
          </Button>
        </div>
      ) : (
        <PostEditor post={post} />
      )}
    </ProtectedPage>
  );
}
