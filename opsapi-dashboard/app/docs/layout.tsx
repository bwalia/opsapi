import type { Metadata } from 'next';
import { DocsLayout } from '@/components/docs/DocsLayout';
import { loadOpenApi } from '@/lib/openapi/loader';
import { parseOpenApi } from '@/lib/openapi/parser';

export const metadata: Metadata = {
  title: 'OpsAPI Docs',
  description:
    'Developer documentation for OpsAPI — automated REST APIs on PostgreSQL.',
};

export const dynamic = 'force-dynamic';

export default async function DocsRootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const doc = await loadOpenApi();
  const domains = parseOpenApi(doc);
  return <DocsLayout domains={domains}>{children}</DocsLayout>;
}
