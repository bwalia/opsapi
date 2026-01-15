'use client';

import React, { useState, useCallback } from 'react';
import { Lock, Key, Eye, EyeOff, AlertTriangle } from 'lucide-react';
import { Button, Input, Card } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import toast from 'react-hot-toast';

interface VaultUnlockProps {
  onSuccess: () => void;
  failedAttempts?: number;
}

const VaultUnlock: React.FC<VaultUnlockProps> = ({ onSuccess, failedAttempts = 0 }) => {
  const [vaultKey, setVaultKey] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [isUnlocking, setIsUnlocking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleUnlock = useCallback(async () => {
    if (!vaultKey) {
      setError('Please enter your vault key');
      return;
    }

    if (vaultKey.length !== 16) {
      setError('Vault key must be exactly 16 characters');
      return;
    }

    setIsUnlocking(true);
    setError(null);

    try {
      await vaultService.unlockVault(vaultKey);
      toast.success('Vault unlocked successfully!');
      onSuccess();
    } catch (err) {
      const error = err as Error;
      setError(error.message || 'Invalid vault key');
      setVaultKey('');
    } finally {
      setIsUnlocking(false);
    }
  }, [vaultKey, onSuccess]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      handleUnlock();
    }
  };

  const remainingAttempts = 5 - failedAttempts;
  const isLocked = remainingAttempts <= 0;

  if (isLocked) {
    return (
      <div className="max-w-md mx-auto">
        <Card className="p-8">
          <div className="text-center">
            <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-error-100 mb-4">
              <AlertTriangle className="w-8 h-8 text-error-600" />
            </div>
            <h2 className="text-xl font-bold text-secondary-900 mb-2">Vault Locked</h2>
            <p className="text-secondary-600 mb-4">
              Your vault has been temporarily locked due to too many failed attempts.
              Please contact support or try again later.
            </p>
          </div>
        </Card>
      </div>
    );
  }

  return (
    <div className="max-w-md mx-auto">
      <Card className="p-8">
        <div className="text-center mb-6">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-primary-100 mb-4">
            <Lock className="w-8 h-8 text-primary-600" />
          </div>
          <h2 className="text-xl font-bold text-secondary-900 mb-2">Unlock Your Vault</h2>
          <p className="text-secondary-600">
            Enter your 16-character vault key to access your secrets
          </p>
        </div>

        <div className="space-y-4">
          <Input
            label="Vault Key"
            type={showKey ? 'text' : 'password'}
            value={vaultKey}
            onChange={(e) => {
              setVaultKey(e.target.value);
              setError(null);
            }}
            onKeyDown={handleKeyDown}
            placeholder="Enter your 16-character key"
            maxLength={16}
            error={error || undefined}
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

          {failedAttempts > 0 && (
            <div className="p-3 bg-warning-50 rounded-lg border border-warning-200">
              <div className="flex items-center gap-2 text-warning-700">
                <AlertTriangle className="w-4 h-4 flex-shrink-0" />
                <p className="text-sm">
                  {remainingAttempts} attempt{remainingAttempts !== 1 ? 's' : ''} remaining before lockout
                </p>
              </div>
            </div>
          )}

          <Button
            onClick={handleUnlock}
            isLoading={isUnlocking}
            className="w-full"
            disabled={vaultKey.length !== 16}
          >
            <Key className="w-4 h-4 mr-2" />
            Unlock Vault
          </Button>
        </div>

        <p className="mt-4 text-xs text-center text-secondary-500">
          Your vault key is never stored on our servers. If you&apos;ve forgotten it,
          your secrets cannot be recovered.
        </p>
      </Card>
    </div>
  );
};

export default VaultUnlock;
