'use client';

/**
 * Where GitHub sends people back (docs/AI_RUNNER.md §28.3): the GitHub App's setup URL and callback URL.
 *   ?installation_id=…&setup_action=install|update  the App was installed (or its repositories changed): sign in to
 *                                                   GitHub so it can confirm you can reach that installation
 *   ?code=…&state=…                                 back from that sign-in: connect the installation to this workspace
 *   ?setup_action=request                           an organisation owner has to approve the install first
 * ai_runners.manage only; the state names the workspace and the person who started it.
 */
import React, { Suspense, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { AlertTriangle, CheckCircle2, GitBranch } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Card } from '@/components/ui';
import { AiRunnerPage, BASE } from '@/components/ai-runner/ui';
import { aiRunner, aiErrorText } from '@/services/ai-runner.service';

export default function GithubCallbackPage() {
  return (
    <AiRunnerPage module="ai_runners" action="manage">
      <Suspense fallback={null}>
        <Callback />
      </Suspense>
    </AiRunnerPage>
  );
}

type Outcome = { kind: 'working' | 'done' | 'error'; text: string };

function Callback() {
  const params = useSearchParams();
  const [outcome, setOutcome] = useState<Outcome>({ kind: 'working', text: 'Connecting GitHub…' });
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return; // a code can be used once
    started.current = true;
    const code = params.get('code');
    const state = params.get('state');
    const installation = Number(params.get('installation_id'));
    (async () => {
      try {
        if (code && state) {
          const i = await aiRunner.githubConnect(code, state);
          setOutcome({ kind: 'done', text: `Connected ${i.account_login || 'the GitHub account'}. The built-in runner now offers its repositories.` });
        } else if (installation > 0) {
          setOutcome({ kind: 'working', text: 'Signing in to GitHub to confirm the installation…' });
          window.location.assign((await aiRunner.githubAuthorize(installation)).url);
        } else if (params.get('setup_action') === 'request') {
          setOutcome({ kind: 'error', text: 'GitHub sent the install to an organisation owner for approval. Once they approve it, use Connect GitHub again.' });
        } else if (params.get('error')) {
          setOutcome({ kind: 'error', text: `GitHub didn't connect: ${params.get('error_description') || params.get('error')}.` });
        } else {
          setOutcome({ kind: 'error', text: 'Nothing to connect here. Use Connect GitHub on Runners & sources.' });
        }
      } catch (e) {
        setOutcome({ kind: 'error', text: aiErrorText(e) });
      }
    })();
  }, [params]);

  const Icon = outcome.kind === 'done' ? CheckCircle2 : outcome.kind === 'error' ? AlertTriangle : GitBranch;
  return (
    <div className="space-y-6">
      <PageHeader title="Connect GitHub" description="For the built-in runner's repositories." icon={<GitBranch className="h-6 w-6" />} />
      <Card className="max-w-2xl">
        <p className={`flex items-start gap-2 text-sm ${outcome.kind === 'error' ? 'text-error-700' : outcome.kind === 'done' ? 'text-success-700' : 'text-secondary-700'}`}
          role={outcome.kind === 'error' ? 'alert' : 'status'} data-testid="air-github-outcome">
          <Icon className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> {outcome.text}
        </p>
        {outcome.kind !== 'working' && (
          <p className="mt-4 text-sm">
            <Link className="text-primary-600 underline" href={`${BASE}/runners`}>Back to Runners &amp; sources</Link>
          </p>
        )}
      </Card>
    </div>
  );
}
