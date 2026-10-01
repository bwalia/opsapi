# @opsapi/client

The TypeScript client for [OpsAPI](https://github.com/bwalia/opsapi). It works in Node.js 20+, browsers, Next.js, Deno, Bun and edge runtimes.

- **Every endpoint is typed**: paths, parameters, request bodies and responses, generated from OpsAPI's OpenAPI spec. Your editor completes them and the compiler catches mistakes.
- **Your plugins are typed too.** Generate types from your own server and the client knows your plugin's resources, fields and enums.
- **Sign-in**: API keys, or email and password with two-factor codes, plus token refresh.
- **Workspaces**: pick one by UUID or slug, and switch at any time.
- **Robust by default**: errors are thrown as `OpsApiError`, with timeouts and retries for safe requests.
- **Helpers**: iterate any list with pagination helpers, and verify webhook signatures.

```bash
npm install @opsapi/client
```

## Quick start

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

Requests use [openapi-fetch](https://openapi-ts.dev/openapi-fetch/): `GET`, `POST`, `PUT`, `PATCH` and `DELETE` with the API path. Path parameters go in `params.path`, query strings in `params.query` and JSON in `body`. The response is `{ data, response }`, where `data` is OpsAPI's `{ success, data, meta }` envelope.

## Signing in

**API keys** suit servers, scripts and integrations. A workspace admin creates one (`POST /api/v2/api-keys` or the dashboard), scoped to the modules it may use. Pass it as `token`.

**Users** sign in with their password. Accounts with two-factor authentication get a code by email:

```ts
const opsapi = createClient({ baseUrl: 'https://api.example.com' });

const result = await opsapi.auth.login({ username: 'ada@example.com', password });
if (result.status === 'needs_2fa') {
  const code = await askUserForCode();
  await opsapi.auth.verify2fa({ sessionToken: result.sessionToken, code });
}
// Signed in: later calls carry the token and the user's default workspace.
```

Keep the refresh token from the login result to renew sessions:

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

The workflow checks that the tag matches `package.json`, then type-checks, tests, builds and publishes. It needs the repository secret `NPM_TOKEN`: an npm automation token with publish rights on the `@opsapi` scope.

## License

[MIT](LICENSE)
