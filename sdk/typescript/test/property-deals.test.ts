import { describe, expect, it, vi } from 'vitest';
import {
  createPropertyDealsClient,
  PROPERTY_DEALS_EVENTS,
  TASK_STATUSES,
  type Today,
} from '../src/property-deals';

const BASE = 'https://api.example.test';

function fakeFetch(body: unknown, status = 200) {
  const calls: Request[] = [];
  const fetch = vi.fn(async (req: Request) => {
    calls.push(req.clone());
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  });
  return { fetch: fetch as unknown as typeof globalThis.fetch, calls };
}

describe('@opsapi/client/property-deals', () => {
  it('calls plugin routes with the token and workspace', async () => {
    const today: Today = {
      counts: { open: 1, overdue: 1, due_today: 0, awaiting_approval: 0 },
      tasks: [{ task_uuid: 't-1', title: 'Book an EPC assessor', pd_status: 'todo' }],
      red_deals: [], approvals_waiting: [],
    };
    const { fetch, calls } = fakeFetch({ success: true, data: today });
    const api = createPropertyDealsClient({ baseUrl: BASE, token: 'jwt', namespace: 'demo-buyers', fetch });
    const { data } = await api.GET('/api/v2/property-deals/today', { params: { query: { limit: 20 } } });
    expect(data?.data.tasks[0]?.title).toBe('Book an EPC assessor');
    expect(calls[0]!.url).toBe(`${BASE}/api/v2/property-deals/today?limit=20`);
    expect(calls[0]!.headers.get('Authorization')).toBe('Bearer jwt');
    expect(calls[0]!.headers.get('X-Namespace-Slug')).toBe('demo-buyers');
  });

  it('types path params and bodies (stage move, approval decision)', async () => {
    const { fetch, calls } = fakeFetch({ success: true, data: {} });
    const api = createPropertyDealsClient({ baseUrl: BASE, token: 'jwt', fetch });
    await api.POST('/api/v2/property-deals/deals/{id}/stage', {
      params: { path: { id: 'd-1' } }, body: { to: 'exchange' },
    });
    await api.POST('/api/v2/property-deals/approvals/{id}/decide', {
      params: { path: { id: 'a-1' } }, body: { decision: 'reject', note: 'Wrong solicitor' },
    });
    expect(calls.map((c) => c.url)).toEqual([
      `${BASE}/api/v2/property-deals/deals/d-1/stage`, `${BASE}/api/v2/property-deals/approvals/a-1/decide`,
    ]);
    expect(await calls[1]!.json()).toEqual({ decision: 'reject', note: 'Wrong solicitor' });
  });

  it('still reaches core routes', async () => {
    const { fetch, calls } = fakeFetch({ success: true, data: [] });
    const api = createPropertyDealsClient({ baseUrl: BASE, token: 'jwt', fetch });
    await api.GET('/api/v2/crm/leads');
    expect(calls[0]!.url).toBe(`${BASE}/api/v2/crm/leads`);
  });

  it('lists statuses and events', () => {
    expect(TASK_STATUSES).toContain('awaiting_approval');
    expect(PROPERTY_DEALS_EVENTS).toContain('property_deals.deal.stage_changed');
  });
});
