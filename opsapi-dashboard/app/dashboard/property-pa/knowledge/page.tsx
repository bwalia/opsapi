'use client';

/**
 * Property PA — Knowledge (HOW-IT-WORKS scene 6): the rules the PA follows. Managers teach company and team rules
 * and approve what agents or the PA propose; anyone keeps personal rules. Every change is a new version; the old
 * one is kept.
 */
import React, { useState } from 'react';
import { BookOpen, Check, X, GraduationCap } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Select, Textarea } from '@/components/ui';
import { ErrorNote, Spinner, Empty } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { paService } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';
import PaPage, { usePaCan } from '@/components/property-pa/PaPage';

type Scope = 'personal' | 'team' | 'company';

function Teach({ onDone, isManager }: { onDone: () => void; isManager: boolean }) {
  const [statement, setStatement] = useState('');
  const [title, setTitle] = useState('');
  const [scope, setScope] = useState<Scope>(isManager ? 'company' : 'personal');
  const canApprove = isManager || scope === 'personal'; // the route: managers for company/team rules
  const [triggers, setTriggers] = useState('');
  const [busy, setBusy] = useState(false);
  const submit = async (approve: boolean) => {
    setBusy(true);
    try {
      const k = await paService.teach({
        statement: statement.trim(), title: title.trim() || undefined, scope, approve,
        triggers: triggers.split(/[\s,]+/).map((t) => t.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_')).filter(Boolean),
      });
      toast.success(k.status === 'approved' ? 'Taught. The PA uses it from now on.' : 'Proposed. A manager will approve it.');
      setStatement('');
      setTitle('');
      setTriggers('');
      onDone();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Card className="space-y-3">
      <h3 className="flex items-center gap-2 font-semibold text-secondary-900"><GraduationCap className="h-5 w-5" /> Teach the PA a rule</h3>
      <Textarea label="The rule" rows={3} value={statement} onChange={(e) => setStatement(e.target.value)}
        placeholder="An agent's valuation is not the seller's minimum price. Treat it as their anchor." />
      <div className="grid gap-3 sm:grid-cols-3">
        <Input label="Short title (optional)" value={title} onChange={(e) => setTitle(e.target.value)} />
        <Select label="Who it applies to" value={scope} onChange={(e) => setScope(e.target.value as Scope)}>
          <option value="company">The company</option>
          <option value="team">My team</option>
          <option value="personal">Just me</option>
        </Select>
        <Input label="When it applies" value={triggers} onChange={(e) => setTriggers(e.target.value)} placeholder="valuation, price" />
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" disabled={!statement.trim()} isLoading={busy} onClick={() => submit(false)}>Propose</Button>
        {canApprove && <Button disabled={!statement.trim()} isLoading={busy} onClick={() => submit(true)}>Teach now</Button>}
      </div>
      <p className="text-xs text-secondary-400">&quot;Teach now&quot; approves it straight away: managers for company and team rules, anyone for their own.</p>
    </Card>
  );
}

export default function KnowledgePage() {
  return (
    <PaPage module="property_pa_knowledge">
      <Knowledge />
    </PaPage>
  );
}

function Knowledge() {
  const { can, isManager } = usePaCan();
  const rules = usePdData(() => paService.knowledge(), []);
  const pending = usePdData(() => paService.pendingKnowledge(), []);
  const refresh = () => { rules.refresh(); pending.refresh(); };
  const decide = async (id: string, version: number, approve: boolean) => {
    try {
      await paService.decideKnowledge(id, version, approve);
      toast.success(approve ? 'Approved' : 'Rejected');
      refresh();
    } catch (e) {
      toast.error(pdErrorText(e));
    }
  };
  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <PageHeader title="PA knowledge" description="The rules your PA follows. Versioned and approved." icon={<BookOpen className="h-6 w-6" />} />
      {can('property_pa_knowledge', 'create') && <Teach onDone={refresh} isManager={isManager} />}
      <ErrorNote product="Property PA" error={pending.error} />
      {!!pending.data?.length && (
        <Card className="space-y-3">
          <h3 className="font-semibold text-secondary-900">Waiting for approval</h3>
          {pending.data.map((p) => (
            <div key={`${p.uuid}-${p.version}`} className="flex flex-wrap items-start justify-between gap-2 border-t border-secondary-100 pt-3">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-secondary-900">{p.title} <span className="text-xs text-secondary-400">v{p.version} · {p.scope}</span>
                  {p.proposed_by_ai && <Badge size="sm" variant="info" className="ml-2">from the PA</Badge>}</p>
                <p className="text-sm text-secondary-700">{p.rule}</p>
              </div>
              {(isManager || p.scope === 'personal') && (
                <div className="flex gap-1">
                  <Button size="sm" leftIcon={<Check className="h-4 w-4" />} onClick={() => decide(p.uuid, p.version, true)}>Approve</Button>
                  <Button size="sm" variant="ghost" leftIcon={<X className="h-4 w-4" />} onClick={() => decide(p.uuid, p.version, false)}>Reject</Button>
                </div>
              )}
            </div>
          ))}
        </Card>
      )}
      <ErrorNote product="Property PA" error={rules.error} />
      {rules.loading && !rules.data ? <Spinner /> : !rules.data?.length ? <Empty title="No rules yet" /> : (
        <Card className="space-y-3">
          <h3 className="font-semibold text-secondary-900">In use</h3>
          {rules.data.map((k) => (
            <div key={k.uuid} className="border-t border-secondary-100 pt-3">
              <p className="text-sm font-medium text-secondary-900">{k.title}
                <span className="ml-2 text-xs text-secondary-400">{k.scope} · v{k.current_version}{k.triggers?.length ? ` · ${k.triggers.join(', ')}` : ''}</span></p>
              <p className="text-sm text-secondary-700">{k.rule}</p>
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}
