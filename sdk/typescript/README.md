# @opsapi/client

The TypeScript client for **[OpsAPI](https://github.com/bwalia/opsapi)**. It works in Node.js 20+, browsers, Next.js, Deno, Bun and edge runtimes.

## What is OpsAPI?

OpsAPI is an open-source, multi-tenant backend for running a business. One server gives you a REST API for customers and CRM, invoices and accounting, timesheets, projects and tasks, employees, e-commerce (stores, products, orders, delivery), chat, documents, UK tax filing (HMRC Making Tax Digital) and more. It also includes users, two-factor sign-in, roles and permissions, API keys, webhooks, an AI assistant and plugins.

**You host OpsAPI yourself.** It ships as a Docker image (`bwalia/opsapi` on Docker Hub) that runs next to a PostgreSQL database. This package is the client your app uses to talk to that server, so you need a running OpsAPI before it can do anything. The next section shows how to start one in about ten minutes.

How the pieces fit:

- **Your OpsAPI server:** the `bwalia/opsapi` container plus PostgreSQL, at an address like `https://api.example.com`.
- **Workspaces:** each customer or company is a *workspace* (also called a *namespace*). Its data is kept apart from every other workspace's, and each workspace has its own members, roles and API keys.
- **Your app:** uses `@opsapi/client`, signed in with an **API key** (for servers and scripts) or as a **user** (email + password + 2FA code), and works inside one workspace.

```bash
npm install @opsapi/client
```

## 1. Run an OpsAPI server

You need [Docker](https://docs.docker.com/get-docker/) with Compose.

### Try it on your machine

Create a folder with these two files.

**`docker-compose.yml`**

```yaml
services:
  db:
    image: pgvector/pgvector:pg16          # PostgreSQL with the pgvector extension
    environment:
      POSTGRES_USER: opsapi
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: opsapi
    volumes:
      - opsapi-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U opsapi -d opsapi"]
      interval: 5s
      retries: 20

  opsapi:
    image: bwalia/opsapi:latest           # in production pin a release tag, e.g. bwalia/opsapi:1.0.182-429
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "4010:80"                          # the API on http://localhost:4010
    env_file: .env
    environment:
      POSTGRES_HOST: db
      POSTGRES_PORT: "5432"
      POSTGRES_USER: opsapi
      POSTGRES_DB: opsapi

volumes:
  opsapi-db:
```

**`.env`**: generate the secrets rather than typing them:

```bash
cat > .env <<EOF
LAPIS_ENVIRONMENT=production
PROJECT_CODE=all
POSTGRES_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET_KEY=$(openssl rand -base64 32)
OPENSSL_SECRET_KEY=$(openssl rand -hex 16)
OPENSSL_SECRET_IV=$(openssl rand -hex 16)
# Local trial only: sign in without email. Remove both lines on a real server.
OPSAPI_DEPLOY_ENV=local
TEST_OTP_CODE=$(openssl rand -hex 4)
EOF
```

Start it, create the tables, then create your admin account and first workspace:

```bash
docker compose up -d
docker compose exec opsapi lapis migrate

docker compose exec opsapi lapis exec "require('scripts.setup-namespace').run({
  admin_email = 'you@example.com', admin_password = 'choose-a-strong-password',
  namespace_name = 'Acme Ltd', namespace_slug = 'acme' })"
```

Check it's up:

- `http://localhost:4010/health` returns `200`.
- `http://localhost:4010/swagger` is the interactive API reference, with every endpoint and its fields.

Signing in always asks for a 6-character code that OpsAPI sends by email. On this local trial there's no email server, so use the `TEST_OTP_CODE` value from your `.env` instead. OpsAPI only accepts that code when `OPSAPI_DEPLOY_ENV` isn't `production`.

### Running it for real

The same image runs in production. Before you go live:

- **Email (required).** Sign-in codes, invitations and password resets are sent by email. Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM_EMAIL` and `SMTP_FROM_NAME`, and **remove** `OPSAPI_DEPLOY_ENV` and `TEST_OTP_CODE`.
- **Keep the secrets safe and stable.** `JWT_SECRET_KEY` signs every session; changing it signs everyone out. `OPENSSL_SECRET_KEY` / `OPENSSL_SECRET_IV` encrypt stored secrets such as vault entries and plugin settings; changing them makes those unreadable. Store them in your secret manager.
- **HTTPS.** Put OpsAPI behind your load balancer or a reverse proxy (Caddy, nginx, Traefik) that terminates TLS. The container listens on port 80.
- **Pin the image and migrate on upgrade.** Use a release tag (`bwalia/opsapi:1.0.x-N`; see the [tags on Docker Hub](https://hub.docker.com/r/bwalia/opsapi/tags)) instead of `latest`. After each upgrade run `docker compose exec opsapi lapis migrate`. Migrations are safe to re-run.
- **Back up PostgreSQL** (for example a nightly `pg_dump`). That's where all the data lives.
- **Browser apps:** to call OpsAPI from a web page on another domain, allow it with `CORS_ALLOWED_DOMAINS=example.com` (covers the domain and its subdomains) or `CORS_ALLOWED_ORIGINS=https://app.example.com`. Calls from `localhost` are always allowed.
- **Pick the modules.** `PROJECT_CODE=all` turns everything on. A narrower code such as `tax_copilot`, `ecommerce` or `crm,invoicing` creates and serves only those modules. Endpoints of modules you leave out return `404`.

## 2. Connect: sign in, then create an API key

Sign in as the admin you created. The code comes by email (or is your `TEST_OTP_CODE` on a local trial):

```ts
import { createClient } from '@opsapi/client';

const opsapi = createClient({ baseUrl: 'http://localhost:4010' });

let session = await opsapi.auth.login({ username: 'you@example.com', password });
if (session.status === 'needs_2fa') {
  session = await opsapi.auth.verify2fa({ sessionToken: session.sessionToken, code: await askForCode() });
}
opsapi.setNamespace('acme');               // the workspace slug (or UUID)
```

For servers, scripts and integrations, use an **API key** instead of a person's login. A key belongs to one workspace and can only use the modules you scope it to:

```ts
const { data } = await opsapi.POST('/api/v2/api-keys', {
  body: { name: 'billing sync', scopes: { customers: ['read', 'create', 'update'], invoices: ['read'] } },
});
const apiKey = data.data.key;              // "opsk_…": shown once, store it in your secret manager
```

You can also create keys in the OpsAPI dashboard under **My Workspace → API Keys**.

## 3. Use it

```ts
import { createClient } from '@opsapi/client';

const opsapi = createClient({
  baseUrl: 'https://api.example.com',
  token: process.env.OPSAPI_KEY,   // an API key or a JWT
  namespace: 'acme',               // workspace slug or UUID
});

const { data } = await opsapi.GET('/api/v2/customers', {
  params: { query: { page: 1, per_page: 50 } },
});

await opsapi.POST('/api/v2/customers', {
  body: { email: 'ada@example.com', first_name: 'Ada' },
});
```

**Every endpoint is typed.** Paths, parameters, request bodies and responses are generated from OpsAPI's OpenAPI spec (over 870 API paths), so your editor completes them and the compiler catches a wrong path or field. To see what an endpoint does, open `/swagger` on your server.

Requests use [openapi-fetch](https://openapi-ts.dev/openapi-fetch/): `GET`, `POST`, `PUT`, `PATCH` and `DELETE` with the API path. Path parameters go in `params.path`, query strings in `params.query` and JSON in `body`. The response is `{ data, response }`, where `data` is OpsAPI's `{ success, data, meta }` envelope.

## Signing in

**API keys** suit servers, scripts and integrations: pass the key as `token`.

**Users** sign in with their password and an emailed code (above). Keep the refresh token from the login result to renew sessions:

```ts
const opsapi = createClient({
  baseUrl,
  token: () => session.accessToken,                // read from your store on every call
  onUnauthorized: async () => {                    // called once on a 401, then the request is retried
    const { token, refreshToken } = await opsapi.auth.refresh(session.refreshToken);
    session.save(token, refreshToken);
    return token;
  },
});
```

`opsapi.auth.logout(refreshToken)` revokes the refresh token. `opsapi.setToken()` and `opsapi.setNamespace()` switch the user or workspace.

**Permissions.** A user can do what their role in the workspace allows; an API key can do what its scopes allow. Anything else is a `403` (`err.isForbidden`). Workspace owners manage roles in the dashboard under **My Workspace → Roles**.

## Errors

A response that isn't 2xx throws an `OpsApiError`:

```ts
import { OpsApiError } from '@opsapi/client';

try {
  await opsapi.POST('/api/v2/customers', { body: { email: 'not-an-email' } });
} catch (err) {
  if (err instanceof OpsApiError && err.isValidation) {
    console.log(err.details); // { email: 'must be a valid email' }
  }
  throw err;
}
```

| | |
|---|---|
| `status` | The HTTP status, or `0` when the request failed (timeout, network). |
| `message` | OpsAPI's error message. |
| `code` | OpsAPI's error code, e.g. `VALIDATION_422`, `CONFLICT_409`, `NOT_FOUND_404`. |
| `context` | Machine-readable specifics, e.g. `{ reason: 'required', field: 'email' }` or `{ reason: 'duplicate', field: 'email' }`. |
| `details` | For some 422 responses: which fields failed validation, as field → message. |
| `body` | The full error response. |
| `isUnauthorized` | 401: missing or bad credentials. |
| `isForbidden` | 403: the user's role doesn't allow it in this workspace. |
| `isNotFound` | 404: doesn't exist, or belongs to another workspace. |
| `isConflict` | 409: a duplicate value, or the record is still referenced by others. |
| `isValidation` | 422: see `details` and `context`. |

A `503` means the server doesn't have an integration this endpoint needs (Stripe, Google, MinIO, …). `GET`, `PUT` and `DELETE` retry it, then throw.

Prefer checking results instead of catching? Pass `throwOnError: false` and calls return `{ data, error, response }`.

## Lists and pagination

```ts
import { paginate, paginateCursor, collect } from '@opsapi/client';

// Page-numbered lists (?page=): fetches the next page as you iterate.
for await (const customer of paginate((page) =>
  opsapi.GET('/api/v2/customers', { params: { query: { page, per_page: 100 } } }).then((r) => r.data))) {
  await sync(customer);
}

// Cursor lists (meta.next_cursor), e.g. the audit trail.
const changes = await collect(
  paginateCursor((cursor) =>
    opsapi.GET('/api/v2/namespace/activity/changes', { params: { query: { cursor } } }).then((r) => r.data)),
  500, // stop after 500
);
```

## Your plugins, typed

OpsAPI plugins add their own APIs, and the server's `/openapi.json` describes them with exact types. Generate types from your server and pass them to the client:

```bash
npx openapi-typescript https://api.example.com/openapi.json -o src/opsapi.d.ts
```

```ts
import { createClient } from '@opsapi/client';
import type { paths, components } from './opsapi';

type Ticket = components['schemas']['HelpdeskTicket'];

const opsapi = createClient<paths>({ baseUrl, token, namespace });

const { data } = await opsapi.GET('/api/v2/helpdesk/tickets', {
  params: { query: { status: 'open', sort: 'priority', order: 'desc' } },
});
const tickets: Ticket[] = data!.data;

await opsapi.POST('/api/v2/helpdesk/tickets', {
  body: { title: 'Printer on fire', status: 'open' },   // status: 'open' | 'pending' | 'closed'
});
```

Wrong field names, enum values, sort columns and missing required fields are all compile errors. Re-run the command when you change a plugin.

For an API key to call a plugin's API, scope the key to one of the plugin's modules, for example `helpdesk_tickets`.

## Webhooks

Verify OpsAPI webhook deliveries before trusting them. This needs the raw request body:

```ts
import { verifyWebhook, WebhookVerificationError } from '@opsapi/client';

// Next.js route handler
export async function POST(req: Request) {
  try {
    const event = await verifyWebhook(await req.text(), req.headers, {
      secret: process.env.OPSAPI_WEBHOOK_SECRET!,
    });
    if (event.type === 'invoice.paid') await thankCustomer(event.data.object);
    return new Response(null, { status: 204 });
  } catch (err) {
    if (err instanceof WebhookVerificationError) return new Response('invalid', { status: 400 });
    throw err;
  }
}
```

With Express, use `express.raw({ type: 'application/json' })` and pass `req.body` (a Buffer) and `req.headers`. Deliveries can arrive more than once, so use `event.id` to skip duplicates.

## Options

| Option | Default | |
|---|---|---|
| `baseUrl` | (required) | Your OpsAPI server, e.g. `https://api.example.com`. |
| `token` | none | An API key or a JWT, or a function returning one (it can be async). |
| `namespace` | the token's own | The workspace, by UUID or slug. |
| `retries` | `2` | Extra attempts for `GET`, `PUT` and `DELETE` on 429, 502, 503, 504 and network errors. They back off exponentially and honour `Retry-After`. `POST` is never retried. |
| `timeoutMs` | `30000` | Abort each attempt after this many milliseconds. |
| `throwOnError` | `true` | `false` returns `{ data, error, response }` instead of throwing. |
| `onUnauthorized` | none | Called once on a 401. Return a new token to retry the request. |
| `headers` | none | Extra headers to send with every request. |
| `fetch` | `globalThis.fetch` | A custom fetch, for tests, proxies or instrumentation. |

## Troubleshooting

| You see | What it means |
|---|---|
| `401` / `err.isUnauthorized` | No token, or it expired. Sign in again, or use `onUnauthorized` to refresh. |
| `403` "Permission denied" | The user's role in this workspace doesn't include that action. A workspace owner can change the role. |
| `403` "API key is not scoped for this endpoint" | Add the module to the key's `scopes`. Older OpsAPI images also refused keys on list/create URLs such as `/api/v2/customers`; update the server to the latest release. |
| `400` "Namespace context required" | Pass `namespace` (slug or UUID) to `createClient`, or call `setNamespace()`. |
| `404` for a whole module | The module isn't switched on: check `PROJECT_CODE` on the server. |
| A CORS error in the browser | Allow your site's origin with `CORS_ALLOWED_DOMAINS` / `CORS_ALLOWED_ORIGINS` on the server. |
| Sign-in fails with "identifier required" | `@opsapi/client` 0.1.0 sent the password in a format the server ignores. Use 0.1.1 or later. |
| No sign-in code arrives | Configure SMTP on the server (see *Running it for real*). |

## Developing this package

```bash
npm install
npm test                 # unit tests (no server needed)
OPSAPI_URL=http://127.0.0.1:4010 OPSAPI_TOKEN=… OPSAPI_NAMESPACE=… npx vitest run test/live.test.ts
OPSAPI_OPENAPI_URL=http://127.0.0.1:4010/openapi.json npm run generate   # refresh the core types
npm run build
```

`npm run generate` leaves out plugin routes (they're marked `x-opsapi-plugin` in the spec), so the published types cover OpsAPI itself. Run it against a server with `PROJECT_CODE=all` so every module is included.

### Releasing

Releases are published to npm by CI ([`sdk-typescript-release.yml`](../../.github/workflows/sdk-typescript-release.yml)) with [provenance](https://docs.npmjs.com/generating-provenance-statements), so you don't run `npm publish` yourself.

1. Bump `version` in `package.json` (`npm version minor --no-git-tag-version`) and add a section to [CHANGELOG.md](CHANGELOG.md).
2. Merge to `main`.
3. Tag the merge commit and push the tag: `git tag sdk-v0.2.0 && git push origin sdk-v0.2.0`.

The workflow checks that the tag matches `package.json`, then type-checks, tests, builds and publishes. It needs the repository secret `NPM_TOKEN`: an npm **granular access token** with *Read and write* on the `@opsapi` scope and *Bypass two-factor authentication* ticked.

npm then **stages** the release: it waits under **npmjs.com → Staged Packages** until a maintainer approves it with their 2FA code. Server builds ignore `sdk-v*` tags, so tagging a `main` commit doesn't change OpsAPI's own version.

## License

[MIT](LICENSE)
