'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import AuthShell, { AuthLoader } from '@/components/auth/AuthShell';
import OtpPanel from '@/components/auth/OtpPanel';

export default function VerifyOtpPage() {
  const router = useRouter();
  const [session, setSession] = useState<{ token: string; email: string } | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const token = sessionStorage.getItem('2fa_session_token') || '';
    const email = sessionStorage.getItem('2fa_email') || '';
    if (!token || !email) {
      router.replace('/login');
      return;
    }
    setSession({ token, email });
    setReady(true);
  }, [router]);

  if (!ready || !session) return <AuthLoader />;

  return (
    <AuthShell>
      <OtpPanel sessionToken={session.token} email={session.email} />
    </AuthShell>
  );
}
