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

  it('reads routes registered with app:match (AI assistant status, AI usage)', async () => {
    const status = await opsapi.GET('/api/chat/agent/status');
    expect((status.data as { data: { status: string } }).data.status).toBeTruthy();
    const usage = await opsapi.GET('/api/v2/namespace/ai-usage', { params: { query: { days: 7 } as never } });
    expect((usage.data as { data: { totals: unknown } }).data.totals).toBeTruthy();
  });

  it('creates, reads and deletes a record', async () => {
    const email = `sdk-live-${Date.now()}@e2e.invalid`;
    const created = await opsapi.POST('/api/v2/customers', { body: { email, first_name: 'SDK', last_name: 'Live' } as never });
    const record = created.data as { data?: { uuid: string }; uuid?: string };
    const uuid = record.data?.uuid ?? record.uuid;
    expect(uuid).toBeTruthy();
    const read = await opsapi.GET('/api/v2/customers/{id}', { params: { path: { id: uuid! } } } as never);
    expect(JSON.stringify(read.data)).toContain(email);
    await opsapi.DELETE('/api/v2/customers/{id}', { params: { path: { id: uuid! } } } as never);
    const gone = await opsapi.GET('/api/v2/customers/{id}', { params: { path: { id: uuid! } } } as never).catch((e) => e);
    expect(gone).toBeInstanceOf(OpsApiError);
    expect(gone.isNotFound).toBe(true);
  });

  it('turns a 401 into OpsApiError', async () => {
    const anonymous = createClient({ baseUrl: baseUrl!, namespace });
    const err = await anonymous.GET('/api/v2/namespace/activity/members').catch((e) => e);
    expect(err).toBeInstanceOf(OpsApiError);
    expect(err.isUnauthorized).toBe(true);
  });
});
