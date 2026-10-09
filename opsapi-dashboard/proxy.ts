import { NextResponse, type NextRequest } from 'next/server';

/**
 * A workspace's custom form domain (forms.acme.com) serves its public forms
 * (/f/…) and nothing else of the dashboard. Whether a host is one comes from
 * the API (GET /api/v2/public/form-domains/check, the same question the edge
 * asks before issuing a certificate), cached per host for a minute. If the
 * API can't be reached, the host is treated as the dashboard.
 */

const API = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
const TTL_MS = 60_000;
const known = new Map<string, { custom: boolean; at: number }>();

function maybeCustom(host: string): boolean {
  return host.includes('.') && !/^[\d.]+$/.test(host) && !host.startsWith('[') && !host.endsWith('.localhost');
}

async function isCustomDomain(host: string): Promise<boolean> {
  const hit = known.get(host);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.custom;
  let custom = false;
  try {
    const res = await fetch(`${API}/api/v2/public/form-domains/check?domain=${encodeURIComponent(host)}`,
      { signal: AbortSignal.timeout(2000) });
    custom = res.status === 200;
  } catch {
    // API unreachable: serve the dashboard as usual.
  }
  if (known.size > 5000) known.clear();
  known.set(host, { custom, at: Date.now() });
  return custom;
}

export async function proxy(req: NextRequest) {
  const host = (req.headers.get('x-forwarded-host') || req.headers.get('host') || '').split(',')[0].trim()
    .replace(/:\d+$/, '').toLowerCase();
  if (!maybeCustom(host) || req.nextUrl.pathname.startsWith('/f/')) return NextResponse.next();
  if (!(await isCustomDomain(host))) return NextResponse.next();
  return new NextResponse('Not found', { status: 404, headers: { 'Content-Type': 'text/plain' } });
}

// Pages only: built assets and public files (anything with an extension) pass straight through.
export const config = {
  matcher: ['/((?!_next/|.*\\.[\\w]+$).*)'],
};
