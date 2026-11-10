/**
 * GET /api/v2/shop/admin/analytics — lapis/queries/ShopAnalyticsQueries.lua.
 * Money is integer minor units (pence). Rates are 0..1, or null when there is
 * nothing to divide by (show "—", never 0%).
 */

export type AnalyticsBucket = 'day' | 'week' | 'month';

export interface AnalyticsWindow {
  from: string;
  to: string;
  to_exclusive: string;
  days: number;
  bucket: AnalyticsBucket;
  timezone: string;
  includes_today: boolean;
  previous: { from: string; to: string; to_exclusive: string; days: number };
}

export interface AnalyticsSales {
  orders: number;
  revenue_minor: number;
  revenue_ex_vat_minor: number;
  vat_minor: number;
  shipping_minor: number;
  refunds_minor: number;
  refunded_orders: number;
  net_revenue_minor: number;
  aov_minor: number | null;
  trade_discount_minor: number;
  credit_used_minor: number;
  customers: number;
  new_customers: number;
  returning_customers: number;
}

export interface AnalyticsCheckout {
  sessions: number;
  started: number;
  paid: number;
  payment_failed: number;
  pending: number;
  cancelled: number;
  from_quote: number;
  paid_rate: number | null;
}

export interface AnalyticsCarts {
  created: number;
  with_items: number;
  reached_checkout: number;
  converted: number;
  abandoned: number;
  abandoned_value_minor: number;
  open: number;
  abandon_after_hours: number;
  conversion_rate: number | null;
  abandonment_rate: number | null;
}

export interface AnalyticsQuotes {
  created: number;
  value_minor: number;
  by_source: { cart: number; chat: number; admin: number };
  viewed: number;
  accepted: number;
  converted: number;
  converted_value_minor: number;
  expired: number;
  conversion_rate: number | null;
  average_value_minor: number | null;
}

export interface AnalyticsChat {
  chats: number;
  ai_replied: number;
  no_reply: number;
  contact_saved: number;
  quotes: number;
  added_to_cart: number;
  orders: number;
  completed: number;
  member_chats: number;
  user_messages: number;
  revenue_minor: number;
  reply_rate: number | null;
  completion_rate: number | null;
  order_rate: number | null;
  avg_user_messages: number | null;
}

export interface AnalyticsTrade {
  joins: number;
  cancellations: number;
  active_now: number;
}

export interface AnalyticsPeriod {
  sales: AnalyticsSales;
  checkout: AnalyticsCheckout;
  carts: AnalyticsCarts;
  quotes: AnalyticsQuotes;
  chat: AnalyticsChat;
  trade?: AnalyticsTrade | null;
}

export interface AnalyticsPoint {
  bucket: string;
  orders: number;
  revenue_minor: number;
  revenue_ex_vat_minor: number;
  checkouts: number;
  carts: number;
  chats: number;
  quotes: number;
}

export interface AnalyticsTopProduct {
  product_uuid: string | null;
  name: string | null;
  sku: string | null;
  units: number;
  orders: number;
  revenue_ex_vat_minor: number;
  revenue_minor: number;
}

export interface AnalyticsBasketAdd {
  product_uuid: string;
  name: string;
  sku: string | null;
  adds: number;
  units: number;
  carts: number;
}

export type AnalyticsChangeKey =
  | 'revenue_minor'
  | 'net_revenue_minor'
  | 'orders'
  | 'aov_minor'
  | 'customers'
  | 'checkouts'
  | 'carts'
  | 'abandoned'
  | 'quotes'
  | 'chats'
  | 'chat_completed';

export interface ShopAnalyticsReport extends AnalyticsPeriod {
  window: AnalyticsWindow;
  generated_at: string;
  currency: string;
  series: AnalyticsPoint[];
  top_products: AnalyticsTopProduct[];
  basket_adds: AnalyticsBasketAdd[];
  basket_adds_complete: boolean;
  chat_tools: { name: string; chats: number; uses: number }[];
  chat_countries: { country?: string | null; chats: number }[];
  visitor_tracking: { enabled: boolean; status: string };
  previous?: AnalyticsPeriod;
  changes?: Partial<Record<AnalyticsChangeKey, number | null>>;
}

export interface ShopAnalyticsQuery {
  from?: string;
  to?: string;
  days?: number;
  bucket?: AnalyticsBucket;
  compare?: boolean;
}

export type ShopAnalyticsExport = 'daily' | 'products' | 'chat_tools' | 'survey';

// ---------------------------------------------------------------------------------------------
// "What do I need?" survey funnel (GET /api/v2/shop/admin/analytics/survey). Every count is distinct visitors.

export type ShopSurveyEvent = 'view' | 'start' | 'answer' | 'back' | 'result' | 'lead' | 'ask' | 'apply';

export interface ShopSurveyReport {
  survey: string;
  window: { from: string; to: string; days: number; timezone: string; includes_today: boolean };
  generated_at: string;
  visitors: Record<ShopSurveyEvent, number>;
  funnel: { stage: ShopSurveyEvent; visitors: number; rate_from_previous?: number | null; rate_from_view?: number | null }[];
  dropoff: {
    step: number | null;
    visitors: number;
    previous_visitors?: number | null;
    lost_from_previous?: number | null;
    questions: { question: string | null; visitors: number }[];
  }[];
  answers: { question: string; step?: number | null; answers: { answer: string; visitors: number }[] }[];
  results_by_product: { product: string; visitors: number }[];
  apply_by_plan: { y: number; m: number; total: number; unknown?: number };
  trade_signups: { checkouts_started: number; joined: number; joined_by_plan: { y: number; m: number } } | null;
  retention_months: number;
  complete: boolean;
}
