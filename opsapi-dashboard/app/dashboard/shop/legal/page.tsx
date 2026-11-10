'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { BadgeCheck, Info, ScrollText, Search, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Modal, Pagination, Table, confirmDialog, promptDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { FilterSelect, KeyValue, SHOP_MODULE } from '@/components/shop/shared';
import { shopLegalService } from '@/services/shop-legal.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import { SHOP_LEGAL_CHECKPOINTS, type ShopLegalAcceptance, type ShopLegalCheckpoint, type TableColumn } from '@/types';

const PER_PAGE = 25;

// The shop's documents (workstation-website shop/src/lib/legal). Unknown keys still show, as written.
const DOCUMENTS: Record<string, string> = {
  'terms-of-sale': 'Terms of Sale',
  'trade-terms': 'Trade terms',
  'privacy-notice': 'Privacy notice',
  'ai-assistant': 'AI assistant notice',
  'important-information': 'Important information',
};

const WHERE: Record<ShopLegalCheckpoint, string> = {
  register: 'Signing in',
  quote: 'Quote request',
  checkout: 'Checkout',
  trade_join: 'Joining Trade',
  chat: 'AI chat',
  enquiry: 'Enquiry or waitlist',
  contact: 'Website contact form',
};

const docName = (key: string) => DOCUMENTS[key] ?? key;
const looksLikeEmail = (v: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.trim());

function EmailBadge({ confirmed }: { confirmed: boolean }) {
  return confirmed ? (
    <Badge size="sm" variant="success">Signed in</Badge>
  ) : (
    <Badge size="sm" variant="secondary">Typed</Badge>
  );
}

function LegalContent() {
  const { canDelete } = usePermissions();
  const mayErase = canDelete(SHOP_MODULE);
  const [rows, setRows] = useState<ShopLegalAcceptance[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [doc, setDoc] = useState('');
  const [checkpoint, setCheckpoint] = useState<ShopLegalCheckpoint | ''>('');
  const [page, setPage] = useState(1);
  const [version, setVersion] = useState(0);
  const [open, setOpen] = useState<ShopLegalAcceptance | null>(null);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopLegalService
      .list({ q, document_key: doc, checkpoint, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Could not load the legal record')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [q, doc, checkpoint, page, version]);

  const erase = useCallback(async (preset?: string) => {
    const email = preset ?? (await promptDialog({
      title: 'Erase a person’s legal records',
      message: 'Type the email address exactly as the person gave it. Every record for that address in this workspace will be deleted.',
      label: 'Email address',
      inputType: 'email',
      placeholder: 'name@example.com',
      confirmText: 'Continue',
      validate: (v) => (looksLikeEmail(v) ? null : 'Enter a full email address'),
    }));
    if (!email) return;
    const ok = await confirmDialog({
      title: `Erase every legal record for ${email.trim()}?`,
      message: (
        <div className="space-y-2">
          <p>Do this only for a genuine request from that person to delete their data.</p>
          <p>These records are your proof of what they agreed to. If you might need that proof (an open order, a dispute), keep them and tell the person why.</p>
          <p className="font-medium">This can’t be undone.</p>
        </div>
      ),
      confirmText: 'Erase records',
      danger: true,
    });
    if (!ok) return;
    try {
      const res = await shopLegalService.erase(email.trim());
      toast.success(res.erased === 0 ? 'There were no records for that address' : `Erased ${res.erased} record${res.erased === 1 ? '' : 's'}`);
      setOpen(null);
      setVersion((v) => v + 1);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not erase the records'));
    }
  }, []);

  const columns: TableColumn<ShopLegalAcceptance>[] = [
    { key: 'created_at', header: 'When', render: (r) => <span className="whitespace-nowrap text-sm text-secondary-600">{formatDateTime(r.created_at)}</span> },
    {
      key: 'email',
      header: 'Email',
      render: (r) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">{r.email}</p>
          <EmailBadge confirmed={r.email_confirmed} />
        </div>
      ),
    },
    {
      key: 'document_key',
      header: 'Document',
      render: (r) => (
        <div>
          <p className="text-secondary-900">{docName(r.document_key)}</p>
          <p className="text-xs text-secondary-500">Version {r.document_version}</p>
        </div>
      ),
    },
    { key: 'checkpoint', header: 'Where', render: (r) => <span className="text-sm text-secondary-700">{WHERE[r.checkpoint] ?? r.checkpoint}</span> },
    {
      key: 'statement',
      header: 'What they ticked',
      render: (r) => <p className="line-clamp-2 max-w-md text-sm text-secondary-700">{r.statement}</p>,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Legal record"
        description="Every statement customers ticked in the shop: which document and version, where, and when. Records can’t be changed."
        icon={<ScrollText className="h-5 w-5" />}
        actions={
          mayErase ? (
            <Button variant="outline" onClick={() => erase()} leftIcon={<Trash2 className="h-4 w-4" />}>
              Erase a person’s records
            </Button>
          ) : undefined
        }
      />

      <Card padding="md" className="flex gap-3 text-sm text-secondary-700">
        <Info className="mt-0.5 h-4 w-4 shrink-0 text-secondary-500" aria-hidden="true" />
        <div className="space-y-1">
          <p>
            <Badge size="sm" variant="success">Signed in</Badge> The person was signed in, so the email is theirs. Only these count as
            them having agreed: the shop asks again until they have.
          </p>
          <p>
            <Badge size="sm" variant="secondary">Typed</Badge> The email was typed into a form (a quote, chat, checkout or the contact
            form). It shows what was ticked, but anyone could have typed that address.
          </p>
        </div>
      </Card>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input
              placeholder="Search by email"
              aria-label="Search by email"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              leftIcon={<Search className="h-4 w-4" />}
            />
          </div>
          <FilterSelect
            aria-label="Document"
            value={doc}
            onChange={(e) => {
              setDoc(e.target.value);
              setPage(1);
            }}
          >
            <option value="">All documents</option>
            {Object.entries(DOCUMENTS).map(([k, label]) => (
              <option key={k} value={k}>{label}</option>
            ))}
          </FilterSelect>
          <FilterSelect
            aria-label="Where"
            value={checkpoint}
            onChange={(e) => {
              setCheckpoint(e.target.value as ShopLegalCheckpoint | '');
              setPage(1);
            }}
          >
            <option value="">Everywhere</option>
            {SHOP_LEGAL_CHECKPOINTS.map((c) => (
              <option key={c} value={c}>{WHERE[c]}</option>
            ))}
          </FilterSelect>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(r) => r.uuid}
          onRowClick={(r) => setOpen(r)}
          isLoading={loading}
          emptyMessage={q || doc || checkpoint ? 'Nothing matches these filters' : 'No one has ticked anything yet'}
          caption="Legal record"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <Modal
        isOpen={!!open}
        onClose={() => setOpen(null)}
        title={open ? docName(open.document_key) : ''}
        description={open ? `Version ${open.document_version} · ${formatDateTime(open.created_at)}` : undefined}
        size="lg"
        footer={
          open ? (
            <div className="flex w-full flex-wrap justify-between gap-2">
              {mayErase ? (
                <Button variant="ghost" onClick={() => erase(open.email)} leftIcon={<Trash2 className="h-4 w-4" />}>
                  Erase everything for this email
                </Button>
              ) : <span />}
              <Button variant="secondary" onClick={() => setOpen(null)}>Close</Button>
            </div>
          ) : undefined
        }
      >
        {open && (
          <div className="space-y-4">
            <div className="rounded-lg bg-secondary-50 p-3">
              <p className="text-xs font-medium text-secondary-500">What they ticked</p>
              <p className="mt-1 whitespace-pre-wrap text-sm text-secondary-900">{open.statement}</p>
            </div>
            <dl className="divide-y divide-secondary-100">
              <KeyValue label="Email">
                <span className="break-all">{open.email}</span>{' '}
                {open.email_confirmed ? (
                  <span className="inline-flex items-center gap-1 text-xs text-success-700"><BadgeCheck className="h-3.5 w-3.5" aria-hidden="true" />signed in</span>
                ) : (
                  <span className="text-xs text-secondary-500">typed into a form</span>
                )}
              </KeyValue>
              <KeyValue label="Where">{WHERE[open.checkpoint] ?? open.checkpoint}</KeyValue>
              <KeyValue label="For">{open.subject_ref || '—'}</KeyValue>
              <KeyValue label="IP address">{open.client_ip || '—'}</KeyValue>
              <KeyValue label="Browser"><span className="break-words text-xs">{open.user_agent || '—'}</span></KeyValue>
              <KeyValue label="Document fingerprint">
                <span className="break-all font-mono text-xs" title="SHA-256 of the document text they saw">{open.content_hash || '—'}</span>
              </KeyValue>
            </dl>
          </div>
        )}
      </Modal>
    </div>
  );
}

export default function ShopLegalPage() {
  return (
    <ProtectedPage module={SHOP_MODULE} title="Legal record">
      <LegalContent />
    </ProtectedPage>
  );
}
