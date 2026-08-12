'use client';

import React from 'react';
import { ProtectedPage } from '@/components/permissions';
import { PageEditor } from '@/components/cms';

export default function NewCmsPage() {
  return (
    <ProtectedPage module="cms" action="create" title="New Page">
      <PageEditor />
    </ProtectedPage>
  );
}
