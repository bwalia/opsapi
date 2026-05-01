import Link from 'next/link';
import {
  ArrowRight,
  Database,
  Layers,
  LineChart,
  ShieldCheck,
  Zap,
} from 'lucide-react';
import { CodeBlock } from '@/components/docs/CodeBlock';

const baseUrl = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

const features = [
  {
    icon: Zap,
    title: 'Auto-generated APIs',
    body: 'REST endpoints materialize directly from your PostgreSQL schema. Add a table, get an API.',
  },
  {
    icon: Database,
    title: 'PostgreSQL-native',
    body: 'No ORM guessing, no codegen drift. The database is the single source of truth.',
  },
  {
    icon: ShieldCheck,
    title: 'JWT + Keycloak',
    body: 'Built-in auth flows, role-based access, and OIDC integration out of the box.',
  },
  {
    icon: Layers,
    title: 'Multi-tenant namespaces',
    body: 'Isolate customers with namespace-scoped data and quotas.',
  },
  {
    icon: LineChart,
    title: 'Observability',
    body: 'Prometheus metrics, Grafana dashboards, and structured logging wired in from day one.',
  },
];

const quickStart = `# 1. Log in and capture a JWT
TOKEN=$(curl -sX POST ${baseUrl}/api/v2/auth/login \\
  -H 'Content-Type: application/json' \\
  -d '{"email":"you@example.com","password":"..."}' | jq -r .token)

# 2. List the first page of users
curl ${baseUrl}/api/v2/users?page=1 \\
  -H "Authorization: Bearer $TOKEN"`;

export const dynamic = 'force-dynamic';

export default function DocsHomePage() {
  return (
    <div className="space-y-14">
      <section className="space-y-5">
        <div className="inline-flex items-center gap-2 rounded-full border border-secondary-200 px-3 py-1 text-xs text-secondary-600">
          <span className="h-1.5 w-1.5 rounded-full bg-accent-500" />
          OpsAPI — automated REST APIs on PostgreSQL
        </div>
        <h1 className="text-4xl font-bold tracking-tight text-secondary-900 md:text-5xl">
          Ship a production API{' '}
          <span className="text-primary-500">in minutes</span>, not sprints.
        </h1>
        <p className="max-w-2xl text-lg text-secondary-600">
          OpsAPI turns your PostgreSQL schema into a versioned, secure,
          observable REST API. Browse the reference, copy a snippet, and test
          it live in Swagger.
        </p>
        <div className="flex flex-wrap gap-3">
          <Link
            href="/docs/api"
            className="inline-flex items-center gap-2 rounded-md bg-primary-500 px-4 py-2 text-sm font-medium text-white hover:bg-primary-600"
          >
            Explore the API <ArrowRight className="h-4 w-4" />
          </Link>
          <Link
            href="/docs/use-cases"
            className="inline-flex items-center gap-2 rounded-md border border-secondary-200 px-4 py-2 text-sm font-medium text-secondary-700 hover:border-primary-500 hover:text-primary-600"
          >
            See use cases
          </Link>
          <a
            href={`${baseUrl}/swagger`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-md border border-secondary-200 px-4 py-2 text-sm font-medium text-secondary-700 hover:border-primary-500 hover:text-primary-600"
          >
            Open Swagger UI
          </a>
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-xs font-semibold uppercase tracking-wider text-secondary-500">
          Try it in 60 seconds
        </h2>
        <CodeBlock
          tabs={[{ label: 'curl', language: 'bash', code: quickStart }]}
        />
      </section>

      <section>
        <h2 className="mb-6 text-2xl font-semibold text-secondary-900">
          Why OpsAPI
        </h2>
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {features.map((f) => {
            const Icon = f.icon;
            return (
              <div
                key={f.title}
                className="rounded-xl border border-secondary-200 p-5 transition hover:border-primary-500/50 hover:shadow-sm"
              >
                <div className="inline-flex h-9 w-9 items-center justify-center rounded-md bg-primary-50 text-primary-500">
                  <Icon className="h-5 w-5" />
                </div>
                <h3 className="mt-3 font-semibold text-secondary-900">
                  {f.title}
                </h3>
                <p className="mt-1 text-sm text-secondary-600">{f.body}</p>
              </div>
            );
          })}
        </div>
      </section>

      <section className="rounded-xl border border-secondary-200 bg-secondary-50 p-6">
        <h2 className="text-lg font-semibold text-secondary-900">
          Quick links
        </h2>
        <div className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
          <Link
            href="/docs/guides"
            className="text-secondary-700 hover:text-primary-600"
          >
            → Authentication & getting started
          </Link>
          <Link
            href="/docs/api"
            className="text-secondary-700 hover:text-primary-600"
          >
            → API reference
          </Link>
          <Link
            href="/docs/use-cases"
            className="text-secondary-700 hover:text-primary-600"
          >
            → Real-world use cases
          </Link>
          <a
            href={`${baseUrl}/swagger`}
            target="_blank"
            rel="noreferrer"
            className="text-secondary-700 hover:text-primary-600"
          >
            → Test in Swagger UI
          </a>
        </div>
      </section>
    </div>
  );
}
