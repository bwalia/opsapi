'use client';

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { ArrowLeft, Save, Check, History, Eye, Code } from 'lucide-react';
import toast from 'react-hot-toast';

import { Button, Card, Input, Textarea, Badge } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { themesService } from '@/services/themes.service';
import type {
  ThemeDetail,
  ThemeSchema,
  ThemeTokenField,
  ThemeTokens,
  ThemeRevision,
} from '@/types/theme';

const COLOR_SCALE_KEYS = ['50', '100', '200', '300', '400', '500', '600', '700', '800', '900'];

function ThemeEditorContent() {
  const params = useParams();
  const themeUuid = params.uuid as string;
  const { canUpdate } = usePermissions();

  const [detail, setDetail] = useState<ThemeDetail | null>(null);
  const [schema, setSchema] = useState<ThemeSchema | null>(null);
  const [tokens, setTokens] = useState<ThemeTokens>({});
  const [customCss, setCustomCss] = useState('');
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [changeNote, setChangeNote] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [previewKey, setPreviewKey] = useState(0);
  const [showRevisions, setShowRevisions] = useState(false);
  const [revisions, setRevisions] = useState<ThemeRevision[]>([]);
  const [activeGroup, setActiveGroup] = useState<string>('');

  const previewIframeRef = useRef<HTMLIFrameElement>(null);

  const loadTheme = useCallback(async () => {
    setIsLoading(true);
    try {
      const [detailRes, schemaRes] = await Promise.all([
        themesService.get(themeUuid),
        themesService.getSchema(),
      ]);
      setDetail(detailRes);
      setSchema(schemaRes);
      setTokens(detailRes.tokens || {});
      setCustomCss(detailRes.custom_css || '');
      setName(detailRes.theme.name);
      setDescription(detailRes.theme.description || '');
      const groups = Object.keys(schemaRes || {});
      if (groups.length && !activeGroup) setActiveGroup(groups[0]);
    } catch (err) {
      console.error('Failed to load theme', err);
      toast.error('Failed to load theme');
    } finally {
      setIsLoading(false);
    }
  }, [themeUuid, activeGroup]);

  useEffect(() => {
    loadTheme();
  }, [loadTheme]);

  const updateTokenField = (group: string, field: string, value: unknown) => {
    setTokens((prev) => {
      const next: ThemeTokens = { ...prev };
      next[group] = { ...(next[group] || {}), [field]: value };
      return next;
    });
  };

  const updateColorScaleStop = (group: string, field: string, stop: string, value: string) => {
    setTokens((prev) => {
      const next: ThemeTokens = { ...prev };
      const groupTokens = { ...(next[group] || {}) };
      const current = (groupTokens[field] as Record<string, string>) || {};
      groupTokens[field] = { ...current, [stop]: value };
      next[group] = groupTokens;
      return next;
    });
  };

  const handleSave = async () => {
    if (!detail) return;
    setIsSaving(true);
    try {
      const updated = await themesService.update(themeUuid, {
        name,
        description,
        tokens,
        custom_css: customCss,
        change_note: changeNote || undefined,
      });
      setDetail(updated);
      setChangeNote('');
      toast.success('Theme saved');
      setPreviewKey((k) => k + 1);
    } catch {
      toast.error('Failed to save theme');
    } finally {
      setIsSaving(false);
    }
  };

  const handleActivate = async () => {
    try {
      await themesService.activate(themeUuid);
      toast.success('Theme activated');
      loadTheme();
    } catch {
      toast.error('Failed to activate theme');
    }
  };

  const loadRevisions = async () => {
    try {
      const rows = await themesService.listRevisions(themeUuid);
      setRevisions(rows);
      setShowRevisions(true);
    } catch {
      toast.error('Failed to load revisions');
    }
  };

  const handleRevert = async (revisionUuid: string) => {
    try {
      await themesService.revert(themeUuid, revisionUuid);
      toast.success('Reverted to revision');
      setShowRevisions(false);
      loadTheme();
      setPreviewKey((k) => k + 1);
    } catch {
      toast.error('Failed to revert');
    }
  };

  const previewUrl = useMemo(() => {
    if (!detail) return '';
    return `${themesService.previewCssUrl(themeUuid)}?v=${previewKey}`;
  }, [detail, themeUuid, previewKey]);

  if (isLoading) {
    return <div className="text-center py-12 text-secondary-500">Loading theme…</div>;
  }
  if (!detail || !schema) {
    return <div className="text-center py-12 text-secondary-500">Theme not found</div>;
  }

  const theme = detail.theme;
  const readOnly = !canUpdate('themes') || theme.is_platform;
  const groupKeys = Object.keys(schema);
  const currentGroupSchema = schema[activeGroup] || {};

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Link href="/dashboard/themes">
            <Button variant="ghost" size="sm">
              <ArrowLeft className="w-4 h-4 mr-1" />
              Back
            </Button>
          </Link>
          <div>
            <h1 className="text-xl font-semibold text-secondary-900">{theme.name}</h1>
            <div className="flex items-center gap-2 mt-0.5">
              <span className="text-xs text-secondary-500">{theme.slug}</span>
              {theme.is_active && (
                <Badge variant="success">
                  <Check className="w-3 h-3 mr-1" />
                  Active
                </Badge>
              )}
              {theme.is_platform && <Badge variant="info">Platform</Badge>}
              <span className="text-xs text-secondary-500">v{theme.version}</span>
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="secondary" size="sm" onClick={loadRevisions}>
            <History className="w-4 h-4 mr-1" />
            Revisions
          </Button>
          {!theme.is_active && (
            <Button variant="secondary" size="sm" onClick={handleActivate}>
              Activate
            </Button>
          )}
          {!readOnly && (
            <Button onClick={handleSave} disabled={isSaving}>
              <Save className="w-4 h-4 mr-1" />
              {isSaving ? 'Saving…' : 'Save'}
            </Button>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-5 gap-5">
        <div className="lg:col-span-3 space-y-4">
          <Card>
            <div className="p-5 space-y-4">
              <h2 className="text-base font-semibold text-secondary-900">Theme details</h2>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Name</label>
                <Input
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  disabled={readOnly}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">
                  Description
                </label>
                <Textarea
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  disabled={readOnly}
                  rows={2}
                />
              </div>
            </div>
          </Card>

          <Card>
            <div className="p-5">
              <div className="flex items-center justify-between mb-4">
                <h2 className="text-base font-semibold text-secondary-900">Design tokens</h2>
              </div>
              <div className="flex flex-wrap gap-2 mb-4 border-b border-secondary-200 pb-3">
                {groupKeys.map((g) => (
                  <button
                    key={g}
                    onClick={() => setActiveGroup(g)}
                    className={`px-3 py-1.5 text-sm rounded-md capitalize transition-colors ${
                      activeGroup === g
                        ? 'bg-primary-100 text-primary-700 font-medium'
                        : 'text-secondary-600 hover:bg-secondary-50'
                    }`}
                  >
                    {g}
                  </button>
                ))}
              </div>

              <div className="space-y-4">
                {Object.entries(currentGroupSchema).map(([fieldName, field]) => (
                  <TokenField
                    key={fieldName}
                    name={fieldName}
                    field={field as ThemeTokenField}
                    value={tokens[activeGroup]?.[fieldName]}
                    disabled={readOnly}
                    onChange={(v) => updateTokenField(activeGroup, fieldName, v)}
                    onScaleStopChange={(stop, v) =>
                      updateColorScaleStop(activeGroup, fieldName, stop, v)
                    }
                  />
                ))}
                {Object.keys(currentGroupSchema).length === 0 && (
                  <div className="text-sm text-secondary-500 text-center py-6">
                    No editable fields in this group.
                  </div>
                )}
              </div>
            </div>
          </Card>

          <Card>
            <div className="p-5 space-y-3">
              <div className="flex items-center gap-2">
                <Code className="w-4 h-4 text-secondary-500" />
                <h2 className="text-base font-semibold text-secondary-900">Custom CSS</h2>
              </div>
              <p className="text-xs text-secondary-500">
                Advanced. Sanitized server-side. Use CSS variables like{' '}
                <code className="text-xs">var(--ops-color-primary-500)</code>.
              </p>
              <Textarea
                value={customCss}
                onChange={(e) => setCustomCss(e.target.value)}
                disabled={readOnly}
                rows={8}
                className="font-mono text-xs"
              />
            </div>
          </Card>

          {!readOnly && (
            <Card>
              <div className="p-5 space-y-2">
                <label className="block text-sm font-medium text-secondary-700">
                  Change note (optional)
                </label>
                <Input
                  value={changeNote}
                  onChange={(e) => setChangeNote(e.target.value)}
                  placeholder="What did you change?"
                />
                <p className="text-xs text-secondary-500">
                  Attached to the revision created on save. Lets you recover prior edits.
                </p>
              </div>
            </Card>
          )}
        </div>

        <div className="lg:col-span-2">
          <Card>
            <div className="p-5 space-y-3">
              <div className="flex items-center gap-2">
                <Eye className="w-4 h-4 text-secondary-500" />
                <h2 className="text-base font-semibold text-secondary-900">Preview</h2>
              </div>
              <p className="text-xs text-secondary-500">
                Live sample rendered with the current tokens. Save to commit a revision.
              </p>
              <iframe
                ref={previewIframeRef}
                title="Theme preview"
                srcDoc={buildPreviewDoc(previewUrl)}
                className="w-full h-[520px] rounded-md border border-secondary-200 bg-white"
              />
            </div>
          </Card>
        </div>
      </div>

      {showRevisions && (
        <Card>
          <div className="p-5 space-y-3">
            <div className="flex items-center justify-between">
              <h2 className="text-base font-semibold text-secondary-900">Revision history</h2>
              <Button variant="ghost" size="sm" onClick={() => setShowRevisions(false)}>
                Close
              </Button>
            </div>
            {revisions.length === 0 ? (
              <div className="text-sm text-secondary-500 text-center py-6">No revisions yet.</div>
            ) : (
              <div className="space-y-2">
                {revisions.map((rev) => (
                  <div
                    key={rev.uuid}
                    className="flex items-center justify-between p-3 rounded-md border border-secondary-200"
                  >
                    <div>
                      <div className="text-sm font-medium text-secondary-900">
                        v{rev.version} — {new Date(rev.created_at).toLocaleString()}
                      </div>
                      {rev.change_note && (
                        <div className="text-xs text-secondary-500 mt-0.5">{rev.change_note}</div>
                      )}
                    </div>
                    {!readOnly && (
                      <Button
                        variant="secondary"
                        size="sm"
                        onClick={() => handleRevert(rev.uuid)}
                      >
                        Revert to this
                      </Button>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </Card>
      )}
    </div>
  );
}

function TokenField({
  name,
  field,
  value,
  disabled,
  onChange,
  onScaleStopChange,
}: {
  name: string;
  field: ThemeTokenField;
  value: unknown;
  disabled?: boolean;
  onChange: (v: unknown) => void;
  onScaleStopChange: (stop: string, v: string) => void;
}) {
  const label = field.ui?.label || name;
  const hint = field.ui?.hint;

  if (field.type === 'color_scale') {
    const scale = (value as Record<string, string>) || {};
    return (
      <div>
        <div className="flex items-baseline justify-between mb-1">
          <label className="text-sm font-medium text-secondary-700">{label}</label>
          {hint && <span className="text-xs text-secondary-500">{hint}</span>}
        </div>
        <div className="grid grid-cols-5 gap-2">
          {COLOR_SCALE_KEYS.map((stop) => (
            <div key={stop} className="flex flex-col items-center gap-1">
              <input
                type="color"
                disabled={disabled}
                value={normalizeHex(scale[stop]) || '#888888'}
                onChange={(e) => onScaleStopChange(stop, e.target.value)}
                className="w-full h-8 rounded border border-secondary-300 cursor-pointer disabled:cursor-not-allowed"
              />
              <span className="text-[10px] text-secondary-500">{stop}</span>
            </div>
          ))}
        </div>
      </div>
    );
  }

  if (field.type === 'color') {
    const hex = normalizeHex(value as string) || '';
    return (
      <div className="flex items-center justify-between gap-3">
        <div className="flex-1">
          <label className="block text-sm font-medium text-secondary-700">{label}</label>
          {hint && <span className="text-xs text-secondary-500">{hint}</span>}
        </div>
        <div className="flex items-center gap-2">
          <input
            type="color"
            disabled={disabled}
            value={hex || '#888888'}
            onChange={(e) => onChange(e.target.value)}
            className="w-10 h-10 rounded border border-secondary-300 cursor-pointer disabled:cursor-not-allowed"
          />
          <Input
            value={(value as string) || ''}
            onChange={(e) => onChange(e.target.value)}
            disabled={disabled}
            className="w-32 font-mono text-xs"
          />
        </div>
      </div>
    );
  }

  if (field.type === 'enum' && field.values) {
    return (
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-1">{label}</label>
        <select
          disabled={disabled}
          value={(value as string) || ''}
          onChange={(e) => onChange(e.target.value)}
          className="w-full border border-secondary-300 rounded-md px-3 py-2 text-sm disabled:bg-secondary-50"
        >
          <option value="">—</option>
          {field.values.map((v) => (
            <option key={v} value={v}>
              {v}
            </option>
          ))}
        </select>
        {hint && <p className="text-xs text-secondary-500 mt-1">{hint}</p>}
      </div>
    );
  }

  if (field.type === 'boolean') {
    return (
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          disabled={disabled}
          checked={Boolean(value)}
          onChange={(e) => onChange(e.target.checked)}
          className="rounded border-secondary-300"
        />
        <span className="text-sm text-secondary-700">{label}</span>
        {hint && <span className="text-xs text-secondary-500">— {hint}</span>}
      </label>
    );
  }

  if (field.type === 'number') {
    return (
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-1">{label}</label>
        <Input
          type="number"
          disabled={disabled}
          min={field.min}
          max={field.max}
          value={(value as number) ?? ''}
          onChange={(e) => onChange(e.target.value === '' ? null : Number(e.target.value))}
        />
        {hint && <p className="text-xs text-secondary-500 mt-1">{hint}</p>}
      </div>
    );
  }

  // Fallback: string/size/font/shadow/asset — plain text input
  return (
    <div>
      <label className="block text-sm font-medium text-secondary-700 mb-1">
        {label} <span className="text-xs text-secondary-400">({field.type})</span>
      </label>
      <Input
        disabled={disabled}
        value={(value as string) || ''}
        onChange={(e) => onChange(e.target.value)}
        maxLength={field.max_length}
      />
      {hint && <p className="text-xs text-secondary-500 mt-1">{hint}</p>}
    </div>
  );
}

function normalizeHex(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const trimmed = v.trim();
  if (/^#[0-9a-fA-F]{6}$/.test(trimmed)) return trimmed;
  if (/^#[0-9a-fA-F]{3}$/.test(trimmed)) {
    return (
      '#' +
      trimmed
        .slice(1)
        .split('')
        .map((c) => c + c)
        .join('')
    );
  }
  return null;
}

function buildPreviewDoc(cssUrl: string): string {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<link rel="stylesheet" href="${cssUrl}"/>
<style>
  body { margin:0; padding:24px; font-family: var(--ops-font-body, system-ui, sans-serif); background: var(--ops-color-background, #fff); color: var(--ops-color-foreground, #0f172a); }
  .card { background:#fff; border-radius:12px; padding:20px; box-shadow:0 1px 2px rgba(0,0,0,.06); border:1px solid #e2e8f0; margin-bottom:16px; }
  .btn { display:inline-block; padding:8px 14px; border-radius:8px; font-weight:500; font-size:14px; border:none; cursor:pointer; margin-right:8px; }
  .btn-primary { background: var(--ops-color-primary-500, #0ea5e9); color:#fff; }
  .btn-secondary { background: var(--ops-color-secondary-200, #e2e8f0); color: var(--ops-color-secondary-900, #0f172a); }
  .btn-danger { background: var(--ops-color-danger, #ef4444); color:#fff; }
  h1 { font-family: var(--ops-font-heading, inherit); margin:0 0 8px 0; font-size:22px; }
  p { color: var(--ops-color-secondary-600, #475569); margin:0 0 12px 0; }
  .swatch-row { display:flex; gap:6px; flex-wrap:wrap; }
  .swatch { width:36px; height:36px; border-radius:6px; border:1px solid rgba(0,0,0,.08); }
  .label { font-size:12px; color: var(--ops-color-secondary-600, #475569); margin-bottom:6px; }
</style>
</head>
<body>
  <div class="card">
    <h1>Preview heading</h1>
    <p>This iframe re-renders on every save with the latest compiled CSS.</p>
    <button class="btn btn-primary">Primary</button>
    <button class="btn btn-secondary">Secondary</button>
    <button class="btn btn-danger">Danger</button>
  </div>
  <div class="card">
    <div class="label">Primary scale</div>
    <div class="swatch-row">
      ${[50, 100, 200, 300, 400, 500, 600, 700, 800, 900]
        .map(
          (s) =>
            `<div class="swatch" style="background:var(--ops-color-primary-${s})" title="primary-${s}"></div>`
        )
        .join('')}
    </div>
    <div class="label" style="margin-top:12px">Secondary scale</div>
    <div class="swatch-row">
      ${[50, 100, 200, 300, 400, 500, 600, 700, 800, 900]
        .map(
          (s) =>
            `<div class="swatch" style="background:var(--ops-color-secondary-${s})" title="secondary-${s}"></div>`
        )
        .join('')}
    </div>
  </div>
</body>
</html>`;
}

export default function ThemeEditorPage() {
  return (
    <ProtectedPage module="themes" title="Theme editor">
      <ThemeEditorContent />
    </ProtectedPage>
  );
}
