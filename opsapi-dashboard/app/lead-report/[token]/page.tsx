'use client';

/**
 * The link in the "new lead" email: opens the AI lead report (a PDF kept in the
 * workspace's file storage). The link is signed and expires (30 days); after that
 * the report is on the lead's page in the dashboard.
 */
import React, { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import { FileDown, Loader2, AlertTriangle } from 'lucide-react';

const API = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

export default function LeadReportPage() {
  const { token } = useParams<{ token: string }>();
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let objectUrl: string | null = null;
    let active = true;
    fetch(`${API}/api/v2/public/crm/lead-reports/${encodeURIComponent(token)}`)
      .then(async (res) => {
        if (!res.ok) {
          const body = await res.json().catch(() => null);
          throw new Error(body?.error || 'The report could not be opened. Try again shortly.');
        }
        return res.blob();
      })
      .then((blob) => {
        if (!active) return;
        objectUrl = URL.createObjectURL(blob);
        setUrl(objectUrl);
        window.location.replace(objectUrl);
      })
      .catch((e: Error) => active && setError(e.message));
    return () => {
      active = false;
      if (objectUrl) setTimeout(() => URL.revokeObjectURL(objectUrl as string), 60_000);
    };
  }, [token]);

  return (
    <main className="flex min-h-screen items-center justify-center bg-secondary-50 p-6">
      <div className="w-full max-w-md rounded-2xl border border-secondary-200 bg-white p-6 text-center shadow-sm">
        <h1 className="text-lg font-semibold text-secondary-900">AI lead report</h1>
        {!url && !error && (
          <p className="mt-4 flex items-center justify-center gap-2 text-sm text-secondary-600" role="status">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" /> Opening the report…
          </p>
        )}
        {url && (
          <div className="mt-4 space-y-3">
            <p className="text-sm text-secondary-600">The report should open by itself. If it doesn’t:</p>
            <a href={url} download="lead-report.pdf"
              className="inline-flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700">
              <FileDown className="h-4 w-4" aria-hidden="true" /> Download the PDF
            </a>
          </div>
        )}
        {error && (
          <div className="mt-4 space-y-3" role="alert">
            <p className="flex items-center justify-center gap-2 text-sm text-error-700">
              <AlertTriangle className="h-4 w-4" aria-hidden="true" /> {error}
            </p>
            <Link href="/dashboard/leads" className="inline-flex text-sm font-medium text-primary-600 hover:underline">
              Open Leads in the dashboard
            </Link>
          </div>
        )}
      </div>
    </main>
  );
}
