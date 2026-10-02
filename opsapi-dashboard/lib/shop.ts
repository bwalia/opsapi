/**
 * Shop back-office helpers: money (minor units ↔ pounds), status colours,
 * customer-link → PDF URL derivation, Stripe dashboard links.
 */
import type { ShopOrderStatus, ShopQuoteStatus, ShopProduct, ShopOptionGroup } from '@/types/shop';

const formatters = new Map<string, Intl.NumberFormat>();

/** Format integer minor units as currency with 2 dp (GBP by default). */
export function formatMoney(minor: number | null | undefined, currency: string = 'GBP'): string {
  if (minor === null || minor === undefined || Number.isNaN(Number(minor))) return '—';
  const cur = (currency || 'GBP').toUpperCase();
  let f = formatters.get(cur);
  if (!f) {
    f = new Intl.NumberFormat('en-GB', {
      style: 'currency',
      currency: cur,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    formatters.set(cur, f);
  }
  return f.format(Number(minor) / 100);
}

/** Ex-VAT minor → inc-VAT minor (rounded half-up per line, matching server). */
export function incVat(minor: number, vatRate: number = 0.2): number {
  return Math.round(minor * (1 + (Number.isFinite(vatRate) ? vatRate : 0.2)));
}

/** Pounds (string or number, e.g. "1,299.99") → integer pence. Returns null for blank/invalid. */
export function poundsToMinor(value: string | number | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  const s = String(value).replace(/[£,\s]/g, '').trim();
  if (s === '' || s === '-') return null;
  if (!/^-?\d*(\.\d*)?$/.test(s)) return null;
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return Math.round(n * 100);
}

/** Integer pence → pounds string with 2 dp for input fields ("" for null). */
export function minorToPounds(minor: number | null | undefined): string {
  if (minor === null || minor === undefined || Number.isNaN(Number(minor))) return '';
  return (Number(minor) / 100).toFixed(2);
}

export function slugify(s: string): string {
  return s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 120);
}

/** Lenient sanitiser for typing into slug/code fields (keeps trailing separators). */
export function typingSlug(s: string, sep: '-' | '_' = '-'): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, sep);
}

export function codify(s: string): string {
  return slugify(s).replace(/-/g, '_');
}

/**
 * Sanitise a group/option code typed by the admin. Existing catalogue codes use
 * both '-' and '_' (e.g. "rtx-pro-6000-we", "boot_drive"); since groups/options
 * are upserted BY CODE, rewriting separators would silently replace the option
 * (breaking rules, selections and saved quotes). Keep both separators.
 */
export function typingCode(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9_-]+/g, '_');
}

export function normalizeCode(s: string): string {
  return typingCode(s.trim()).replace(/^[-_]+|[-_]+$/g, '');
}

/**
 * Quote PDF route on the shop app, derived from the customer link:
 *   https://shop.example/quotes/<uuid>?t=<token>
 *   → https://shop.example/api/quotes/<uuid>/pdf?t=<token>
 */
export function quotePdfUrl(publicUrl: string | null | undefined): string | null {
  if (!publicUrl) return null;
  try {
    const u = new URL(publicUrl);
    const path = u.pathname.replace(/\/+$/, '');
    const idx = path.indexOf('/quotes/');
    if (idx === -1) return null;
    u.pathname = `${path.slice(0, idx)}/api${path.slice(idx)}/pdf`;
    return u.toString();
  } catch {
    return null;
  }
}

export function stripePaymentUrl(paymentIntentId: string): string {
  return `https://dashboard.stripe.com/payments/${encodeURIComponent(paymentIntentId)}`;
}

export function stripeSessionUrl(sessionId: string): string {
  return `https://dashboard.stripe.com/checkout/sessions/${encodeURIComponent(sessionId)}`;
}

type BadgeVariant = 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary';

export function orderStatusVariant(s: ShopOrderStatus | string): BadgeVariant {
  switch (s) {
    case 'paid':
    case 'delivered':
      return 'success';
    case 'processing':
    case 'shipped':
      return 'info';
    case 'pending_payment':
      return 'warning';
    case 'cancelled':
    case 'payment_failed':
      return 'error';
    default:
      return 'secondary';
  }
}

export function quoteStatusVariant(s: ShopQuoteStatus | string): BadgeVariant {
  switch (s) {
    case 'accepted':
    case 'converted':
      return 'success';
    case 'sent':
      return 'info';
    case 'draft':
      return 'warning';
    case 'expired':
    case 'cancelled':
      return 'error';
    default:
      return 'secondary';
  }
}

export function productStatusVariant(s: string): BadgeVariant {
  return s === 'active' ? 'success' : s === 'draft' ? 'warning' : 'secondary';
}

export function humanize(s: string | null | undefined): string {
  if (!s) return '';
  return s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

/**
 * Client-side preview of the configurable "from" price, mirroring the server
 * (lib/shop-pricing.lua `from_price`): base + for each active group the cheapest
 * active option × max(min_qty, required ? 1 : 0); optional groups only count
 * a negative cheapest delta. The server's pricing engine is authoritative.
 */
export function estimateFromPrice(
  basePriceMinor: number,
  groups: (Pick<ShopOptionGroup, 'required' | 'min_qty' | 'options'> & { is_active?: boolean })[]
): number {
  let total = basePriceMinor || 0;
  for (const g of groups) {
    if (g.is_active === false) continue;
    const active = g.options.filter((o) => o.is_active !== false);
    if (!active.length) continue;
    const cheapest = Math.min(...active.map((o) => o.price_delta_minor || 0));
    let need = Math.max(0, g.min_qty || 0);
    if (g.required && need < 1) need = 1;
    if (need > 0) total += cheapest * need;
    else if (cheapest < 0) total += cheapest;
  }
  return total;
}

export function productStockLabel(p: Pick<ShopProduct, 'stock_qty' | 'held' | 'low_stock_threshold'>): {
  available: number;
  low: boolean;
} {
  const available = (p.stock_qty ?? 0) - (p.held ?? 0);
  return { available, low: available <= (p.low_stock_threshold ?? 0) };
}

/**
 * Catalogue image paths are relative to the shop storefront (e.g.
 * "/img/products/tower.svg"), not to this dashboard. Resolve them against
 * NEXT_PUBLIC_SHOP_URL (the storefront origin) when configured; absolute URLs
 * pass through unchanged.
 */
export function shopAssetUrl(u: string | null | undefined): string {
  const s = (u ?? '').trim();
  if (!s || /^(https?:|data:|blob:)/i.test(s) || s.startsWith('//')) return s;
  const base = (process.env.NEXT_PUBLIC_SHOP_URL || '').replace(/\/+$/, '');
  return base && s.startsWith('/') ? base + s : s;
}
