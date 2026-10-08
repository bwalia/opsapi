'use client';

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Pencil, Plus, Trash2 } from 'lucide-react';
import { Button, ConfirmDialog, Input, Modal, Select, Table } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { billingService, type BillingApp, type BillingFeature, type FeatureType } from '@/services/billing.service';
import type { TableColumn } from '@/types';

const toKey = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 64);

function FeatureModal({
  app,
  feature,
  isOpen,
  onClose,
  onSaved,
}: {
  app: BillingApp;
  feature: BillingFeature | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState('');
  const [key, setKey] = useState('');
  const [keyTouched, setKeyTouched] = useState(false);
  const [type, setType] = useState<FeatureType>('boolean');
  const [unit, setUnit] = useState('');
  const [description, setDescription] = useState('');
  const [releasedAt, setReleasedAt] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setName(feature?.name || '');
    setKey(feature?.key || '');
    setKeyTouched(!!feature);
    setType(feature?.type || 'boolean');
    setUnit(feature?.unit || '');
    setDescription(feature?.description || '');
    setReleasedAt(feature?.released_at ? feature.released_at.slice(0, 10) : '');
  }, [isOpen, feature]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const body = {
        name: name.trim(),
        unit: unit.trim(),
        description: description.trim(),
        released_at: releasedAt ? `${releasedAt}T00:00:00Z` : null,
      };
      if (feature) await billingService.updateFeature(app.uuid, feature.key, body);
      else await billingService.addFeature(app.uuid, { ...body, key, type });
      toast.success(feature ? 'Feature updated' : 'Feature added');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the feature'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={feature ? 'Edit feature' : 'Add feature'}
      description="Something your app can switch on or limit, per plan."
    >
      <form onSubmit={submit} className="space-y-4">
        <Input
          label="Name"
          value={name}
          onChange={(e) => {
            setName(e.target.value);
            if (!keyTouched) setKey(toKey(e.target.value));
          }}
          placeholder="Advanced reports"
          required
          maxLength={120}
          autoFocus
        />
        <Input
          label="Key (what your code checks)"
          value={key}
          onChange={(e) => {
            setKeyTouched(true);
            setKey(e.target.value);
          }}
          disabled={!!feature}
          pattern="[a-z0-9_]{1,64}"
          helperText={feature ? "A feature's key can't change." : 'Lowercase letters, digits and _'}
          required
          className="font-mono"
        />
        <Select
          label="Type"
          value={type}
          onChange={(e) => setType(e.target.value as FeatureType)}
          disabled={!!feature}
          helperText={type === 'limit' ? 'A number per plan (or unlimited), e.g. projects or seats.' : 'Included or not, per plan.'}
        >
          <option value="boolean">On / off</option>
          <option value="limit">Limit (a number)</option>
        </Select>
        {type === 'limit' && <Input label="Unit" value={unit} onChange={(e) => setUnit(e.target.value)} placeholder="projects" />}
        <Input label="Description (optional)" value={description} onChange={(e) => setDescription(e.target.value)} />
        <Input
          label="Released on (optional)"
          type="date"
          value={releasedAt}
          onChange={(e) => setReleasedAt(e.target.value)}
          helperText="Lifetime and fixed-term buyers get it only if it was released inside their updates window."
        />
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!name.trim() || !key}>
            {feature ? 'Save' : 'Add feature'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

export default function AppFeatures({
  app,
  features,
  onChanged,
}: {
  app: BillingApp;
  features: BillingFeature[];
  onChanged: () => void;
}) {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [modalOpen, setModalOpen] = useState(false);
  const [editing, setEditing] = useState<BillingFeature | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<BillingFeature | null>(null);
  const [deleting, setDeleting] = useState(false);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await billingService.deleteFeature(app.uuid, deleteTarget.key);
      toast.success('Feature removed');
      setDeleteTarget(null);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove the feature'));
    } finally {
      setDeleting(false);
    }
  };

  const columns: TableColumn<BillingFeature>[] = [
    {
      key: 'name',
      header: 'Feature',
      render: (f) => (
        <div>
          <p className="font-medium text-secondary-900">{f.name}</p>
          {f.description && <p className="text-xs text-secondary-500">{f.description}</p>}
        </div>
      ),
    },
    { key: 'key', header: 'Key', render: (f) => <code className="text-xs">{f.key}</code> },
    {
      key: 'released',
      header: 'Released',
      render: (f) => <span className="text-sm text-secondary-600">{f.released_at ? f.released_at.slice(0, 10) : '—'}</span>,
    },
    {
      key: 'type',
      header: 'Type',
      render: (f) => (
        <Pill className={f.type === 'limit' ? 'bg-blue-50 text-blue-700' : 'bg-secondary-100 text-secondary-700'}>
          {f.type === 'limit' ? `Limit${f.unit ? ` (${f.unit})` : ''}` : 'On / off'}
        </Pill>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-24',
      render: (f) => (
        <div className="flex items-center gap-1">
          {canUpdate('billing') && (
            <button
              type="button"
              onClick={() => {
                setEditing(f);
                setModalOpen(true);
              }}
              className="p-2 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
              aria-label={`Edit ${f.name}`}
            >
              <Pencil className="w-4 h-4" />
            </button>
          )}
          {canDelete('billing') && (
            <button
              type="button"
              onClick={() => setDeleteTarget(f)}
              className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
              aria-label={`Remove ${f.name}`}
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-secondary-500">
          Your code checks these keys, e.g. <code className="text-xs">can(&quot;advanced_reports&quot;)</code>. Each plan
          sets a value for every feature.
        </p>
        {canCreate('billing') && (
          <Button
            onClick={() => {
              setEditing(null);
              setModalOpen(true);
            }}
          >
            <Plus className="w-4 h-4 mr-1.5" /> Add feature
          </Button>
        )}
      </div>
      <Table columns={columns} data={features} keyExtractor={(f) => f.uuid} emptyMessage="No features yet." />
      <FeatureModal
        app={app}
        feature={editing}
        isOpen={modalOpen}
        onClose={() => setModalOpen(false)}
        onSaved={() => {
          setModalOpen(false);
          onChanged();
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title={`Remove ${deleteTarget?.name || 'feature'}?`}
        message="It is removed from every plan and grant of this app, and your app's checks for it will return off / 0."
        confirmText="Remove"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}
