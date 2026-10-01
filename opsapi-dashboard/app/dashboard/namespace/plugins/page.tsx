'use client';

/**
 * Plugins — /dashboard/namespace/plugins
 *
 * The plugins installed on this server, on or off for this workspace, and the
 * settings each one asks for. Off is a hard switch: the plugin's API answers
 * 404 here, its pages leave the sidebar, and its events and jobs stop for this
 * workspace (lapis/helper/plugin-workspaces.lua). Installing plugins is the
 * server operator's job (PLUGINS.md); this page only configures them.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Clock, Puzzle } from 'lucide-react';
import { Button, Card, Switch } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useMenu } from '@/hooks/useMenu';
import { Pill, apiError } from '@/components/field-service/shared';
import { FieldInput, toFormValue, toPayloadValue, type FormValue } from '@/components/plugins/PluginRecordModal';
import { when } from '@/components/webhooks/WebhookDeliveriesModal';
import {
  pluginService,
  type WorkspacePlugin,
  type WorkspacePluginJob,
  type WorkspacePluginSetting,
} from '@/services/plugins.service';

type FieldErrors = Record<string, string>;

// The API's 422 `details` (field -> message), for showing under each field.
function fieldErrors(err: unknown): FieldErrors {
  const details = (err as { response?: { data?: { details?: Record<string, string> } } })?.response?.data?.details;
  if (!details || typeof details !== 'object') return {};
  return Object.fromEntries(
    Object.entries(details).map(([k, v]) => [k, String(v).charAt(0).toUpperCase() + String(v).slice(1)])
  );
}

// Secrets are write-only: their inputs start empty.
function formValues(plugin: WorkspacePlugin): Record<string, FormValue> {
  return Object.fromEntries(plugin.settings.map((s) => [s.name, s.secret ? '' : toFormValue(s, s.value)]));
}

function placeholderFor(s: WorkspacePluginSetting): string | undefined {
  if (s.secret) return s.is_set ? 'Saved — type a new value to replace it' : 'Not set';
  if (s.default !== undefined && s.default !== null && s.type !== 'boolean') return `Default: ${String(s.default)}`;
  return undefined;
}

function JobLine({ job }: { job: WorkspacePluginJob }) {
  const label = job.name.split('.').slice(1).join('.').replace(/_/g, ' ');
  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
      <Clock className="h-4 w-4 shrink-0 text-secondary-400" aria-hidden />
      <span className="font-medium capitalize text-secondary-700">{label}</span>
      <span className="text-secondary-500">
        every {job.every}
        {job.at ? ` at ${job.at} UTC` : ''}
      </span>
      {job.last_status && (
        <Pill className={job.last_status === 'ok' ? 'bg-success-500/10 text-success-600' : 'bg-error-500/10 text-error-600'}>
          {job.last_status === 'ok' ? 'Last run OK' : 'Last run failed'}
        </Pill>
      )}
      <span className="text-xs text-secondary-500">
        {job.last_run_at ? `Last run ${when(job.last_run_at)}` : 'Not run yet'}
        {job.next_run_at ? ` · next ${when(job.next_run_at)}` : ''}
      </span>
    </li>
  );
}

function PluginCard({
  plugin,
  canEdit,
  onSaved,
}: {
  plugin: WorkspacePlugin;
  canEdit: boolean;
  onSaved: (plugin: WorkspacePlugin, toggled: boolean) => void;
}) {
  const initial = useMemo(() => formValues(plugin), [plugin]);
  const [values, setValues] = useState(initial);
  const [cleared, setCleared] = useState<Set<string>>(new Set()); // secrets to remove
  const [errors, setErrors] = useState<FieldErrors>({});
  const [saving, setSaving] = useState(false);
  const [toggling, setToggling] = useState(false);

  useEffect(() => {
    setValues(initial);
    setCleared(new Set());
    setErrors({});
  }, [initial]);

  const dirty = cleared.size > 0 || plugin.settings.some((s) => values[s.name] !== initial[s.name]);

  const save = async () => {
    const payload: Record<string, unknown> = {};
    const invalid: FieldErrors = {};
    for (const s of plugin.settings) {
      if (cleared.has(s.name)) {
        payload[s.name] = null;
      } else if (values[s.name] !== initial[s.name]) {
        const { value, error } = toPayloadValue(s, values[s.name]);
        if (error) invalid[s.name] = error.charAt(0).toUpperCase() + error.slice(1);
        else payload[s.name] = value; // empty = null = back to the default
      }
    }
    setErrors(invalid);
    if (Object.keys(invalid).length) return;
    setSaving(true);
    try {
      onSaved(await pluginService.updateForWorkspace(plugin.code, { settings: payload }), false);
      toast.success(`${plugin.name} settings saved`);
    } catch (err) {
      setErrors(fieldErrors(err));
      toast.error(apiError(err, 'Could not save the settings'));
    } finally {
      setSaving(false);
    }
  };

  const toggle = async (on: boolean) => {
    setToggling(true);
    try {
      onSaved(await pluginService.updateForWorkspace(plugin.code, { enabled: on }), true);
      toast.success(`${plugin.name} is ${on ? 'on' : 'off'} for this workspace`);
    } catch (err) {
      setErrors(fieldErrors(err)); // e.g. required settings missing
      toast.error(apiError(err, `Could not turn ${plugin.name} ${on ? 'on' : 'off'}`));
    } finally {
      setToggling(false);
    }
  };

  const toggleCleared = (name: string) =>
    setCleared((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });

  return (
    <Card padding="none" className="overflow-hidden">
      <div className="flex items-start justify-between gap-4 p-5">
        <div className="flex min-w-0 items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary-500/10">
            <Puzzle className="h-5 w-5 text-primary-500" aria-hidden />
          </div>
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="font-semibold text-secondary-900">{plugin.name}</h2>
              <span className="text-xs text-secondary-500">v{plugin.version}</span>
              <Pill className={plugin.enabled ? 'bg-success-500/10 text-success-600' : 'bg-secondary-500/10 text-secondary-500'}>
                {plugin.enabled ? 'On' : 'Off'}
              </Pill>
            </div>
            {plugin.description && <p className="mt-1 text-sm text-secondary-500">{plugin.description}</p>}
          </div>
        </div>
        <Switch
          checked={plugin.enabled}
          onChange={toggle}
          disabled={!canEdit || toggling}
          aria-label={`${plugin.enabled ? 'Turn off' : 'Turn on'} ${plugin.name} for this workspace`}
        />
      </div>

      {plugin.settings.length > 0 && (
        <form
          className="space-y-4 border-t border-secondary-200 p-5"
          onSubmit={(e) => {
            e.preventDefault();
            save();
          }}
        >
          <h3 className="text-sm font-semibold text-secondary-700">Settings</h3>
          <fieldset disabled={!canEdit || saving} className="grid gap-4 sm:grid-cols-2">
            {plugin.settings.map((s) => (
              <div key={s.name}>
                <FieldInput
                  field={s}
                  value={values[s.name]}
                  error={errors[s.name]}
                  placeholder={cleared.has(s.name) ? 'Will be removed when you save' : placeholderFor(s)}
                  secret={s.secret}
                  onChange={(v) => setValues((prev) => ({ ...prev, [s.name]: v }))}
                />
                {s.description && <p className="mt-1 text-xs text-secondary-500">{s.description}</p>}
                {s.secret && s.is_set && canEdit && (
                  <button
                    type="button"
                    onClick={() => toggleCleared(s.name)}
                    className="mt-1 cursor-pointer text-xs text-error-600 hover:underline focus:outline-none focus:ring-2 focus:ring-error-500/30 rounded"
                  >
                    {cleared.has(s.name) ? 'Keep the saved value' : 'Remove the saved value'}
                  </button>
                )}
              </div>
            ))}
          </fieldset>
          {canEdit && (
            <div className="flex justify-end gap-2">
              <Button
                type="button"
                variant="ghost"
                disabled={!dirty || saving}
                onClick={() => {
                  setValues(initial);
                  setCleared(new Set());
                  setErrors({});
                }}
              >
                Reset
              </Button>
              <Button type="submit" disabled={!dirty} isLoading={saving}>
                Save settings
              </Button>
            </div>
          )}
        </form>
      )}

      {plugin.jobs.length > 0 && (
        <div className="border-t border-secondary-200 bg-secondary-500/5 px-5 py-3">
          <h3 className="sr-only">Scheduled jobs</h3>
          <ul className="space-y-1.5">
            {plugin.jobs.map((job) => (
              <JobLine key={job.name} job={job} />
            ))}
          </ul>
          {!plugin.enabled && (
            <p className="mt-1.5 text-xs text-secondary-500">Jobs don&apos;t run while the plugin is off.</p>
          )}
        </div>
      )}
    </Card>
  );
}

function PluginsPageContent() {
  const { canUpdate } = usePermissions();
  const { refreshMenu } = useMenu();
  const [plugins, setPlugins] = useState<WorkspacePlugin[]>([]);
  const [loading, setLoading] = useState(true);
  const canEdit = canUpdate('namespace');

  const load = useCallback(async () => {
    try {
      setPlugins(await pluginService.listForWorkspace());
    } catch (err) {
      toast.error(apiError(err, 'Could not load plugins'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const onSaved = (updated: WorkspacePlugin, toggled: boolean) => {
    setPlugins((prev) => prev.map((p) => (p.code === updated.code ? updated : p)));
    if (toggled) refreshMenu(); // its pages join or leave the sidebar
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Plugins"
        description="Turn the plugins installed on this server on or off for this workspace, and fill in their settings."
        icon={<Puzzle className="h-5 w-5" />}
      />

      {loading ? (
        <div className="space-y-4" aria-busy="true" aria-label="Loading plugins">
          {[0, 1].map((i) => (
            <div key={i} className="h-28 animate-pulse rounded-xl bg-secondary-100" />
          ))}
        </div>
      ) : plugins.length === 0 ? (
        <Card className="p-10 text-center">
          <Puzzle className="mx-auto h-8 w-8 text-secondary-400" aria-hidden />
          <p className="mt-3 font-medium text-secondary-900">No plugins are installed on this server</p>
          <p className="mt-1 text-sm text-secondary-500">
            Plugins add their own APIs and pages. The server&apos;s operator installs them; see PLUGINS.md.
          </p>
        </Card>
      ) : (
        <div className="space-y-4">
          {!canEdit && (
            <p className="text-sm text-secondary-500">
              You can see this workspace&apos;s plugins; changing them needs the Workspace update permission.
            </p>
          )}
          {plugins.map((plugin) => (
            <PluginCard key={plugin.code} plugin={plugin} canEdit={canEdit} onSaved={onSaved} />
          ))}
        </div>
      )}
    </div>
  );
}

export default function PluginsPage() {
  return (
    <ProtectedPage module="namespace" title="Plugins">
      <PluginsPageContent />
    </ProtectedPage>
  );
}
