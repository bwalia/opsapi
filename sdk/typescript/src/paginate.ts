/**
 * Paging info OpsAPI list endpoints return. Endpoints differ: most put it in
 * `meta` (snake_case or camelCase), some at the top level, and some send none.
 */
export interface PageMeta {
  page?: number;
  per_page?: number;
  perPage?: number;
  limit?: number;
  total?: number;
  total_pages?: number;
  totalPages?: number;
  next_cursor?: string | null;
  nextCursor?: string | null;
}

/**
 * One page as an endpoint returns it. The item type is inferred from `data`;
 * other shapes (items under `items`, paging info at the top level, …) work
 * too: pass the type, e.g. `paginate<Ticket>(…)`, or `options.items`.
 */
// `object`: endpoints whose spec doesn't describe the list (`data: {}`) still
// type-check; their items are `unknown` unless you pass the type.
export type PageResult<T> = { data?: T[] | object | null; meta?: PageMeta | null; [key: string]: unknown } | null | undefined;

export interface PageOptions<T> {
  /** Stop after this many pages. */
  maxPages?: number;
  /** Where the items are, for responses that keep them somewhere else, e.g. `(r) => r.notifications`. */
  items?: (page: any) => T[] | null | undefined; // eslint-disable-line @typescript-eslint/no-explicit-any
}

function itemsOf<T>(result: unknown, select?: PageOptions<T>['items']): T[] {
  if (select) return select(result) ?? [];
  if (Array.isArray(result)) return result as T[];
  const r = result as { data?: unknown; items?: unknown } | null | undefined;
  if (Array.isArray(r?.data)) return r.data as T[];
  if (Array.isArray(r?.items)) return r.items as T[];
  const nested = (r?.data as { items?: unknown } | null | undefined)?.items;
  return Array.isArray(nested) ? (nested as T[]) : [];
}

function metaOf(result: unknown): PageMeta {
  if (!result || typeof result !== 'object' || Array.isArray(result)) return {};
  const r = result as PageMeta & { meta?: PageMeta | null };
  return { ...r, ...(r.meta ?? {}) };
}

/** Total number of pages, when the response says (directly or via total + page size). */
function totalPagesOf(meta: PageMeta): number | undefined {
  const pages = meta.total_pages ?? meta.totalPages;
  if (typeof pages === 'number') return pages;
  const size = meta.per_page ?? meta.perPage ?? meta.limit;
  if (typeof meta.total === 'number' && typeof size === 'number' && size > 0) return Math.ceil(meta.total / size);
  return undefined;
}

const keyOf = (item: unknown): string => {
  const o = item as { uuid?: unknown; id?: unknown } | null;
  return o && typeof o === 'object' && (o.uuid ?? o.id) != null ? String(o.uuid ?? o.id) : JSON.stringify(item);
};

/**
 * Every item of a page-numbered list (?page=), fetching pages as you iterate:
 *
 *   for await (const ticket of paginate((page) =>
 *     opsapi.GET('/api/v2/helpdesk/tickets', { params: { query: { page, per_page: 100 } } }).then((r) => r.data))) { … }
 *
 * Stops at the last page (from `total_pages`/`totalPages`, or `total` and the
 * page size), on an empty page, and on an endpoint that isn't paginated (it
 * returns the same items for page 2), so it never loops.
 */
export async function* paginate<T>(
  fetchPage: (page: number) => Promise<PageResult<T>>,
  options: PageOptions<T> = {},
): AsyncGenerator<T, void, undefined> {
  const maxPages = options.maxPages ?? Infinity;
  let previousFirst: string | undefined;
  for (let page = 1; page <= maxPages; page++) {
    const result = await fetchPage(page);
    const items = itemsOf<T>(result, options.items);
    if (items.length === 0) return;
    const first = keyOf(items[0]);
    if (page > 1 && first === previousFirst) return; // the endpoint ignored ?page
    previousFirst = first;
    yield* items;
    const totalPages = totalPagesOf(metaOf(result));
    if (typeof totalPages === 'number' && page >= totalPages) return;
  }
}

/**
 * Every item of a cursor-paged list (`next_cursor`), e.g. the activity log:
 *
 *   for await (const change of paginateCursor((cursor) =>
 *     opsapi.GET('/api/v2/namespace/activity/changes', { params: { query: { cursor } } }).then((r) => r.data))) { … }
 */
export async function* paginateCursor<T>(
  fetchPage: (cursor: string | undefined) => Promise<PageResult<T>>,
  options: PageOptions<T> = {},
): AsyncGenerator<T, void, undefined> {
  const maxPages = options.maxPages ?? Infinity;
  let cursor: string | undefined;
  for (let n = 0; n < maxPages; n++) {
    const result = await fetchPage(cursor);
    yield* itemsOf<T>(result, options.items);
    const meta = metaOf(result);
    const next = meta.next_cursor ?? meta.nextCursor;
    if (!next || next === cursor) return;
    cursor = next;
  }
}

/** Collect an async iterable into an array (stop after `limit` items). */
export async function collect<T>(items: AsyncIterable<T>, limit = Infinity): Promise<T[]> {
  const out: T[] = [];
  for await (const item of items) {
    if (out.length >= limit) break;
    out.push(item);
  }
  return out;
}
