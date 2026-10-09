/**
 * @opsapi/client/property-deals — typed client for the Property Deals plugin
 * (back office for buying and selling homes: deals, workflow tasks, SLAs,
 * compliance, approvals, map). API guide: docs/property-deals/API.md.
 *
 *   import { createPropertyDealsClient } from '@opsapi/client/property-deals';
 *   const api = createPropertyDealsClient({ baseUrl, token, namespace: 'demo-buyers' });
 *   const { data } = await api.GET('/api/v2/property-deals/today');
 *
 * The client covers core OpsAPI routes too (same options as createClient):
 * leads are created with POST /api/v2/crm/leads, files listed with core routes, etc.
 * Responses use the house envelope { success, data, meta? }. Null fields are
 * left out of the JSON, so optional properties may be missing.
 */
import { createClient } from './client';
import type { ClientOptions, OpsApiClient } from './client';
import type { paths as CorePaths } from './generated/opsapi';
import type { components, operations, paths as PropertyDealsPaths } from './generated/property-deals';

export type { components, operations, PropertyDealsPaths };

/** Core + Property Deals routes. */
export type Paths = CorePaths & PropertyDealsPaths;
export type PropertyDealsClient = OpsApiClient<Paths>;

/** A client for core OpsAPI and the Property Deals plugin. */
export function createPropertyDealsClient(options: ClientOptions): PropertyDealsClient {
  return createClient<Paths>(options);
}

type S = components['schemas'];

// Main records, by name.
export type Me = S['PropertyDealsMe'];
export type Today = S['PropertyDealsToday'];
export type Deal = S['PropertyDealsDeal'];
export type DealCreate = S['PropertyDealsDealCreate'];
export type DealUpdate = S['PropertyDealsDealUpdate'];
export type DealOverview = S['PropertyDealsDealOverview'];
export type DealBoard = S['PropertyDealsDealBoard'];
export type DealHealth = S['PropertyDealsDealHealth'];
export type Gate = S['PropertyDealsGate'];
export type GateItem = S['PropertyDealsGateItem'];
export type Task = S['PropertyDealsTask'];
export type TaskSummary = S['PropertyDealsTaskSummary'];
export type UrgencyFactor = S['PropertyDealsUrgencyFactor'];
export type Lead = S['PropertyDealsLead'];
export type LeadDetailsUpdate = S['PropertyDealsLeadDetailsUpdate'];
export type Property = S['PropertyDealsProperty'];
export type BuyerProfile = S['PropertyDealsBuyerProfile'];
export type Supplier = S['PropertyDealsSupplier'];
export type Booking = S['PropertyDealsBooking'];
export type Enquiry = S['PropertyDealsEnquiry'];
export type Chase = S['PropertyDealsChase'];
export type ComplianceCheck = S['PropertyDealsComplianceCheck'];
export type Document = S['PropertyDealsDocument'];
export type Approval = S['PropertyDealsApproval'];
export type ApprovalDecision = S['PropertyDealsApprovalDecision'];
export type WorkflowTemplate = S['PropertyDealsWorkflowTemplate'];
export type WorkflowTemplateVersion = S['PropertyDealsWorkflowTemplateVersion'];
export type MapResult = S['PropertyDealsMapResult'];
export type MapFeature = S['PropertyDealsMapFeature'];
export type PropertyCard = S['PropertyDealsPropertyCard'];
export type Digest = S['PropertyDealsDigest'];
export type TimelineItem = S['PropertyDealsTimelineItem'];
export type Match = S['PropertyDealsMatch'];
export type AgentRun = S['PropertyDealsAgentRun'];
export type Agent = S['PropertyDealsAgent'];
export type AgentConfig = S['PropertyDealsAgentConfig'];
export type AiRoute = S['PropertyDealsAiRoute'];
export type MailConnector = S['PropertyDealsMailConnector'];
export type MailConnectorWrite = S['PropertyDealsMailConnectorWrite'];
export type InboundMessage = S['PropertyDealsInboundMessage'];
export type NotificationPreferences = S['PropertyDealsNotificationPreferences'];

/** Task statuses (pd_status), in workflow order. */
export const TASK_STATUSES = [
  'todo', 'in_progress', 'waiting_third_party', 'agent_running', 'awaiting_approval', 'done', 'cancelled',
] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

/** Events the plugin sends to workspace webhooks (besides <entity>.created/updated/deleted). */
export const PROPERTY_DEALS_EVENTS = [
  'property_deals.deal.stage_changed', 'property_deals.deal.health_changed',
  'property_deals.deal.completed', 'property_deals.deal.fell_through',
  'property_deals.task.sla_warning', 'property_deals.task.overdue', 'property_deals.task.escalated',
  'property_deals.task.done', 'property_deals.task.awaiting_approval',
  'property_deals.approval.requested', 'property_deals.approval.approved', 'property_deals.approval.rejected',
  'property_deals.approval.decided', 'property_deals.approval.executed',
  'property_deals.agent_run.succeeded', 'property_deals.agent_run.failed',
  'property_deals.compliance_check.passed', 'property_deals.compliance_check.failed',
  'property_deals.compliance_check.expiring', 'property_deals.compliance_check.expired',
  'property_deals.booking.confirmed', 'property_deals.booking.cancelled',
] as const;
