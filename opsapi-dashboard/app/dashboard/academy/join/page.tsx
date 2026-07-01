'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { GraduationCap, BookOpen, DollarSign, CheckCircle2, ArrowRight } from 'lucide-react';
import { Button } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { academyService, type InstructorStatus } from '@/services/academy.service';
import toast from 'react-hot-toast';

// Any authenticated dashboard user can reach this page (it is intentionally NOT
// wrapped in ProtectedPage module="courses"): it is where a learner opts in to
// becoming an instructor. Registration grants the "instructor" RBAC role inside
// the single academy namespace — instructors never create their own namespace.

const BENEFITS: { icon: React.ReactNode; title: string; body: string }[] = [
  {
    icon: <BookOpen size={18} />,
    title: 'Publish your own courses',
    body: 'Create courses and rich WYSIWYG lessons. You manage only the content you own.',
  },
  {
    icon: <DollarSign size={18} />,
    title: 'Earn from every sale',
    body: 'Set your price. The platform takes its cut and pays the rest to your bank account.',
  },
  {
    icon: <GraduationCap size={18} />,
    title: 'Reach every learner',
    body: 'Your published courses appear in the academy marketplace alongside everyone else’s.',
  },
];

function JoinAsInstructor() {
  const router = useRouter();
  const { switchNamespace } = useNamespace();

  const [status, setStatus] = useState<InstructorStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setStatus(await academyService.getInstructorStatus());
    } catch (err) {
      console.error('Load instructor status failed:', err);
      toast.error('Could not load your instructor status');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const goToAcademy = useCallback(
    async (ns: InstructorStatus['namespace']) => {
      // Switch the dashboard into the academy namespace so the freshly-granted
      // "courses" permissions load, then hard-reload to apply the new context.
      try {
        await switchNamespace(ns.uuid);
      } catch (err) {
        console.error('Switch to academy namespace failed:', err);
      }
      window.location.href = '/dashboard/academy';
    },
    [switchNamespace]
  );

  const handleRegister = async () => {
    setSubmitting(true);
    try {
      const result = await academyService.registerInstructor();
      toast.success('You are now an instructor');
      await goToAcademy(result.namespace);
    } catch (err) {
      console.error('Instructor registration failed:', err);
      toast.error('Could not complete registration. Please try again.');
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="animate-pulse space-y-4 max-w-2xl mx-auto">
        <div className="h-8 bg-secondary-200 rounded w-1/3" />
        <div className="h-4 bg-secondary-200 rounded w-2/3" />
        <div className="h-40 bg-secondary-200 rounded" />
      </div>
    );
  }

  const alreadyInstructor = status?.is_instructor || status?.is_owner;

  return (
    <div className="max-w-2xl mx-auto space-y-8">
      <div className="text-center">
        <div className="w-14 h-14 mx-auto mb-4 rounded-2xl bg-primary-50 text-primary-600 flex items-center justify-center">
          <GraduationCap size={28} />
        </div>
        <h1 className="text-2xl font-bold text-secondary-900">
          {alreadyInstructor ? 'You’re an instructor' : 'Teach on Academy'}
        </h1>
        <p className="mt-2 text-secondary-500">
          {alreadyInstructor
            ? 'Head to your dashboard to create and manage your courses.'
            : 'Share what you know, build your audience, and earn from your courses.'}
        </p>
      </div>

      {alreadyInstructor ? (
        <div className="bg-surface rounded-xl border border-secondary-200 p-6 text-center space-y-4">
          <div className="inline-flex items-center gap-2 text-success-600">
            <CheckCircle2 size={20} />
            <span className="font-medium">
              {status?.is_owner ? 'You own the academy workspace' : 'Instructor access is active'}
            </span>
          </div>
          <div>
            <Button
              rightIcon={<ArrowRight size={16} />}
              onClick={() => status && goToAcademy(status.namespace)}
            >
              Go to Academy
            </Button>
          </div>
        </div>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-3">
            {BENEFITS.map((b) => (
              <div key={b.title} className="bg-surface rounded-xl border border-secondary-200 p-4">
                <div className="w-9 h-9 rounded-lg bg-primary-50 text-primary-600 flex items-center justify-center mb-3">
                  {b.icon}
                </div>
                <h3 className="text-sm font-semibold text-secondary-900">{b.title}</h3>
                <p className="mt-1 text-xs text-secondary-500 leading-relaxed">{b.body}</p>
              </div>
            ))}
          </div>

          <div className="bg-surface rounded-xl border border-secondary-200 p-6 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
            <div>
              <p className="font-medium text-secondary-900">Ready to start teaching?</p>
              <p className="text-sm text-secondary-500">
                You can add your bank details for payouts later, from Monetization.
              </p>
            </div>
            <Button isLoading={submitting} onClick={handleRegister} rightIcon={<ArrowRight size={16} />}>
              Become an Instructor
            </Button>
          </div>
        </>
      )}

      <div className="text-center">
        <button
          onClick={() => router.push('/dashboard')}
          className="text-sm text-secondary-500 hover:text-secondary-700"
        >
          Back to dashboard
        </button>
      </div>
    </div>
  );
}

export default function JoinAsInstructorPage() {
  return <JoinAsInstructor />;
}
