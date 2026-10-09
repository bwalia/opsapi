// Copy the Property Deals OpenAPI types from the SDK generator into the dashboard
// (types/property-deals.generated.ts). Run after `npm run generate:property-deals`
// in sdk/typescript. Switch to `@opsapi/client/property-deals` once 1.3.0 is on npm.
import { copyFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, '../../sdk/typescript/src/generated/property-deals.ts');
const dst = resolve(here, '../types/property-deals.generated.ts');
copyFileSync(src, dst);
console.log('copied', src, '->', dst);
