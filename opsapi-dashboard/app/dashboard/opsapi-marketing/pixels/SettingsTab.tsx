'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { KeyRound, Save, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  apiErrorMessage,
  DEST_LABEL,
  formatDateTime,
  FORWARD_STATUS_CLASS,
  INPUT_CLASS,
  parseDomains,
  unwrap,
  type ForwardLog,
  type Pixel,
} from './shared';

type Props = {
  pixel: Pixel;
  onUpdated: (p: Pixel) => void;
  onDeleted: (uuid: string) => void;
};

export function SettingsTab({ pixel, onUpdated, onDeleted }: Props) {
  const [name, setName] = useState(pixel.name);
  const [domains, setDomains] = useState(pixel.allowed_domains.join('\n'));
  const [windowDays, setWindowDays] = useState(String(pixel.attribution_window_days));
  const [active, setActive] = useState(pixel.is_active);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [forwards, setForwards] = useState<ForwardLog[] | null>(null);
  const [forwardsError, setForwardsError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    marketingService
      .pixelForwards({ limit: 25 })
      .then((res) => {
        if (cancelled) return;
        const rows = unwrap<ForwardLog[]>(res);
        setForwards(Array.isArray(rows) ? rows : []);
      })
      .catch((e: unknown) => {
        if (!cancelled) setForwardsError(apiErrorMessage(e, 'Failed to load forward log'));
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const run = async (fn: () => Promise<string | void>) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const msg = await fn();
      if (msg) setNotice(msg);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Action failed'));
    } finally {
      setBusy(false);
    }
  };

  const save = (e: React.FormEvent) => {
    e.preventDefault();
    void run(async () => {
      const trimmed = name.trim();
      if (!trimmed) throw new Error('Name is required');
      const days = Number(windowDays);
      if (!Number.isInteger(days) || days < 1 || days > 90) {
        throw new Error('Attribution window must be a whole number of days between 1 and 90');
      }
      const res = await marketingService.updatePixel(pixel.uuid, {
        name: trimmed,
        allowed_domains: parseDomains(domains),
        attribution_window_days: days,
        is_active: active,
      });
      const updated = unwrap<Pixel>(res);
      onUpdated(updated && updated.uuid ? updated : { ...pixel, name: trimmed });
      return 'Settings saved.';
    });
  };

  const rotate = () =>
    run(async () => {
      if (
        !window.confirm(
          `Rotate the key for "${pixel.name}"?\n\nThe current snippet stops working immediately. You must paste the new snippet on every site that uses this pixel.`,
        )
      ) {
        return;
      }
      const res = await marketingService.rotatePixelKey(pixel.uuid);
      const updated = unwrap<Pixel>(res);
      if (updated?.uuid) onUpdated(updated);
      return 'Key rotated — copy the new snippet from the Install tab.';
    });

  const remove = () =>
    run(async () => {
      if (
        !window.confirm(
          `Delete pixel "${pixel.name}"?\n\nTracking stops on every site using it and its event history is removed. This cannot be undone.`,
        )
      ) {
        return;
      }
      await marketingService.deletePixel(pixel.uuid);
      onDeleted(pixel.uuid);
    });

  const fieldId = (s: string) => `pixel-${pixel.uuid}-${s}`;

  return (
    <div className="space-y-6">
      {error && <p className="text-sm text-error-600">{error}</p>}
      {notice && <p className="text-sm text-green-700 dark:text-green-400">{notice}</p>}

      <form className="space-y-4 rounded-lg border border-secondary-200 p-4" onSubmit={save}>
        <h3 className="text-sm font-medium">General</h3>
        <div className="space-y-1">
          <label htmlFor={fieldId('name')} className="text-sm">
            Name
          </label>
          <input
            id={fieldId('name')}
            className={`w-full ${INPUT_CLASS}`}
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
          />
        </div>
        <div className="space-y-1">
          <label htmlFor={fieldId('domains')} className="text-sm">
            Allowed domains
          </label>
          <textarea
            id={fieldId('domains')}
            className={`h-24 w-full font-mono ${INPUT_CLASS}`}
            value={domains}
            onChange={(e) => setDomains(e.target.value)}
            placeholder={'example.com\nshop.example.com'}
            aria-describedby={fieldId('domains-help')}
          />
          <p id={fieldId('domains-help')} className="text-xs text-secondary-500">
            One per line or comma separated. Events from other sites are rejected. Leave empty to accept any domain.
          </p>
        </div>
        <div className="space-y-1">
          <label htmlFor={fieldId('window')} className="text-sm">
            Attribution window (days)
          </label>
          <input
            id={fieldId('window')}
            type="number"
            min={1}
            max={90}
            step={1}
            className={`w-28 ${INPUT_CLASS}`}
            value={windowDays}
            onChange={(e) => setWindowDays(e.target.value)}
            aria-describedby={fieldId('window-help')}
          />
          <p id={fieldId('window-help')} className="text-xs text-secondary-500">
            How long after an email click a conversion is still credited to that campaign (1–90).
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
          Active — accept events from this pixel
        </label>
        <Button type="submit" size="sm" leftIcon={<Save className="h-4 w-4" />} disabled={busy}>
          Save settings
        </Button>
      </form>

      <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
        <h3 className="text-sm font-medium">Key &amp; lifecycle</h3>
        <p className="text-xs text-secondary-500">
          Public key: <code className="font-mono">{pixel.public_key}</code>. Rotate it if the snippet was copied
          somewhere it shouldn&apos;t be — the old snippet stops working.
        </p>
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            leftIcon={<KeyRound className="h-4 w-4" />}
            disabled={busy}
            onClick={() => void rotate()}
          >
            Rotate key
          </Button>
          <Button
            size="sm"
            variant="danger"
            leftIcon={<Trash2 className="h-4 w-4" />}
            disabled={busy}
            onClick={() => void remove()}
          >
            Delete pixel
          </Button>
        </div>
      </div>

      <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
        <h3 className="text-sm font-medium">Server-side forwarding</h3>
        <p className="text-xs text-secondary-500">
          Conversions can be relayed server-side to the Meta Conversions API and Google Analytics 4 (unaffected by ad
          blockers). Credentials are set under{' '}
          <Link href="/dashboard/opsapi-marketing/settings" className="underline hover:no-underline">
            Marketing → Settings
          </Link>
          . Recent forwards across all pixels:
        </p>
        {forwardsError ? (
          <p className="text-sm text-error-600">{forwardsError}</p>
        ) : forwards === null ? (
          <p className="text-sm text-secondary-500" role="status">
            Loading…
          </p>
        ) : forwards.length === 0 ? (
          <p className="text-sm text-secondary-500">No forwards yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-secondary-500">
                <tr>
                  <th className="p-1.5 font-normal">When</th>
                  <th className="p-1.5 font-normal">Event</th>
                  <th className="p-1.5 font-normal">Destination</th>
                  <th className="p-1.5 font-normal">Status</th>
                  <th className="p-1.5 font-normal">Response</th>
                </tr>
              </thead>
              <tbody>
                {forwards.map((f, i) => (
                  <tr key={`${f.created_at}-${i}`} className="border-t border-secondary-200 align-top">
                    <td className="p-1.5 whitespace-nowrap text-secondary-500">{formatDateTime(f.created_at)}</td>
                    <td className="p-1.5 font-mono">{f.event_name || '—'}</td>
                    <td className="p-1.5">{DEST_LABEL[f.destination] || f.destination}</td>
                    <td className={`p-1.5 whitespace-nowrap ${FORWARD_STATUS_CLASS[f.status] || ''}`}>
                      {f.status.replace('_', ' ')}
                      {f.http_status ? ` (${f.http_status})` : ''}
                    </td>
                    <td className="max-w-xs truncate p-1.5 font-mono text-xs text-secondary-500" title={f.response || ''}>
                      {f.response || '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
