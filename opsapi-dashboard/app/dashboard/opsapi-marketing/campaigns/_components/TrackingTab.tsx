'use client';

import React, { useMemo, useState } from 'react';
import Link from 'next/link';
import { Save, Target, Link2 } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type Campaign,
  type TrackingConfig,
  INPUT_CLASS,
  Notice,
  Toggle,
  apiErrorMessage,
  slugify,
  unwrap,
} from './shared';

const GOALS: { value: string; label: string }[] = [
  { value: '', label: 'Any conversion event' },
  { value: 'purchase', label: 'Purchase' },
  { value: 'lead', label: 'Lead' },
  { value: 'sign_up', label: 'Sign up' },
  { value: 'subscribe', label: 'Subscribe' },
  { value: 'start_trial', label: 'Start trial' },
  { value: 'book_demo', label: 'Book demo' },
];
const CUSTOM = '__custom__';

type State = {
  track_opens: boolean;
  track_clicks: boolean;
  attribution: boolean;
  utm_enabled: boolean;
  utm_source: string;
  utm_medium: string;
  utm_campaign: string;
  utm_content: string;
  goal_event: string;
};

function fromCampaign(c: Campaign): State {
  const t: TrackingConfig = c.tracking ?? {};
  const u = t.utm ?? {};
  return {
    track_opens: t.track_opens !== false,
    track_clicks: t.track_clicks !== false,
    attribution: t.attribution !== false,
    utm_enabled: u.enabled !== false,
    utm_source: u.source ?? '',
    utm_medium: u.medium ?? '',
    utm_campaign: u.campaign ?? '',
    utm_content: u.content ?? '',
    goal_event: t.goal_event ?? '',
  };
}

function toTracking(s: State): TrackingConfig {
  const utm: TrackingConfig['utm'] = { enabled: s.utm_enabled };
  if (s.utm_source.trim()) utm.source = s.utm_source.trim();
  if (s.utm_medium.trim()) utm.medium = s.utm_medium.trim();
  if (s.utm_campaign.trim()) utm.campaign = s.utm_campaign.trim();
  if (s.utm_content.trim()) utm.content = s.utm_content.trim();
  const out: TrackingConfig = {
    track_opens: s.track_opens,
    track_clicks: s.track_clicks,
    attribution: s.attribution,
    utm,
  };
  if (s.goal_event.trim()) out.goal_event = s.goal_event.trim();
  return out;
}

export default function TrackingTab({
  campaign,
  editable,
  onSaved,
}: {
  campaign: Campaign;
  editable: boolean;
  onSaved: (c: Campaign, message: string) => void;
}) {
  const [state, setState] = useState<State>(() => fromCampaign(campaign));
  const [customGoal, setCustomGoal] = useState(
    () => !!campaign.tracking?.goal_event && !GOALS.some((g) => g.value === campaign.tracking?.goal_event),
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const saved = useMemo(() => JSON.stringify(toTracking(fromCampaign(campaign))), [campaign]);
  const dirty = JSON.stringify(toTracking(state)) !== saved;

  const set = <K extends keyof State>(k: K, v: State[K]) => setState((s) => ({ ...s, [k]: v }));

  const defaults = {
    source: 'opsapi',
    medium: campaign.channel === 'sms' ? 'sms' : 'email',
    campaign: slugify(campaign.name) || 'campaign',
    content: campaign.ab_config?.enabled ? 'variant key (e.g. A)' : '',
  };

  const exampleUrl = useMemo(() => {
    const url = new URL('https://www.example.com/landing');
    if (state.utm_enabled) {
      url.searchParams.set('utm_source', state.utm_source.trim() || defaults.source);
      url.searchParams.set('utm_medium', state.utm_medium.trim() || defaults.medium);
      url.searchParams.set('utm_campaign', state.utm_campaign.trim() || defaults.campaign);
      const content = state.utm_content.trim() || (campaign.ab_config?.enabled ? 'A' : '');
      if (content) url.searchParams.set('utm_content', content);
      url.searchParams.set('utm_id', campaign.uuid);
    }
    if (state.attribution) url.searchParams.set('_mkt', 'tk_8f3a…');
    return url.toString().replace('tk_8f3a%E2%80%A6', 'tk_8f3a…');
  }, [state, defaults.source, defaults.medium, defaults.campaign, campaign.ab_config?.enabled, campaign.uuid]);

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const res = await marketingService.updateCampaign(campaign.uuid, { tracking: toTracking(state) });
      onSaved(unwrap<Campaign>(res), 'Tracking settings saved.');
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not save tracking settings'));
    } finally {
      setSaving(false);
    }
  };

  const goalSelectValue = customGoal ? CUSTOM : state.goal_event;

  return (
    <div className="space-y-4">
      {!editable && (
        <Notice tone="warn">
          Tracking settings are locked while the campaign is {campaign.status.replace(/_/g, ' ')}.
        </Notice>
      )}
      {error && <Notice tone="error">{error}</Notice>}

      <fieldset disabled={!editable} className="space-y-4">
        <legend className="sr-only">Tracking settings</legend>

        <section aria-labelledby="trk-engagement" className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <h2 id="trk-engagement" className="text-sm font-medium">
            Engagement tracking
          </h2>
          <Toggle
            id="trk-opens"
            label="Track opens"
            description="Adds a 1×1 pixel. Opens are estimates — Apple Mail Privacy Protection and scanners pre-load images; known bots are filtered."
            checked={state.track_opens}
            onChange={(v) => set('track_opens', v)}
          />
          <Toggle
            id="trk-clicks"
            label="Track clicks"
            description="Rewrites links through a redirect so clicks are counted per contact. Bot clicks are filtered."
            checked={state.track_clicks}
            onChange={(v) => set('track_clicks', v)}
          />
          <Toggle
            id="trk-attr"
            label="Website attribution"
            description={
              <>
                Appends a <code>_mkt</code> token to links so the website pixel can tie visits and conversions back to
                this send.
              </>
            }
            checked={state.attribution}
            onChange={(v) => set('attribution', v)}
          />
        </section>

        <section aria-labelledby="trk-utm" className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <h2 id="trk-utm" className="flex items-center gap-1.5 text-sm font-medium">
            <Link2 className="h-4 w-4 text-secondary-500" aria-hidden="true" /> UTM parameters
          </h2>
          <Toggle
            id="trk-utm-on"
            label="Add UTM parameters to links"
            description="So Google Analytics and other tools credit this campaign. Existing UTM parameters on a link are kept."
            checked={state.utm_enabled}
            onChange={(v) => set('utm_enabled', v)}
          />
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {(
              [
                ['utm_source', 'Source', defaults.source],
                ['utm_medium', 'Medium', defaults.medium],
                ['utm_campaign', 'Campaign', defaults.campaign],
                ['utm_content', 'Content', defaults.content || 'optional'],
              ] as const
            ).map(([k, label, ph]) => (
              <label key={k} className="block text-sm">
                <span className="font-medium">{label}</span>
                <input
                  className={`${INPUT_CLASS} mt-1 w-full`}
                  value={state[k]}
                  onChange={(e) => set(k, e.target.value)}
                  placeholder={ph}
                  disabled={!state.utm_enabled}
                />
              </label>
            ))}
          </div>
          <p className="text-xs text-secondary-500">Empty fields use the defaults shown as placeholders.</p>
          <div>
            <div className="text-xs text-secondary-500">Example tagged link</div>
            <code className="mt-1 block break-all rounded bg-secondary-100 px-2 py-1.5 text-xs">{exampleUrl}</code>
          </div>
        </section>

        <section aria-labelledby="trk-goal" className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <h2 id="trk-goal" className="flex items-center gap-1.5 text-sm font-medium">
            <Target className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Conversion goal
          </h2>
          <div className="flex flex-wrap items-end gap-2">
            <label className="block text-sm">
              <span className="font-medium">Goal event</span>
              <select
                className={`${INPUT_CLASS} mt-1 block`}
                value={goalSelectValue}
                onChange={(e) => {
                  if (e.target.value === CUSTOM) {
                    setCustomGoal(true);
                    set('goal_event', '');
                  } else {
                    setCustomGoal(false);
                    set('goal_event', e.target.value);
                  }
                }}
              >
                {GOALS.map((g) => (
                  <option key={g.value} value={g.value}>
                    {g.label}
                  </option>
                ))}
                <option value={CUSTOM}>Custom event…</option>
              </select>
            </label>
            {customGoal && (
              <label className="block text-sm">
                <span className="font-medium">Custom event name</span>
                <input
                  className={`${INPUT_CLASS} mt-1 block`}
                  value={state.goal_event}
                  onChange={(e) => set('goal_event', e.target.value)}
                  placeholder="e.g. quote_requested"
                />
              </label>
            )}
          </div>
          <p className="text-xs text-secondary-500">
            Conversions are attributed <strong>last-click</strong>: a conversion event from the website pixel is credited
            to the most recent campaign click by that visitor within the pixel&apos;s attribution window. Requires
            website attribution above and an installed pixel.{' '}
            <Link href="/dashboard/opsapi-marketing/pixels" className="underline">
              Set up the pixel
            </Link>
            .
          </p>
        </section>

        <div className="flex items-center gap-3">
          <Button
            leftIcon={<Save className="h-4 w-4" />}
            onClick={() => void save()}
            isLoading={saving}
            disabled={!editable || !dirty}
          >
            Save tracking
          </Button>
          <span className="text-xs text-secondary-500" aria-live="polite">
            {dirty ? 'Unsaved changes' : 'All changes saved'}
          </span>
        </div>
      </fieldset>
    </div>
  );
}
