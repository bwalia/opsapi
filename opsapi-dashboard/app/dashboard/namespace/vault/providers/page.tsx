'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { Shield, Cloud, Server, Lock, FileText, Plus, RefreshCw, Trash2, Settings, ArrowLeft, CheckCircle, XCircle, Loader2, Upload, Download } from 'lucide-react';
import { vaultProvidersService, VaultProvider, ProviderType, SyncLog } from '@/services/vault-providers.service';
import { getVaultKey } from '@/services/vault.service';

const PROVIDER_ICONS: Record<string, typeof Shield> = {
  hashicorp_vault: Shield,
  aws_secrets_manager: Cloud,
  azure_key_vault: Lock,
  gcp_secret_manager: Cloud,
  kubernetes: Server,
  env_file: FileText,
  dotenv: FileText,
};

const STATUS_COLORS: Record<string, string> = {
  active: 'bg-green-100 text-green-800',
  inactive: 'bg-gray-100 text-gray-800',
  error: 'bg-red-100 text-red-800',
  syncing: 'bg-blue-100 text-blue-800',
};

const CONFIG_FIELDS: Record<string, Array<{ key: string; label: string; type?: string; placeholder?: string; required?: boolean }>> = {
  hashicorp_vault: [
    { key: 'vault_url', label: 'Vault URL', placeholder: 'https://vault.example.com:8200', required: true },
    { key: 'auth_method', label: 'Auth Method', type: 'select', placeholder: 'token' },
    { key: 'token', label: 'Token', type: 'password', placeholder: 'hvs.xxxxx' },
    { key: 'mount_path', label: 'Mount Path', placeholder: 'secret' },
    { key: 'namespace', label: 'Namespace (Enterprise)', placeholder: 'admin' },
  ],
  aws_secrets_manager: [
    { key: 'region', label: 'AWS Region', placeholder: 'us-east-1', required: true },
    { key: 'access_key_id', label: 'Access Key ID', required: true },
    { key: 'secret_access_key', label: 'Secret Access Key', type: 'password', required: true },
    { key: 'prefix', label: 'Secret Name Prefix', placeholder: 'myapp/' },
  ],
  azure_key_vault: [
    { key: 'vault_url', label: 'Vault URL', placeholder: 'https://myvault.vault.azure.net', required: true },
    { key: 'tenant_id', label: 'Tenant ID', required: true },
    { key: 'client_id', label: 'Client ID', required: true },
    { key: 'client_secret', label: 'Client Secret', type: 'password', required: true },
  ],
  kubernetes: [
    { key: 'api_server', label: 'API Server', placeholder: 'https://kubernetes.default.svc (leave empty for in-cluster)' },
    { key: 'token', label: 'Service Account Token', type: 'password' },
    { key: 'k8s_namespace', label: 'Kubernetes Namespace', placeholder: 'default', required: true },
  ],
  env_file: [
    { key: 'file_content', label: 'Paste .env content', type: 'textarea', required: true },
  ],
};

export default function VaultProvidersPage() {
  const router = useRouter();
  const [providers, setProviders] = useState<VaultProvider[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [showImportModal, setShowImportModal] = useState(false);
  const [selectedType, setSelectedType] = useState<string>('');
  const [formData, setFormData] = useState<Record<string, string>>({});
  const [providerName, setProviderName] = useState('');
  const [providerDesc, setProviderDesc] = useState('');
  const [syncDirection, setSyncDirection] = useState('import');
  const [isTesting, setIsTesting] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [envContent, setEnvContent] = useState('');
  const [syncingId, setSyncingId] = useState<string | null>(null);
  const [showLogsFor, setShowLogsFor] = useState<string | null>(null);
  const [syncLogs, setSyncLogs] = useState<SyncLog[]>([]);
  const fetchIdRef = useRef(0);

  const vaultKey = getVaultKey();

  const fetchProviders = useCallback(async () => {
    if (!vaultKey) return;
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const data = await vaultProvidersService.getProviders(vaultKey);
      if (fetchId === fetchIdRef.current) setProviders(data);
    } catch {
      toast.error('Failed to load providers');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [vaultKey]);

  useEffect(() => {
    if (!vaultKey) {
      router.push('/dashboard/namespace/vault');
      return;
    }
    fetchProviders();
  }, [vaultKey, fetchProviders, router]);

  const handleTestConnection = async () => {
    if (!vaultKey || !selectedType) return;
    setIsTesting(true);
    try {
      const result = await vaultProvidersService.testConnection(vaultKey, selectedType, formData);
      if (result.connected) {
        toast.success('Connection successful!');
      } else {
        toast.error(result.error || 'Connection failed');
      }
    } catch {
      toast.error('Connection test failed');
    } finally {
      setIsTesting(false);
    }
  };

  const handleCreateProvider = async () => {
    if (!vaultKey) return;
    setIsSaving(true);
    try {
      await vaultProvidersService.createProvider(vaultKey, {
        provider_type: selectedType,
        name: providerName,
        description: providerDesc,
        config: formData,
        sync_direction: syncDirection,
      });
      toast.success('Provider connected!');
      setShowCreateModal(false);
      resetForm();
      fetchProviders();
    } catch {
      toast.error('Failed to create provider');
    } finally {
      setIsSaving(false);
    }
  };

  const handleSync = async (uuid: string) => {
    if (!vaultKey) return;
    setSyncingId(uuid);
    try {
      const result = await vaultProvidersService.triggerSync(vaultKey, uuid);
      toast.success(`Sync complete: ${result.created} created, ${result.updated} updated${result.failed > 0 ? `, ${result.failed} failed` : ''}`);
      fetchProviders();
    } catch {
      toast.error('Sync failed');
    } finally {
      setSyncingId(null);
    }
  };

  const handleDelete = async (uuid: string) => {
    if (!vaultKey || !confirm('Delete this provider?')) return;
    try {
      await vaultProvidersService.deleteProvider(vaultKey, uuid);
      toast.success('Provider removed');
      fetchProviders();
    } catch {
      toast.error('Failed to delete');
    }
  };

  const handleImportEnv = async () => {
    if (!vaultKey || !envContent.trim()) return;
    try {
      const result = await vaultProvidersService.importEnv(vaultKey, envContent);
      toast.success(`Imported ${result.created} secrets${result.failed > 0 ? ` (${result.failed} failed)` : ''}`);
      setShowImportModal(false);
      setEnvContent('');
    } catch {
      toast.error('Import failed');
    }
  };

  const handleExportEnv = async () => {
    if (!vaultKey) return;
    try {
      const content = await vaultProvidersService.exportEnv(vaultKey);
      const blob = new Blob([content], { type: 'text/plain' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'vault-secrets.env';
      a.click();
      URL.revokeObjectURL(url);
      toast.success('Exported as .env');
    } catch {
      toast.error('Export failed');
    }
  };

  const handleViewLogs = async (uuid: string) => {
    if (!vaultKey) return;
    setShowLogsFor(showLogsFor === uuid ? null : uuid);
    if (showLogsFor !== uuid) {
      try {
        const result = await vaultProvidersService.getSyncLogs(vaultKey, uuid);
        setSyncLogs(result.data || []);
      } catch {
        toast.error('Failed to load logs');
      }
    }
  };

  const resetForm = () => {
    setSelectedType('');
    setFormData({});
    setProviderName('');
    setProviderDesc('');
    setSyncDirection('import');
  };

  if (!vaultKey) return null;

  return (
    <div className="p-6 max-w-6xl mx-auto">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <button onClick={() => router.push('/dashboard/namespace/vault')} className="p-2 hover:bg-gray-100 rounded-lg">
            <ArrowLeft size={20} />
          </button>
          <div>
            <h1 className="text-2xl font-bold">External Providers</h1>
            <p className="text-gray-500 text-sm">Connect to HashiCorp Vault, AWS, Azure, Kubernetes, and more</p>
          </div>
        </div>
        <div className="flex gap-2">
          <button onClick={() => setShowImportModal(true)} className="flex items-center gap-2 px-4 py-2 border rounded-lg hover:bg-gray-50">
            <Upload size={16} /> Import .env
          </button>
          <button onClick={handleExportEnv} className="flex items-center gap-2 px-4 py-2 border rounded-lg hover:bg-gray-50">
            <Download size={16} /> Export .env
          </button>
          <button onClick={() => setShowCreateModal(true)} className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700">
            <Plus size={16} /> Connect Provider
          </button>
        </div>
      </div>

      {/* Provider Cards */}
      {isLoading ? (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {[1, 2].map(i => <div key={i} className="bg-white border rounded-xl p-6 animate-pulse h-40" />)}
        </div>
      ) : providers.length === 0 ? (
        <div className="text-center py-16 bg-white border rounded-xl">
          <Shield size={48} className="mx-auto text-gray-300 mb-4" />
          <h3 className="text-lg font-semibold text-gray-600 mb-2">No providers connected</h3>
          <p className="text-gray-400 mb-4">Connect to external secret managers to sync your secrets</p>
          <button onClick={() => setShowCreateModal(true)} className="px-4 py-2 bg-primary-600 text-white rounded-lg">
            Connect Your First Provider
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {providers.map(provider => {
            const Icon = PROVIDER_ICONS[provider.provider_type] || Shield;
            return (
              <div key={provider.uuid} className="bg-white border rounded-xl p-6 hover:shadow-md transition-shadow">
                <div className="flex items-start justify-between mb-3">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 bg-primary-50 rounded-lg flex items-center justify-center">
                      <Icon size={20} className="text-primary-600" />
                    </div>
                    <div>
                      <h3 className="font-semibold">{provider.name}</h3>
                      <p className="text-xs text-gray-500">{provider.provider_type.replace(/_/g, ' ')}</p>
                    </div>
                  </div>
                  <span className={`px-2 py-1 text-xs font-medium rounded-full ${STATUS_COLORS[provider.status] || STATUS_COLORS.inactive}`}>
                    {provider.status}
                  </span>
                </div>

                {provider.description && <p className="text-sm text-gray-500 mb-3">{provider.description}</p>}

                <div className="flex items-center gap-4 text-xs text-gray-500 mb-4">
                  <span>{provider.secrets_synced_count} secrets synced</span>
                  <span>{provider.sync_direction}</span>
                  {provider.last_sync_at && <span>Last: {new Date(provider.last_sync_at).toLocaleDateString()}</span>}
                </div>

                {provider.status === 'error' && provider.last_sync_error && (
                  <div className="bg-red-50 text-red-700 text-xs p-2 rounded mb-3">{provider.last_sync_error}</div>
                )}

                <div className="flex gap-2">
                  <button
                    onClick={() => handleSync(provider.uuid)}
                    disabled={syncingId === provider.uuid}
                    className="flex items-center gap-1 px-3 py-1.5 text-sm bg-primary-50 text-primary-700 rounded-lg hover:bg-primary-100 disabled:opacity-50"
                  >
                    {syncingId === provider.uuid ? <Loader2 size={14} className="animate-spin" /> : <RefreshCw size={14} />}
                    Sync Now
                  </button>
                  <button onClick={() => handleViewLogs(provider.uuid)} className="flex items-center gap-1 px-3 py-1.5 text-sm border rounded-lg hover:bg-gray-50">
                    <Settings size={14} /> Logs
                  </button>
                  <button onClick={() => handleDelete(provider.uuid)} className="flex items-center gap-1 px-3 py-1.5 text-sm text-red-600 border border-red-200 rounded-lg hover:bg-red-50">
                    <Trash2 size={14} />
                  </button>
                </div>

                {/* Sync Logs Expandable */}
                {showLogsFor === provider.uuid && (
                  <div className="mt-4 border-t pt-3">
                    <h4 className="text-sm font-medium mb-2">Sync History</h4>
                    {syncLogs.length === 0 ? (
                      <p className="text-xs text-gray-400">No sync history yet</p>
                    ) : (
                      <div className="space-y-2 max-h-48 overflow-y-auto">
                        {syncLogs.map(log => (
                          <div key={log.uuid} className="flex items-center gap-3 text-xs p-2 bg-gray-50 rounded">
                            {log.secrets_failed > 0 ? <XCircle size={14} className="text-red-500" /> : <CheckCircle size={14} className="text-green-500" />}
                            <span className="flex-1">{log.secrets_created} created, {log.secrets_updated} updated{log.secrets_failed > 0 ? `, ${log.secrets_failed} failed` : ''}</span>
                            <span className="text-gray-400">{log.duration_ms ? `${log.duration_ms}ms` : ''}</span>
                            <span className="text-gray-400">{new Date(log.created_at).toLocaleString()}</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Create Provider Modal */}
      {showCreateModal && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-xl w-full max-w-xl max-h-[90vh] overflow-y-auto">
            <div className="p-6 border-b">
              <h2 className="text-lg font-semibold">Connect External Provider</h2>
            </div>
            <div className="p-6 space-y-4">
              {!selectedType ? (
                <div className="grid grid-cols-1 gap-3">
                  {Object.entries(CONFIG_FIELDS).map(([type]) => {
                    const Icon = PROVIDER_ICONS[type] || Shield;
                    const labels: Record<string, string> = {
                      hashicorp_vault: 'HashiCorp Vault',
                      aws_secrets_manager: 'AWS Secrets Manager',
                      azure_key_vault: 'Azure Key Vault',
                      kubernetes: 'Kubernetes Secrets',
                      env_file: '.env File Import',
                    };
                    return (
                      <button key={type} onClick={() => setSelectedType(type)} className="flex items-center gap-4 p-4 border rounded-lg hover:bg-gray-50 text-left">
                        <div className="w-10 h-10 bg-primary-50 rounded-lg flex items-center justify-center">
                          <Icon size={20} className="text-primary-600" />
                        </div>
                        <div>
                          <div className="font-medium">{labels[type] || type}</div>
                          <div className="text-xs text-gray-500">{type.replace(/_/g, ' ')}</div>
                        </div>
                      </button>
                    );
                  })}
                </div>
              ) : (
                <>
                  <button onClick={() => setSelectedType('')} className="text-sm text-primary-600 hover:underline">&larr; Back to provider selection</button>
                  <div>
                    <label className="block text-sm font-medium mb-1">Provider Name *</label>
                    <input value={providerName} onChange={e => setProviderName(e.target.value)} className="w-full border rounded-lg px-3 py-2" placeholder="My AWS Secrets" />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-1">Description</label>
                    <input value={providerDesc} onChange={e => setProviderDesc(e.target.value)} className="w-full border rounded-lg px-3 py-2" placeholder="Production secrets from AWS" />
                  </div>

                  {CONFIG_FIELDS[selectedType]?.map(field => (
                    <div key={field.key}>
                      <label className="block text-sm font-medium mb-1">{field.label} {field.required && '*'}</label>
                      {field.type === 'textarea' ? (
                        <textarea value={formData[field.key] || ''} onChange={e => setFormData(prev => ({ ...prev, [field.key]: e.target.value }))} className="w-full border rounded-lg px-3 py-2 font-mono text-sm" rows={6} placeholder={field.placeholder} />
                      ) : field.type === 'select' ? (
                        <select value={formData[field.key] || ''} onChange={e => setFormData(prev => ({ ...prev, [field.key]: e.target.value }))} className="w-full border rounded-lg px-3 py-2">
                          <option value="token">Token</option>
                          <option value="approle">AppRole</option>
                        </select>
                      ) : (
                        <input type={field.type || 'text'} value={formData[field.key] || ''} onChange={e => setFormData(prev => ({ ...prev, [field.key]: e.target.value }))} className="w-full border rounded-lg px-3 py-2" placeholder={field.placeholder} />
                      )}
                    </div>
                  ))}

                  <div>
                    <label className="block text-sm font-medium mb-1">Sync Direction</label>
                    <select value={syncDirection} onChange={e => setSyncDirection(e.target.value)} className="w-full border rounded-lg px-3 py-2">
                      <option value="import">Import (external → vault)</option>
                      <option value="export">Export (vault → external)</option>
                      <option value="bidirectional">Bidirectional</option>
                    </select>
                  </div>
                </>
              )}
            </div>
            <div className="p-6 border-t flex justify-between">
              <button onClick={() => { setShowCreateModal(false); resetForm(); }} className="px-4 py-2 border rounded-lg">Cancel</button>
              {selectedType && (
                <div className="flex gap-2">
                  <button onClick={handleTestConnection} disabled={isTesting} className="flex items-center gap-2 px-4 py-2 border rounded-lg hover:bg-gray-50 disabled:opacity-50">
                    {isTesting ? <Loader2 size={14} className="animate-spin" /> : <CheckCircle size={14} />}
                    Test Connection
                  </button>
                  <button onClick={handleCreateProvider} disabled={isSaving || !providerName} className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg disabled:opacity-50">
                    {isSaving ? <Loader2 size={14} className="animate-spin" /> : <Plus size={14} />}
                    Connect
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Import .env Modal */}
      {showImportModal && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-xl w-full max-w-lg">
            <div className="p-6 border-b">
              <h2 className="text-lg font-semibold">Import from .env</h2>
            </div>
            <div className="p-6">
              <p className="text-sm text-gray-500 mb-3">Paste your .env file contents below. Each KEY=VALUE pair will be imported as a secret.</p>
              <textarea value={envContent} onChange={e => setEnvContent(e.target.value)} className="w-full border rounded-lg px-3 py-2 font-mono text-sm" rows={12} placeholder="DATABASE_URL=postgres://...&#10;API_KEY=sk_live_...&#10;SECRET_TOKEN=abc123" />
            </div>
            <div className="p-6 border-t flex justify-end gap-2">
              <button onClick={() => { setShowImportModal(false); setEnvContent(''); }} className="px-4 py-2 border rounded-lg">Cancel</button>
              <button onClick={handleImportEnv} disabled={!envContent.trim()} className="px-4 py-2 bg-primary-600 text-white rounded-lg disabled:opacity-50">Import Secrets</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
