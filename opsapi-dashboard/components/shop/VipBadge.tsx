import React from 'react';
import { Crown } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { ShopVipStatus } from '@/types/shop';

/**
 * Gold "VIP" pill for a customer holding a Trade membership in force. Renders nothing for null, so
 * callers can drop it next to any name: <VipBadge vip={vips[email]} />.
 */
export function VipBadge({ vip, size = 'sm', className }: { vip: ShopVipStatus | null | undefined; size?: 'sm' | 'md'; className?: string }) {
  if (!vip) return null;
  const tier = vip.tier === 'founding' ? 'Founding member' : 'Member';
  const note = vip.status === 'past_due' ? ' — payment overdue' : vip.cancel_at_period_end ? ' — cancelling' : '';
  return (
    <span
      title={`VIP ${tier.toLowerCase()} (${vip.billing_interval}ly)${note}`}
      className={cn(
        'inline-flex shrink-0 items-center gap-1 rounded-full border font-semibold uppercase tracking-wide',
        vip.status === 'past_due'
          ? 'border-error-300 bg-error-50 text-error-700'
          : 'border-amber-300 bg-gradient-to-r from-amber-100 to-yellow-50 text-amber-800 dark:border-amber-500/50 dark:from-amber-500/20 dark:to-yellow-500/10 dark:text-amber-300',
        size === 'md' ? 'px-2.5 py-1 text-xs' : 'px-2 py-0.5 text-[10px]',
        className
      )}
    >
      <Crown className={size === 'md' ? 'h-3.5 w-3.5' : 'h-3 w-3'} aria-hidden="true" />
      VIP{vip.tier === 'founding' ? ' · Founding' : ''}
      <span className="sr-only">{`${tier}${note}`}</span>
    </span>
  );
}

export default VipBadge;
