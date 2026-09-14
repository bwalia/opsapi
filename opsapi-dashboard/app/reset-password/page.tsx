'use client';

import { Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import AuthShell, { AuthLoader } from '@/components/auth/AuthShell';
import ResetPasswordPanel from '@/components/auth/ResetPasswordPanel';

// useSearchParams must live under a Suspense boundary (Next App Router), so the
// token read is isolated in an inner component.
function ResetPasswordInner() {
  const token = useSearchParams().get('token');
  return (
    <AuthShell>
      <ResetPasswordPanel token={token} />
    </AuthShell>
  );
}

export default function ResetPasswordPage() {
  return (
    <Suspense fallback={<AuthLoader />}>
      <ResetPasswordInner />
    </Suspense>
  );
}
