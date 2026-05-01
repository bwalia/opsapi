export type HttpMethod =
  | 'get'
  | 'post'
  | 'put'
  | 'patch'
  | 'delete'
  | 'options'
  | 'head';

export interface OpenApiParameter {
  name: string;
  in: 'path' | 'query' | 'header' | 'cookie';
  required?: boolean;
  description?: string;
  schema?: { type?: string; format?: string; example?: unknown };
}

export interface OpenApiSchema {
  type?: string;
  format?: string;
  example?: unknown;
  description?: string;
  properties?: Record<string, OpenApiSchema>;
  items?: OpenApiSchema;
}

export interface OpenApiRequestBody {
  required?: boolean;
  content?: Record<string, { schema?: OpenApiSchema }>;
}

export interface OpenApiResponse {
  description?: string;
  content?: Record<string, { schema?: OpenApiSchema }>;
}

export interface OpenApiOperation {
  summary?: string;
  description?: string;
  operationId?: string;
  tags?: string[];
  parameters?: OpenApiParameter[];
  requestBody?: OpenApiRequestBody;
  responses?: Record<string, OpenApiResponse>;
  security?: Array<Record<string, string[]>>;
}

export type OpenApiPathItem = Partial<Record<HttpMethod, OpenApiOperation>>;

export interface OpenApiDoc {
  openapi: string;
  info: { title: string; version: string; description?: string };
  paths: Record<string, OpenApiPathItem>;
  components?: {
    securitySchemes?: Record<string, unknown>;
    schemas?: Record<string, OpenApiSchema>;
  };
}

export interface ParsedEndpoint {
  id: string;
  tag: string;
  tagSlug: string;
  method: HttpMethod;
  path: string;
  summary: string;
  description: string;
  operationId: string;
  parameters: OpenApiParameter[];
  requestBody?: OpenApiRequestBody;
  responses: Record<string, OpenApiResponse>;
  requiresAuth: boolean;
}

export interface ParsedDomain {
  tag: string;
  slug: string;
  endpoints: ParsedEndpoint[];
}
