'use client';

/**
 * The "How to pay" block exactly as customers see it on Order Authorisations, bank-transfer orders and
 * invoices: each method's bank details, then "Reference: <document number>".
 */
import React from 'react';
import { kindLabel, paymentMethodRows, type PaymentMethodPublic } from '@/lib/payment-methods';

export default function HowToPay({
  methods,
  reference,
  className = '',
}: {
  methods: PaymentMethodPublic[];
  reference?: string | null;
  className?: string;
}) {
  if (methods.length === 0) {
    return (
      <div className={`rounded-lg border border-dashed border-secondary-300 p-4 text-sm text-secondary-500 ${className}`}>
        Nothing to show yet — add a bank account and keep &quot;Show on documents&quot; on.
      </div>
    );
  }
  return (
    <div className={`rounded-lg border border-secondary-200 bg-surface p-4 ${className}`}>
      <p className="text-sm font-semibold text-secondary-900">How to pay</p>
      <div className="mt-2 space-y-3">
        {methods.map((m, i) => {
          const rows = paymentMethodRows(m);
          return (
            <div key={i} className={i > 0 ? 'border-t border-secondary-100 pt-3' : ''}>
              <p className="text-sm font-medium text-secondary-800">
                {m.kind === 'bank_transfer' ? `Bank transfer — ${m.label}` : m.label || kindLabel(m.kind)}
              </p>
              {rows.length > 0 && (
                <dl className="mt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-0.5 text-sm">
                  {rows.map(([k, v]) => (
                    <React.Fragment key={k}>
                      <dt className="text-secondary-500">{k}</dt>
                      <dd className="font-mono text-secondary-900">{v}</dd>
                    </React.Fragment>
                  ))}
                </dl>
              )}
              {m.instructions && <p className="mt-1 text-sm text-secondary-600">{m.instructions}</p>}
            </div>
          );
        })}
      </div>
      {reference && (
        <p className="mt-3 text-sm text-secondary-900">
          Reference: <span className="font-mono font-semibold">{reference}</span>
        </p>
      )}
    </div>
  );
}
