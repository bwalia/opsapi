'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Palette, Plus, Check, Copy, Trash2, Globe, Lock, Sparkles, Download } from 'lucide-react';
import toast from 'react-hot-toast';

import { Button, Badge, Card, Input, Textarea, ConfirmDialog, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { themesService } from '@/services/themes.service';
import type { Theme, ThemePreset, ThemeListMeta } from '@/types/theme';

type Tab = 'installed' | 'presets' | 'marketplace';

function ThemesPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [tab, setTab] = useState<Tab>('installed');

  const [installed, setInstalled] = useState<Theme[]>([]);
  const [presets, setPresets] = useState<ThemePreset[]>([]);
  const [marketplace, setMarketplace] = useState<Theme[]>([]);
  const [marketplaceMeta, setMarketplaceMeta] = useState<ThemeListMeta>({});
  const [isLoading, setIsLoading] = useState(true);

  const [createOpen, setCreateOpen] = useState(false);
  const [createForm, setCreateForm] = useState({ name: '', description: '', from_preset_slug: '' });
  const [isSubmitting, setIsSubmitting] = useState(false);

  const [confirmDelete, setConfirmDelete] = useState<Theme | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const fetchAll = useCallback(async () => {
    setIsLoading(true);
    try {
      const [installedRes, presetRes, marketRes] = await Promise.all([
        themesService.list(),
        themesService.listPresets(),
        themesService.listMarketplace(),
      ]);
      setInstalled(installedRes.items);
      setPresets(presetRes);
      setMarketplace(marketRes.items);
      setMarketplaceMeta(marketRes.meta);
    } catch (err) {
      console.error('Failed to load themes', err);
      toast.error('Failed to load themes');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchAll();
  }, [fetchAll]);

  const handleActivate = async (theme: Theme) => {
    try {
      await themesService.activate(theme.uuid);
      toast.success(`${theme.name} activated`);
      fetchAll();
    } catch {
      toast.error('Failed to activate theme');
    }
  };

  const handleDuplicate = async (theme: Theme) => {
    try {
      await themesService.duplicate(theme.uuid, `${theme.name} copy`);
      toast.success('Theme duplicated');
      fetchAll();
    } catch {
      toast.error('Failed to duplicate theme');
    }
  };

  const handleInstallPreset = async (preset: ThemePreset) => {
    if (!canCreate('themes')) {
      toast.error('You do not have permission to create themes');
      return;
    }
    try {
      await themesService.create({
        name: preset.name,
        from_preset_slug: preset.slug,
        description: preset.description ?? undefined,
      });
      toast.success(`Installed "${preset.name}"`);
      setTab('installed');
      fetchAll();
    } catch {
      toast.error('Failed to install preset');
    }
  };

  const handleInstallMarketplace = async (theme: Theme) => {
    try {
      await themesService.install(theme.uuid);
      toast.success(`Installed "${theme.name}"`);
      setTab('installed');
      fetchAll();
    } catch {
      toast.error('Failed to install theme');
    }
  };

  const handleCreate = async () => {
    if (!createForm.name.trim()) {
      toast.error('Theme name is required');
      return;
    }
    setIsSubmitting(true);
    try {
      const result = await themesService.create({
        name: createForm.name.trim(),
        description: createForm.description.trim() || undefined,
        from_preset_slug: createForm.from_preset_slug || undefined,
      });
      toast.success('Theme created');
      setCreateOpen(false);
      setCreateForm({ name: '', description: '', from_preset_slug: '' });
      fetchAll();
      if (result?.theme?.uuid) {
        window.location.href = `/dashboard/themes/${result.theme.uuid}`;
      }
    } catch {
      toast.error('Failed to create theme');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleDelete = async () => {
    if (!confirmDelete) return;
    setIsDeleting(true);
    try {
      await themesService.remove(confirmDelete.uuid);
      toast.success('Theme deleted');
      setConfirmDelete(null);
      fetchAll();
    } catch {
      toast.error('Failed to delete theme');
    } finally {
      setIsDeleting(false);
    }
  };

  const tabClass = (t: Tab) =>
    `px-4 py-2 text-sm font-medium rounded-md transition-colors ${
      tab === t
        ? 'bg-primary-100 text-primary-700'
        : 'text-secondary-600 hover:text-secondary-900 hover:bg-secondary-50'
    }`;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-secondary-900 flex items-center gap-2">
            <Palette className="w-6 h-6 text-primary-600" />
            Themes
          </h1>
          <p className="text-sm text-secondary-600 mt-1">
            Customize the look and feel of your workspace
          </p>
        </div>
        {canCreate('themes') && (
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="w-4 h-4 mr-2" />
            New Theme
          </Button>
        )}
      </div>

      <div className="flex items-center gap-2 border-b border-secondary-200 pb-3">
        <button className={tabClass('installed')} onClick={() => setTab('installed')}>
          Installed ({installed.length})
        </button>
        <button className={tabClass('presets')} onClick={() => setTab('presets')}>
          Platform Presets ({presets.length})
        </button>
        <button className={tabClass('marketplace')} onClick={() => setTab('marketplace')}>
          Marketplace ({marketplaceMeta.total ?? marketplace.length})
        </button>
      </div>

      {isLoading ? (
        <div className="text-center py-12 text-secondary-500">Loading themes…</div>
      ) : tab === 'installed' ? (
        <ThemeGrid
          themes={installed}
          emptyMessage="No themes installed. Try a platform preset or browse the marketplace."
          onActivate={handleActivate}
          onDuplicate={canCreate('themes') ? handleDuplicate : undefined}
          onDelete={canDelete('themes') ? (t) => setConfirmDelete(t) : undefined}
          editable={canUpdate('themes')}
        />
      ) : tab === 'presets' ? (
        <PresetGrid
          presets={presets}
          onInstall={canCreate('themes') ? handleInstallPreset : undefined}
        />
      ) : (
        <ThemeGrid
          themes={marketplace}
          emptyMessage="No marketplace themes available yet."
          onInstall={canCreate('themes') ? handleInstallMarketplace : undefined}
          variant="marketplace"
        />
      )}

      <Modal
        isOpen={createOpen}
        onClose={() => setCreateOpen(false)}
        title="Create new theme"
        size="md"
      >
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Name</label>
            <Input
              value={createForm.name}
              onChange={(e) => setCreateForm({ ...createForm, name: e.target.value })}
              placeholder="My brand theme"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">
              Description (optional)
            </label>
            <Textarea
              value={createForm.description}
              onChange={(e) => setCreateForm({ ...createForm, description: e.target.value })}
              rows={2}
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">
              Start from preset (optional)
            </label>
            <select
              className="w-full border border-secondary-300 rounded-md px-3 py-2 text-sm"
              value={createForm.from_preset_slug}
              onChange={(e) => setCreateForm({ ...createForm, from_preset_slug: e.target.value })}
            >
              <option value="">Blank</option>
              {presets.map((p) => (
                <option key={p.slug} value={p.slug}>
                  {p.name}
                </option>
              ))}
            </select>
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="secondary" onClick={() => setCreateOpen(false)}>
              Cancel
            </Button>
            <Button onClick={handleCreate} disabled={isSubmitting}>
              {isSubmitting ? 'Creating…' : 'Create theme'}
            </Button>
          </div>
        </div>
      </Modal>

      <ConfirmDialog
        isOpen={!!confirmDelete}
        onClose={() => setConfirmDelete(null)}
        onConfirm={handleDelete}
        title="Delete theme"
        message={`Are you sure you want to delete "${confirmDelete?.name}"? This cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </div>
  );
}

function ThemeGrid({
  themes,
  emptyMessage,
  onActivate,
  onDuplicate,
  onDelete,
  onInstall,
  editable,
  variant,
}: {
  themes: Theme[];
  emptyMessage: string;
  onActivate?: (t: Theme) => void;
  onDuplicate?: (t: Theme) => void;
  onDelete?: (t: Theme) => void;
  onInstall?: (t: Theme) => void;
  editable?: boolean;
  variant?: 'marketplace';
}) {
  if (themes.length === 0) {
    return (
      <Card>
        <div className="text-center py-10 text-sm text-secondary-500">{emptyMessage}</div>
      </Card>
    );
  }
  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
      {themes.map((theme) => (
        <Card key={theme.uuid}>
          <div className="p-5 space-y-3">
            <div className="flex items-start justify-between">
              <div className="flex-1 min-w-0">
                <h3 className="text-base font-semibold text-secondary-900 truncate">
                  {theme.name}
                </h3>
                <p className="text-xs text-secondary-500 mt-0.5">{theme.slug}</p>
              </div>
              <div className="flex items-center gap-1">
                {theme.is_active && (
                  <Badge variant="success">
                    <Check className="w-3 h-3 mr-1" />
                    Active
                  </Badge>
                )}
                {theme.visibility === 'public' && (
                  <Badge variant="info">
                    <Globe className="w-3 h-3 mr-1" />
                    Public
                  </Badge>
                )}
                {theme.visibility === 'private' && (
                  <Badge variant="default">
                    <Lock className="w-3 h-3 mr-1" />
                    Private
                  </Badge>
                )}
              </div>
            </div>

            {theme.description && (
              <p className="text-sm text-secondary-600 line-clamp-2">{theme.description}</p>
            )}

            <div className="flex items-center gap-2 pt-2 flex-wrap">
              {variant === 'marketplace' ? (
                onInstall && (
                  <Button size="sm" onClick={() => onInstall(theme)}>
                    <Download className="w-3.5 h-3.5 mr-1" />
                    Install
                  </Button>
                )
              ) : (
                <>
                  {editable && (
                    <Link href={`/dashboard/themes/${theme.uuid}`}>
                      <Button size="sm" variant="secondary">
                        Edit
                      </Button>
                    </Link>
                  )}
                  {!theme.is_active && onActivate && (
                    <Button size="sm" onClick={() => onActivate(theme)}>
                      Activate
                    </Button>
                  )}
                  {onDuplicate && (
                    <Button size="sm" variant="secondary" onClick={() => onDuplicate(theme)}>
                      <Copy className="w-3.5 h-3.5 mr-1" />
                      Duplicate
                    </Button>
                  )}
                  {onDelete && !theme.is_platform && !theme.is_active && (
                    <Button size="sm" variant="danger" onClick={() => onDelete(theme)}>
                      <Trash2 className="w-3.5 h-3.5" />
                    </Button>
                  )}
                </>
              )}
            </div>
          </div>
        </Card>
      ))}
    </div>
  );
}

function PresetGrid({
  presets,
  onInstall,
}: {
  presets: ThemePreset[];
  onInstall?: (p: ThemePreset) => void;
}) {
  if (presets.length === 0) {
    return (
      <Card>
        <div className="text-center py-10 text-sm text-secondary-500">
          No presets available for this project.
        </div>
      </Card>
    );
  }
  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
      {presets.map((preset) => (
        <Card key={preset.slug}>
          <div className="p-5 space-y-3">
            <div className="flex items-start justify-between gap-2">
              <div className="flex-1 min-w-0">
                <h3 className="text-base font-semibold text-secondary-900 truncate">
                  {preset.name}
                </h3>
                <p className="text-xs text-secondary-500 mt-0.5">{preset.slug}</p>
              </div>
              <Badge variant="info">
                <Sparkles className="w-3 h-3 mr-1" />
                Preset
              </Badge>
            </div>
            {preset.description && (
              <p className="text-sm text-secondary-600 line-clamp-2">{preset.description}</p>
            )}
            <div className="pt-2">
              {onInstall && (
                <Button size="sm" onClick={() => onInstall(preset)}>
                  <Download className="w-3.5 h-3.5 mr-1" />
                  Install
                </Button>
              )}
            </div>
          </div>
        </Card>
      ))}
    </div>
  );
}

export default function ThemesPage() {
  return (
    <ProtectedPage module="themes" title="Themes">
      <ThemesPageContent />
    </ProtectedPage>
  );
}
