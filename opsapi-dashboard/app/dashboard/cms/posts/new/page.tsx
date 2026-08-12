'use client';

import React from 'react';
import { ProtectedPage } from '@/components/permissions';
import { PostEditor } from '@/components/cms';

export default function NewPostPage() {
  return (
    <ProtectedPage module="cms" action="create" title="New Post">
      <PostEditor />
    </ProtectedPage>
  );
}
