/** Paging info OpsAPI list endpoints return in `meta`. */
export interface PageMeta {
  page?: number;
  per_page?: number;
  total?: number;
  total_pages?: number;
  next_cursor?: string | null;
}

type PageResult<T> = { data?: T[] | null; meta?: PageMeta | null } | null | undefined;

/**
 * Every item of a page-numbered list (?page=), fetching pages as you iterate:
 *
 *   for await (const ticket of paginate((page) =>
 *     opsapi.GET('/api/v2/helpdesk/tickets', { params: { query: { page, per_page: 100 } } }).then((r) => r.data))) { … }
 */
export async function* paginate<T>(
  fetchPage: (page: number) => Promise<PageResult<T>>,
  options: { maxPages?: number } = {},
): AsyncGenerator<T, void, undefined> {
  const maxPages = options.maxPages ?? Infinity;
  for (let page = 1; page <= maxPages; page++) {
    const result = await fetchPage(page);
    const items = result?.data ?? [];
    yield* items;
    const totalPages = result?.meta?.total_pages;
    if (items.length === 0 || (typeof totalPages === 'number' && page >= totalPages)) return;
  }
}

/**
 * Every item of a cursor-paged list (meta.next_cursor), e.g. the activity log:
 *
 *   for await (const change of paginateCursor((cursor) =>
 *     opsapi.GET('/api/v2/namespace/activity/changes', { params: { query: { cursor } } }).then((r) => r.data))) { … }
 */
export async function* paginateCursor<T>(
  fetchPage: (cursor: string | undefined) => Promise<PageResult<T>>,
  options: { maxPages?: number } = {},
): AsyncGenerator<T, void, undefined> {
  const maxPages = options.maxPages ?? Infinity;
  let cursor: string | undefined;
  for (let n = 0; n < maxPages; n++) {
    const result = await fetchPage(cursor);
    yield* result?.data ?? [];
    const next = result?.meta?.next_cursor;
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
