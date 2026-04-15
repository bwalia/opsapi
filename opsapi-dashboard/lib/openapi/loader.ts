import fs from 'node:fs/promises';
import path from 'node:path';
import type { OpenApiDoc } from './types';

const FALLBACK_PATH = path.join(
  process.cwd(),
  '..',
  'lapis',
  'api-docs',
  'swagger.json',
);

const EMPTY_DOC: OpenApiDoc = {
  openapi: '3.0.0',
  info: {
    title: 'OpsAPI',
    version: '0.0.0',
    description: 'Spec unavailable — check that the OpsAPI server is running.',
  },
  paths: {},
};

export async function loadOpenApi(): Promise<OpenApiDoc> {
  const base = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
  try {
    const res = await fetch(`${base}/swagger/swagger.json`, {
      next: { revalidate: 300 },
    });
    if (res.ok) {
      return (await res.json()) as OpenApiDoc;
    }
  } catch {
    // fall through to file fallback
  }
  try {
    const raw = await fs.readFile(FALLBACK_PATH, 'utf8');
    return JSON.parse(raw) as OpenApiDoc;
  } catch {
    return EMPTY_DOC;
  }
}
