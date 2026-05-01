import type {
  OpenApiParameter,
  OpenApiSchema,
  ParsedEndpoint,
} from './types';

function extractSchemaExample(
  schema: OpenApiSchema | undefined,
): Record<string, unknown> {
  if (!schema || typeof schema !== 'object') return {};
  if (
    schema.example &&
    typeof schema.example === 'object' &&
    !Array.isArray(schema.example)
  ) {
    return schema.example as Record<string, unknown>;
  }
  if (schema.type === 'object' && schema.properties) {
    const out: Record<string, unknown> = {};
    for (const [key, prop] of Object.entries(schema.properties)) {
      if (prop?.example !== undefined) {
        out[key] = prop.example;
      } else if (prop?.type === 'string') {
        out[key] = 'string';
      } else if (prop?.type === 'number' || prop?.type === 'integer') {
        out[key] = 0;
      } else if (prop?.type === 'boolean') {
        out[key] = false;
      } else {
        out[key] = null;
      }
    }
    return out;
  }
  return {};
}

function firstRequestBodyExample(
  endpoint: ParsedEndpoint,
): Record<string, unknown> | null {
  const content = endpoint.requestBody?.content;
  if (!content) return null;
  const first = Object.values(content)[0];
  const ex = extractSchemaExample(first?.schema);
  return Object.keys(ex).length ? ex : null;
}

function buildQueryString(params: OpenApiParameter[]): string {
  const q = params.filter((p) => p.in === 'query');
  if (!q.length) return '';
  return (
    '?' +
    q
      .map((p) => {
        const example = p.schema?.example ?? (p.schema?.type === 'number' ? 1 : '');
        return `${p.name}=${example}`;
      })
      .join('&')
  );
}

function fillPath(apiPath: string, params: OpenApiParameter[]): string {
  let out = apiPath;
  for (const p of params.filter((p) => p.in === 'path')) {
    const example = p.schema?.example ?? `<${p.name}>`;
    out = out.replace(`{${p.name}}`, String(example));
  }
  return out;
}

export interface CodeSamples {
  curl: string;
  javascript: string;
  python: string;
}

export function generateSamples(
  endpoint: ParsedEndpoint,
  baseUrl: string,
): CodeSamples {
  const method = endpoint.method.toUpperCase();
  const filled = fillPath(endpoint.path, endpoint.parameters);
  const query = buildQueryString(endpoint.parameters);
  const url = `${baseUrl}${filled}${query}`;
  const body = firstRequestBodyExample(endpoint);
  const bodyJson = body ? JSON.stringify(body, null, 2) : null;

  const curlLines = [`curl -X ${method} '${url}' \\`];
  if (endpoint.requiresAuth) {
    curlLines.push(`  -H "Authorization: Bearer $OPSAPI_TOKEN" \\`);
  }
  if (bodyJson) {
    curlLines.push(`  -H 'Content-Type: application/json' \\`);
    curlLines.push(`  -d '${bodyJson}'`);
  } else {
    const last = curlLines[curlLines.length - 1];
    curlLines[curlLines.length - 1] = last.replace(/ \\$/, '');
  }
  const curl = curlLines.join('\n');

  const jsHeaders: string[] = ["'Content-Type': 'application/json'"];
  if (endpoint.requiresAuth) {
    jsHeaders.push("'Authorization': `Bearer ${token}`");
  }
  const javascript = `const res = await fetch('${url}', {
  method: '${method}',
  headers: {
    ${jsHeaders.join(',\n    ')},
  },${bodyJson ? `\n  body: JSON.stringify(${bodyJson}),` : ''}
});
const data = await res.json();`;

  const pyHeaders: string[] = ['"Content-Type": "application/json"'];
  if (endpoint.requiresAuth) {
    pyHeaders.push('"Authorization": f"Bearer {token}"');
  }
  const pyMethod = endpoint.method === 'delete' ? 'delete' : endpoint.method;
  const python = `import requests

res = requests.${pyMethod}(
    "${url}",
    headers={
        ${pyHeaders.join(',\n        ')},
    },${bodyJson ? `\n    json=${bodyJson},` : ''}
)
data = res.json()`;

  return { curl, javascript, python };
}
