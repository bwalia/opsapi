'use client';

import AuthShell from '@/components/auth/AuthShell';
import ForgotPasswordPanel from '@/components/auth/ForgotPasswordPanel';

export default function ForgotPasswordPage() {
  return (
    <AuthShell>
      <ForgotPasswordPanel />
    </AuthShell>
  );
}
