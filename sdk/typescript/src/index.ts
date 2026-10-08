/**
 * @opsapi/client — typed client for the OpsAPI REST API.
 * Guide: README.md; API reference: your server's /swagger.
 */
export { createClient } from './client';
export type {
  AuthApi,
  ClientOptions,
  LoginChallenge,
  LoginNamespace,
  LoginSuccess,
  LoginUser,
  OpsApiClient,
  TokenSource,
} from './client';
export { OpsApiError } from './errors';
export { collect, paginate, paginateCursor } from './paginate';
export type { PageMeta, PageOptions, PageResult } from './paginate';
export { signWebhook, verifyWebhook, WebhookVerificationError } from './webhooks';
export type { VerifyWebhookOptions, WebhookEvent } from './webhooks';
export type { components, operations, paths } from './generated/opsapi';
