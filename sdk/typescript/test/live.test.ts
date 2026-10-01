/**
 * Against a running OpsAPI (skipped unless configured):
 *   OPSAPI_URL=http://127.0.0.1:4010 OPSAPI_TOKEN=<jwt or API key> OPSAPI_NAMESPACE=<uuid|slug> npx vitest run test/live.test.ts
 */
import { describe, expect, it } from 'vitest';
import { collect, createClient, OpsApiError, paginate, paginateCursor } from '../src/index';

const baseUrl = process.env.OPSAPI_URL;
const token = process.env.OPSAPI_TOKEN;
const namespace = process.env.OPSAPI_NAMESPACE;

describe.skipIf(!baseUrl || !token)('live OpsAPI', () => {
  const opsapi = baseUrl ? createClient({ baseUrl, token, namespace }) : (undefined as never);

  it('reads a typed list with its paging meta', async () => {
    const { data } = await opsapi.GET('/api/v2/namespace/activity/members', { params: { query: { per_page: 5 } as never } });
    expect(data).toBeTruthy();
  });

  it('walks a page-numbered list', async () => {
    const items = await collect(
      paginate((page) =>
        opsapi
          .GET('/api/v2/namespace/activity/members', { params: { query: { page, per_page: 2 } as never } })
          .then((r) => r.data as { data: unknown[]; meta: { total_pages: number } })),
      10,
    );
    expect(Array.isArray(items)).toBe(true);
  });

  it('walks a cursor-paged list (audit trail)', async () => {
    const items = await collect(
      paginateCursor((cursor) =>
        opsapi
          .GET('/api/v2/namespace/activity/changes' as never, { params: { query: { cursor, limit: 2 } } } as never)
          .then((r: { data?: unknown }) => r.data as { data: unknown[]; meta: { next_cursor?: string } })),
      6,
    );
    expect(items.length).toBeGreaterThan(0);
  });

  it('turns a 401 into OpsApiError', async () => {
    const anonymous = createClient({ baseUrl: baseUrl!, namespace });
    const err = await anonymous.GET('/api/v2/namespace/activity/members').catch((e) => e);
    expect(err).toBeInstanceOf(OpsApiError);
    expect(err.isUnauthorized).toBe(true);
  });
});
