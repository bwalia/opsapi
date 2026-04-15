import type {
  HttpMethod,
  OpenApiDoc,
  OpenApiOperation,
  ParsedDomain,
  ParsedEndpoint,
} from './types';

const METHODS: HttpMethod[] = [
  'get',
  'post',
  'put',
  'patch',
  'delete',
  'options',
  'head',
];

export function slugify(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function makeEndpointId(method: string, apiPath: string): string {
  return `${method.toLowerCase()}-${slugify(apiPath)}`;
}

function deriveOperationId(
  op: OpenApiOperation,
  method: string,
  apiPath: string,
): string {
  if (op.operationId) return op.operationId;
  return makeEndpointId(method, apiPath);
}

function deriveRequiresAuth(op: OpenApiOperation): boolean {
  if (!op.security) return true;
  if (op.security.length === 0) return false;
  return op.security.some((entry) => Object.keys(entry).length > 0);
}

export function parseOpenApi(doc: OpenApiDoc): ParsedDomain[] {
  const byTag = new Map<string, ParsedEndpoint[]>();

  for (const [apiPath, pathItem] of Object.entries(doc.paths || {})) {
    if (!pathItem) continue;
    for (const method of METHODS) {
      const op = pathItem[method];
      if (!op) continue;
      const tag = op.tags?.[0] || 'General';
      const endpoint: ParsedEndpoint = {
        id: makeEndpointId(method, apiPath),
        tag,
        tagSlug: slugify(tag),
        method,
        path: apiPath,
        summary: op.summary || `${method.toUpperCase()} ${apiPath}`,
        description: op.description || '',
        operationId: deriveOperationId(op, method, apiPath),
        parameters: op.parameters || [],
        requestBody: op.requestBody,
        responses: op.responses || {},
        requiresAuth: deriveRequiresAuth(op),
      };
      const list = byTag.get(tag) || [];
      list.push(endpoint);
      byTag.set(tag, list);
    }
  }

  const domains: ParsedDomain[] = [];
  for (const [tag, endpoints] of byTag.entries()) {
    endpoints.sort(
      (a, b) =>
        a.path.localeCompare(b.path) || a.method.localeCompare(b.method),
    );
    domains.push({ tag, slug: slugify(tag), endpoints });
  }
  domains.sort((a, b) => a.tag.localeCompare(b.tag));
  return domains;
}

export function flattenEndpoints(domains: ParsedDomain[]): ParsedEndpoint[] {
  return domains.flatMap((d) => d.endpoints);
}

export function findDomain(
  domains: ParsedDomain[],
  slug: string,
): ParsedDomain | undefined {
  return domains.find((d) => d.slug === slug);
}
