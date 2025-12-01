import { clsx, type ClassValue } from 'clsx';
import { format, formatDistanceToNow, parseISO } from 'date-fns';

/**
 * Merge class names with clsx
 */
export function cn(...inputs: ClassValue[]): string {
  return clsx(inputs);
}

/**
 * Format date to readable string
 */
export function formatDate(date: string | Date, formatStr: string = 'MMM d, yyyy'): string {
  if (!date) return '-';
  const dateObj = typeof date === 'string' ? parseISO(date) : date;
  return format(dateObj, formatStr);
}

/**
 * Format date with time
 */
export function formatDateTime(date: string | Date): string {
  if (!date) return '-';
  const dateObj = typeof date === 'string' ? parseISO(date) : date;
  return format(dateObj, 'MMM d, yyyy h:mm a');
}

/**
 * Format relative time
 */
export function formatRelativeTime(date: string | Date): string {
  if (!date) return '-';
  const dateObj = typeof date === 'string' ? parseISO(date) : date;
  return formatDistanceToNow(dateObj, { addSuffix: true });
}

/**
 * Format currency
 */
export function formatCurrency(
  amount: number | string,
  currency: string = 'USD',
  locale: string = 'en-US'
): string {
  const numAmount = typeof amount === 'string' ? parseFloat(amount) : amount;
  if (isNaN(numAmount)) return '-';

  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(numAmount);
}

/**
 * Format number with commas
 */
export function formatNumber(num: number | string, locale: string = 'en-US'): string {
  const numValue = typeof num === 'string' ? parseFloat(num) : num;
  if (isNaN(numValue)) return '-';
  return new Intl.NumberFormat(locale).format(numValue);
}

/**
 * Format percentage
 */
export function formatPercentage(value: number, decimals: number = 1): string {
  return `${value.toFixed(decimals)}%`;
}

/**
 * Truncate text with ellipsis
 */
export function truncate(str: string, length: number): string {
  if (!str) return '';
  if (str.length <= length) return str;
  return str.slice(0, length) + '...';
}

/**
 * Get initials from name
 */
export function getInitials(firstName?: string, lastName?: string): string {
  const first = firstName?.[0]?.toUpperCase() || '';
  const last = lastName?.[0]?.toUpperCase() || '';
  return first + last || 'U';
}

/**
 * Get full name
 */
export function getFullName(firstName?: string, lastName?: string): string {
  return [firstName, lastName].filter(Boolean).join(' ') || 'Unknown';
}

/**
 * Capitalize first letter
 */
export function capitalize(str: string): string {
  if (!str) return '';
  return str.charAt(0).toUpperCase() + str.slice(1).toLowerCase();
}

/**
 * Convert snake_case to Title Case
 */
export function snakeToTitle(str: string): string {
  if (!str) return '';
  return str
    .split('_')
    .map((word) => capitalize(word))
    .join(' ');
}

/**
 * Generate a random ID
 */
export function generateId(): string {
  return Math.random().toString(36).substring(2, 9);
}

/**
 * Debounce function
 */
export function debounce<T extends (...args: Parameters<T>) => ReturnType<T>>(
  func: T,
  wait: number
): (...args: Parameters<T>) => void {
  let timeout: NodeJS.Timeout | null = null;

  return (...args: Parameters<T>) => {
    if (timeout) clearTimeout(timeout);
    timeout = setTimeout(() => func(...args), wait);
  };
}

/**
 * Check if value is empty
 */
export function isEmpty(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  if (typeof value === 'string') return value.trim() === '';
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === 'object') return Object.keys(value).length === 0;
  return false;
}

/**
 * Safe JSON parse
 */
export function safeJsonParse<T>(str: string, fallback: T): T {
  try {
    return JSON.parse(str);
  } catch {
    return fallback;
  }
}

/**
 * Get status color class
 */
export function getStatusColor(status: string): string {
  const statusColors: Record<string, string> = {
    // Order statuses
    pending: 'bg-warning-500/10 text-warning-600',
    confirmed: 'bg-info-500/10 text-info-600',
    processing: 'bg-info-500/10 text-info-600',
    ready_for_pickup: 'bg-accent-500/10 text-accent-600',
    out_for_delivery: 'bg-accent-500/10 text-accent-600',
    delivered: 'bg-success-500/10 text-success-600',
    cancelled: 'bg-error-500/10 text-error-600',
    refunded: 'bg-secondary-500/10 text-secondary-600',
    // Payment statuses
    paid: 'bg-success-500/10 text-success-600',
    failed: 'bg-error-500/10 text-error-600',
    // General statuses
    active: 'bg-success-500/10 text-success-600',
    inactive: 'bg-secondary-500/10 text-secondary-600',
    draft: 'bg-warning-500/10 text-warning-600',
    archived: 'bg-secondary-500/10 text-secondary-600',
  };

  return statusColors[status.toLowerCase()] || 'bg-secondary-500/10 text-secondary-600';
}
