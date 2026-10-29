'use client';

/**
 * Single sign-on — /dashboard/namespace/sso
 *
 * Connect the workspace to a SAML 2.0 identity provider (Okta, Microsoft Entra
 * ID, Google Workspace, OneLogin, JumpCloud, Keycloak…). People then use
 * "Sign in with SSO" on the login page. Backed by lapis/routes/saml.lua.
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Check, Copy, FileCode2, KeyRound, Pencil, Plus, ShieldCheck, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Modal, Textarea } from '@/components/ui';
import Switch from '@/components/ui/Switch';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { Pill, apiError } from '@/components/field-service/shared';
import { ssoService, type SamlProvider, type SamlProviderInput } from '@/services/sso.service';

function CopyField({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div>
      <p className="text-xs font-medium text-secondary-500 mb-1">{label}</p>
      <div className="flex items-center gap-2">
        <code className="flex-1 min-w-0 truncate rounded-lg bg-secondary-50 border border-secondary-200 px-3 py-1.5 text-xs text-secondary-800" title={value}>
          {value}
        </code>
        <button
          type="button"
          onClick={async () => {
            await navigator.clipboard.writeText(value);
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
          }}
          className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
          aria-label={`Copy ${label}`}
          title={`Copy ${label}`}
        >
          {copied ? <Check className="w-4 h-4 text-green-600" /> : <Copy className="w-4 h-4" />}
        </button>
      </div>
    </div>
  );
}

const EMPTY: Required<Omit<SamlProviderInput, 'attribute_mapping'>> & {
  attribute_mapping: { email: string; first_name: string; last_name: string };
} = {
  name: '',
  idp_entity_id: '',
  idp_sso_url: '',
  idp_x509_cert: '',
  email_domains: '',
  default_role: '',
  auto_provision: true,
  allow_idp_initiated: false,
  is_enabled: true,
  attribute_mapping: { email: '', first_name: '', last_name: '' },
};

function ProviderModal({
  provider,
  isOpen,
  onClose,
  onSaved,
}: {
  provider: SamlProvider | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [form, setForm] = useState(EMPTY);
  const [metadata, setMetadata] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setMetadata('');
    setForm(
      provider
        ? {
            name: provider.name,
            idp_entity_id: provider.idp_entity_id,
            idp_sso_url: provider.idp_sso_url,
            idp_x509_cert: provider.idp_x509_cert,
            email_domains: provider.email_domains.join(', '),
            default_role: provider.default_role ?? '',
            auto_provision: provider.auto_provision,
            allow_idp_initiated: provider.allow_idp_initiated,
            is_enabled: provider.is_enabled,
            attribute_mapping: {
              email: provider.attribute_mapping?.email ?? '',
              first_name: provider.attribute_mapping?.first_name ?? '',
              last_name: provider.attribute_mapping?.last_name ?? '',
            },
          }
        : EMPTY
    );
  }, [isOpen, provider]);

  const set = <K extends keyof typeof EMPTY>(key: K, value: (typeof EMPTY)[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const importMetadata = async () => {
    try {
      const fields = await ssoService.parseMetadata(metadata);
      setForm((f) => ({ ...f, ...fields }));
      toast.success('Filled in from the IdP metadata');
    } catch (err) {
      toast.error(apiError(err, 'Could not read the metadata'));
    }
  };

  const save = async () => {
    setSaving(true);
    try {
      if (provider) await ssoService.update(provider.uuid, form);
      else await ssoService.create(form);
      toast.success(provider ? 'Provider updated' : 'Provider added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the provider'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={provider ? 'Edit identity provider' : 'Add identity provider'}
      description="Paste your IdP's metadata XML, or fill the fields in by hand."
      size="2xl"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={save} isLoading={saving} data-testid="sso-save">Save</Button>
        </div>
      }
    >
      <div className="space-y-4">
        <Input label="Name" placeholder="Okta" value={form.name} onChange={(e) => set('name', e.target.value)} />
        <div className="rounded-xl border border-dashed border-secondary-300 p-3 space-y-2">
          <Textarea
            label="IdP metadata XML (optional)"
            rows={3}
            placeholder="<md:EntityDescriptor …>"
            value={metadata}
            onChange={(e) => setMetadata(e.target.value)}
          />
          <Button variant="outline" size="sm" onClick={importMetadata} disabled={!metadata.trim()}>
            <FileCode2 className="w-4 h-4 mr-1.5" /> Fill in from metadata
          </Button>
        </div>
        <Input label="IdP entity ID (Issuer)" value={form.idp_entity_id} onChange={(e) => set('idp_entity_id', e.target.value)} />
        <Input
          label="IdP sign-in URL (HTTP-Redirect)"
          placeholder="https://idp.example.com/sso/saml"
          value={form.idp_sso_url}
          onChange={(e) => set('idp_sso_url', e.target.value)}
        />
        <Textarea
          label="IdP signing certificate"
          rows={4}
          placeholder="-----BEGIN CERTIFICATE-----"
          value={form.idp_x509_cert}
          onChange={(e) => set('idp_x509_cert', e.target.value)}
          className="font-mono text-xs"
        />
        <Input
          label="Email domains"
          placeholder="acme.com, acme.co.uk"
          helperText="Only these addresses can sign in with this provider, and the login page finds it from them."
          value={form.email_domains}
          onChange={(e) => set('email_domains', e.target.value)}
        />
        <Input
          label="Role for new members"
          placeholder="member"
          helperText="A role name in this workspace. Empty uses the workspace's default role."
          value={form.default_role}
          onChange={(e) => set('default_role', e.target.value)}
        />
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <Input label="Email attribute" placeholder="email" value={form.attribute_mapping.email}
            onChange={(e) => set('attribute_mapping', { ...form.attribute_mapping, email: e.target.value })} />
          <Input label="First name attribute" placeholder="firstName" value={form.attribute_mapping.first_name}
            onChange={(e) => set('attribute_mapping', { ...form.attribute_mapping, first_name: e.target.value })} />
          <Input label="Last name attribute" placeholder="lastName" value={form.attribute_mapping.last_name}
            onChange={(e) => set('attribute_mapping', { ...form.attribute_mapping, last_name: e.target.value })} />
        </div>
        {[
          ['auto_provision', 'Create accounts on first sign-in', 'Off: people must be invited to the workspace first.'],
          ['allow_idp_initiated', 'Allow IdP-initiated sign-in', 'Let people start from the IdP dashboard tile. Less protected against login CSRF.'],
          ['is_enabled', 'Enabled', 'Turn the provider off without deleting it.'],
        ].map(([key, label, help]) => (
          <div key={key} className="flex items-start justify-between gap-4">
            <div>
              <p className="text-sm font-medium text-secondary-800">{label}</p>
              <p className="text-xs text-secondary-500">{help}</p>
            </div>
            <Switch
              checked={form[key as 'auto_provision'] as boolean}
              onChange={(v) => set(key as 'auto_provision', v)}
              aria-label={label}
            />
          </div>
        ))}
      </div>
    </Modal>
  );
}

function SsoPageContent() {
  const { canManage } = usePermissions();
  const allowEdit = canManage('namespace');
  const [providers, setProviders] = useState<SamlProvider[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<{ provider: SamlProvider | null } | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<SamlProvider | null>(null);
  const [working, setWorking] = useState(false);

  const load = useCallback(async () => {
    try {
      setProviders(await ssoService.list());
    } catch (err) {
      toast.error(apiError(err, 'Could not load identity providers'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const remove = async () => {
    if (!deleteTarget) return;
    setWorking(true);
    try {
      await ssoService.remove(deleteTarget.uuid);
      toast.success('Provider deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete the provider'));
    } finally {
      setWorking(false);
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Single sign-on"
        description="Let people sign in with your company's identity provider over SAML 2.0."
        icon={<KeyRound className="w-5 h-5" />}
        actions={
          allowEdit ? (
            <Button onClick={() => setEditing({ provider: null })} data-testid="sso-add">
              <Plus className="w-4 h-4 mr-1.5" /> Add identity provider
            </Button>
          ) : undefined
        }
      />

      {!loading && providers.length === 0 && (
        <Card padding="lg">
          <div className="flex flex-col items-center text-center py-8 gap-3">
            <div className="w-12 h-12 rounded-xl bg-primary-50 text-primary-600 flex items-center justify-center">
              <ShieldCheck className="w-6 h-6" />
            </div>
            <h2 className="text-lg font-semibold text-secondary-900">No identity provider yet</h2>
            <p className="text-sm text-secondary-500 max-w-md">
              Connect Okta, Microsoft Entra ID, Google Workspace, OneLogin, JumpCloud, Keycloak or any SAML 2.0 IdP.
              Your people then choose &ldquo;Sign in with SSO&rdquo; and use their work account.
            </p>
            {allowEdit && (
              <Button onClick={() => setEditing({ provider: null })}>
                <Plus className="w-4 h-4 mr-1.5" /> Add your identity provider
              </Button>
            )}
          </div>
        </Card>
      )}

      {providers.map((p) => (
        <Card key={p.uuid} padding="lg">
          <div className="flex flex-wrap items-start justify-between gap-3 mb-4">
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-lg font-semibold text-secondary-900">{p.name}</h2>
                <Pill className={p.is_enabled ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>
                  {p.is_enabled ? 'Enabled' : 'Off'}
                </Pill>
              </div>
              <p className="text-xs text-secondary-500 mt-1">
                {p.email_domains.length ? `Domains: ${p.email_domains.join(', ')}` : 'Any email domain'}
                {' · '}
                {p.login_count} sign-in{p.login_count === 1 ? '' : 's'}
                {p.last_login_at ? ` · last ${new Date(p.last_login_at).toLocaleString()}` : ''}
              </p>
            </div>
            {allowEdit && (
              <div className="flex items-center gap-1">
                <button
                  type="button"
                  onClick={() => setEditing({ provider: p })}
                  className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                  aria-label="Edit provider"
                  title="Edit provider"
                >
                  <Pencil className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  onClick={() => setDeleteTarget(p)}
                  className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                  aria-label="Delete provider"
                  title="Delete provider"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            )}
          </div>
          <p className="text-sm font-medium text-secondary-700 mb-2">Give these to your identity provider</p>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
            <CopyField label="Metadata URL" value={p.sp.sp_entity_id} />
            <CopyField label="Entity ID (Audience)" value={p.sp.sp_entity_id} />
            <CopyField label="ACS URL (Reply URL)" value={p.sp.acs_url} />
            <CopyField label="Direct sign-in link" value={p.sp.login_url} />
          </div>
          <p className="text-xs text-secondary-500 mt-3">
            NameID format: email address. Send <code>email</code>, <code>firstName</code> and <code>lastName</code>{' '}
            attributes, and sign the response or the assertion with SHA-256.
          </p>
        </Card>
      ))}

      <ProviderModal
        isOpen={!!editing}
        provider={editing?.provider ?? null}
        onClose={() => setEditing(null)}
        onSaved={load}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete identity provider"
        message={`People can no longer sign in through ${deleteTarget?.name ?? ''}. Their accounts stay; they can reset a password to sign in.`}
        confirmText="Delete"
        variant="danger"
        isLoading={working}
      />
    </div>
  );
}

export default function SsoPage() {
  return (
    <ProtectedPage module="namespace" title="Single sign-on">
      <SsoPageContent />
    </ProtectedPage>
  );
}
