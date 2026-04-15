import type { Metadata } from 'next';
import { Callout } from '@/components/docs/Callout';
import { CodeBlock } from '@/components/docs/CodeBlock';

const baseUrl = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

export const metadata: Metadata = {
  title: 'Guides — OpsAPI Docs',
};

const loginCurl = `curl -X POST ${baseUrl}/api/v2/auth/login \\
  -H 'Content-Type: application/json' \\
  -d '{"email":"you@example.com","password":"..."}'`;

const firstCallCurl = `curl ${baseUrl}/api/v2/users \\
  -H "Authorization: Bearer $OPSAPI_TOKEN"`;

const firstCallJs = `const res = await fetch('${baseUrl}/api/v2/users', {
  headers: { Authorization: \`Bearer \${token}\` },
});
const users = await res.json();`;

export default function GuidesPage() {
  return (
    <div className="space-y-10">
      <header>
        <h1 className="text-3xl font-bold tracking-tight text-secondary-900">
          Getting started
        </h1>
        <p className="mt-2 text-secondary-600">
          Authenticate, make your first call, and wire OpsAPI into your app.
        </p>
      </header>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold text-secondary-900">
          1. Authenticate
        </h2>
        <p className="max-w-2xl text-sm text-secondary-600">
          Every request (except a handful of public endpoints) requires a JWT
          in the{' '}
          <code className="rounded bg-secondary-100 px-1 py-0.5 font-mono text-xs">
            Authorization
          </code>{' '}
          header.
        </p>
        <CodeBlock
          tabs={[{ label: 'curl', language: 'bash', code: loginCurl }]}
        />
        <Callout kind="warning">
          JWTs are sensitive credentials. Never commit them to source control
          or log them to stdout in production.
        </Callout>
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold text-secondary-900">
          2. Make your first call
        </h2>
        <CodeBlock
          tabs={[
            { label: 'curl', language: 'bash', code: firstCallCurl },
            { label: 'JavaScript', language: 'javascript', code: firstCallJs },
          ]}
        />
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold text-secondary-900">
          3. Explore the full reference
        </h2>
        <p className="text-sm text-secondary-600">
          The reference is generated live from the OpsAPI server — as soon as
          you add a table, its CRUD endpoints appear.
        </p>
      </section>
    </div>
  );
}
