'use client';

/**
 * Workspace → AI models — /dashboard/namespace/ai
 *
 * The workspace's own AI providers (core, used by the AI assistant and by plugins) and which one
 * drives the AI assistant. namespace.read sees them; namespace.update changes them.
 */
import React from 'react';
import Link from 'next/link';
import { ArrowLeft, Bot } from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import AiProviders from '@/components/ai/AiProviders';

function AiModels() {
  const canEdit = usePermissions().hasPermission('namespace', 'update');
  return (
    <div className="space-y-6">
      <Link href="/dashboard/namespace" className="inline-flex items-center text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="mr-1 h-4 w-4" /> My workspace
      </Link>
      <PageHeader
        title="AI models"
        description="Your own AI keys and local models. Switch on “Assistant” for the one that runs the AI assistant here; with none, it uses the server's default model."
        icon={<Bot className="h-5 w-5" />}
      />
      <AiProviders canEdit={canEdit} />
    </div>
  );
}

export default function NamespaceAiPage() {
  return (
    <ProtectedPage module="namespace" title="AI models">
      <AiModels />
    </ProtectedPage>
  );
}
