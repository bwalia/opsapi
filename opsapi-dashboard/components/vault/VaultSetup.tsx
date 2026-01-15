'use client';

import React, { useState, useCallback } from 'react';
import { Shield, Key, AlertTriangle, Check, Eye, EyeOff } from 'lucide-react';
import { Button, Input, Card } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import toast from 'react-hot-toast';

interface VaultSetupProps {
  onSuccess: () => void;
}

const VaultSetup: React.FC<VaultSetupProps> = ({ onSuccess }) => {
  const [step, setStep] = useState<'intro' | 'create'>('intro');
  const [vaultKey, setVaultKey] = useState('');
  const [confirmKey, setConfirmKey] = useState('');
  const [vaultName, setVaultName] = useState('My Vault');
  const [showKey, setShowKey] = useState(false);
  const [showConfirmKey, setShowConfirmKey] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [errors, setErrors] = useState<{ vaultKey?: string; confirmKey?: string }>({});

  const validateKey = useCallback((key: string): string | undefined => {
    if (!key) return 'Vault key is required';
    if (key.length !== 16) return 'Vault key must be exactly 16 characters';
    if (!/[a-zA-Z]/.test(key)) return 'Vault key must contain at least one letter';
    if (!/[0-9]/.test(key)) return 'Vault key must contain at least one number';
    return undefined;
  }, []);

  const handleCreate = useCallback(async () => {
    const newErrors: typeof errors = {};

    const keyError = validateKey(vaultKey);
    if (keyError) newErrors.vaultKey = keyError;

    if (vaultKey !== confirmKey) {
      newErrors.confirmKey = 'Keys do not match';
    }

    if (Object.keys(newErrors).length > 0) {
      setErrors(newErrors);
      return;
    }

    setIsCreating(true);
    try {
      await vaultService.createVault({
        vault_key: vaultKey,
        name: vaultName || 'My Vault',
      });
      toast.success('Vault created successfully!');
      onSuccess();
    } catch (error) {
      const err = error as Error;
      toast.error(err.message || 'Failed to create vault');
    } finally {
      setIsCreating(false);
    }
  }, [vaultKey, confirmKey, vaultName, validateKey, onSuccess]);

  if (step === 'intro') {
    return (
      <div className="max-w-2xl mx-auto">
        <Card className="p-8">
          <div className="text-center mb-8">
            <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-primary-100 mb-4">
              <Shield className="w-8 h-8 text-primary-600" />
            </div>
            <h2 className="text-2xl font-bold text-secondary-900 mb-2">
              Welcome to Secret Vault
            </h2>
            <p className="text-secondary-600">
              Store your secrets securely with end-to-end encryption
            </p>
          </div>

          <div className="space-y-4 mb-8">
            <div className="flex items-start gap-4 p-4 bg-secondary-50 rounded-lg">
              <Key className="w-5 h-5 text-primary-600 mt-0.5 flex-shrink-0" />
              <div>
                <h3 className="font-medium text-secondary-900">Your 16-Character Key</h3>
                <p className="text-sm text-secondary-600">
                  You&apos;ll create a unique 16-character key that only you know. This key encrypts
                  all your secrets.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 p-4 bg-secondary-50 rounded-lg">
              <Shield className="w-5 h-5 text-primary-600 mt-0.5 flex-shrink-0" />
              <div>
                <h3 className="font-medium text-secondary-900">Zero-Knowledge Encryption</h3>
                <p className="text-sm text-secondary-600">
                  Your vault key is never stored on our servers. Only you can decrypt your
                  secrets.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 p-4 bg-warning-50 rounded-lg border border-warning-200">
              <AlertTriangle className="w-5 h-5 text-warning-600 mt-0.5 flex-shrink-0" />
              <div>
                <h3 className="font-medium text-warning-800">Remember Your Key</h3>
                <p className="text-sm text-warning-700">
                  If you forget your vault key, your secrets cannot be recovered. There is no
                  password reset.
                </p>
              </div>
            </div>
          </div>

          <Button onClick={() => setStep('create')} className="w-full" size="lg">
            Create My Vault
          </Button>
        </Card>
      </div>
    );
  }

  return (
    <div className="max-w-lg mx-auto">
      <Card className="p-6">
        <div className="text-center mb-6">
          <div className="inline-flex items-center justify-center w-12 h-12 rounded-full bg-primary-100 mb-3">
            <Key className="w-6 h-6 text-primary-600" />
          </div>
          <h2 className="text-xl font-bold text-secondary-900">Create Your Vault Key</h2>
          <p className="text-sm text-secondary-600 mt-1">
            Choose a strong 16-character key that you&apos;ll remember
          </p>
        </div>

        <div className="space-y-4">
          <Input
            label="Vault Name (Optional)"
            value={vaultName}
            onChange={(e) => setVaultName(e.target.value)}
            placeholder="My Vault"
          />

          <div>
            <Input
              label="Vault Key (16 characters)"
              type={showKey ? 'text' : 'password'}
              value={vaultKey}
              onChange={(e) => {
                setVaultKey(e.target.value);
                setErrors((prev) => ({ ...prev, vaultKey: undefined }));
              }}
              placeholder="Enter your 16-character key"
              maxLength={16}
              error={errors.vaultKey}
              rightIcon={
                <button
                  type="button"
                  onClick={() => setShowKey(!showKey)}
                  className="focus:outline-none"
                >
                  {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                </button>
              }
            />
            <div className="mt-2 flex items-center gap-2">
              <div className="flex-1 h-1.5 bg-secondary-200 rounded-full overflow-hidden">
                <div
                  className={`h-full transition-all duration-300 ${
                    vaultKey.length === 16
                      ? 'bg-success-500'
                      : vaultKey.length >= 8
                        ? 'bg-warning-500'
                        : 'bg-error-500'
                  }`}
                  style={{ width: `${(vaultKey.length / 16) * 100}%` }}
                />
              </div>
              <span className="text-xs text-secondary-500">{vaultKey.length}/16</span>
            </div>
          </div>

          <Input
            label="Confirm Vault Key"
            type={showConfirmKey ? 'text' : 'password'}
            value={confirmKey}
            onChange={(e) => {
              setConfirmKey(e.target.value);
              setErrors((prev) => ({ ...prev, confirmKey: undefined }));
            }}
            placeholder="Confirm your vault key"
            maxLength={16}
            error={errors.confirmKey}
            rightIcon={
              <button
                type="button"
                onClick={() => setShowConfirmKey(!showConfirmKey)}
                className="focus:outline-none"
              >
                {showConfirmKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
              </button>
            }
          />

          {/* Key Requirements Checklist */}
          <div className="p-3 bg-secondary-50 rounded-lg space-y-2">
            <p className="text-xs font-medium text-secondary-700">Key Requirements:</p>
            <div className="space-y-1">
              {[
                { check: vaultKey.length === 16, text: 'Exactly 16 characters' },
                { check: /[a-zA-Z]/.test(vaultKey), text: 'Contains at least one letter' },
                { check: /[0-9]/.test(vaultKey), text: 'Contains at least one number' },
                { check: vaultKey === confirmKey && confirmKey.length > 0, text: 'Keys match' },
              ].map((item, i) => (
                <div key={i} className="flex items-center gap-2 text-xs">
                  {item.check ? (
                    <Check className="w-3.5 h-3.5 text-success-500" />
                  ) : (
                    <div className="w-3.5 h-3.5 rounded-full border border-secondary-300" />
                  )}
                  <span className={item.check ? 'text-success-700' : 'text-secondary-500'}>
                    {item.text}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className="flex gap-3 mt-6">
          <Button variant="ghost" onClick={() => setStep('intro')} className="flex-1">
            Back
          </Button>
          <Button
            onClick={handleCreate}
            isLoading={isCreating}
            className="flex-1"
            disabled={vaultKey.length !== 16 || vaultKey !== confirmKey}
          >
            Create Vault
          </Button>
        </div>
      </Card>
    </div>
  );
};

export default VaultSetup;
