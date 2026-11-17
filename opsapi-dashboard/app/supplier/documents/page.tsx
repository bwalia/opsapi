'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Download, FileText } from 'lucide-react';
import toast from 'react-hot-toast';
import { btnSmall, fmtDateTime, fmtSize, inputClass } from '@/components/supplier-portal/shared';
import { useSupplierMe } from '@/components/supplier-portal/SupplierPortalContext';
import {
  DOC_TYPE_LABELS,
  openDownload,
  portalError,
  supplierPortalService,
  type PortalDocType,
  type PortalDocument,
} from '@/services/supplier-portal.service';

export default function SupplierDocumentsPage() {
  const me = useSupplierMe();
  const [docType, setDocType] = useState<PortalDocType | ''>('');
  const [docs, setDocs] = useState<PortalDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setDocs(await supplierPortalService.documents(docType || undefined));
      setError(null);
    } catch (err) {
      setError(portalError(err, 'Documents could not be loaded').message);
    } finally {
      setLoading(false);
    }
  }, [docType]);

  useEffect(() => {
    void load();
  }, [load]);

  const download = async (id: string) => {
    try {
      openDownload(await supplierPortalService.documentLink(id));
    } catch (err) {
      toast.error(portalError(err, 'The download could not be started').message);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-xl font-semibold text-secondary-900">Documents</h1>
          <p className="text-sm text-secondary-500">Every document on your purchase orders, newest first.</p>
        </div>
        <select
          className={`${inputClass} sm:w-60`}
          value={docType}
          aria-label="Show"
          onChange={(e) => setDocType(e.target.value as PortalDocType | '')}
        >
          <option value="">All documents</option>
          {(Object.keys(DOC_TYPE_LABELS) as PortalDocType[]).map((t) => (
            <option key={t} value={t}>
              {DOC_TYPE_LABELS[t]}
            </option>
          ))}
        </select>
      </div>

      {error && <p className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</p>}

      <div className="rounded-xl border border-secondary-200 bg-surface shadow-sm">
        {loading ? (
          <div className="space-y-2 p-4">
            {[0, 1, 2].map((i) => (
              <div key={i} className="h-12 animate-pulse rounded bg-secondary-100" />
            ))}
          </div>
        ) : docs.length === 0 ? (
          <p className="p-6 text-center text-sm text-secondary-500">No documents yet.</p>
        ) : (
          <ul className="divide-y divide-secondary-100 text-sm">
            {docs.map((d) => (
              <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
                <div className="flex min-w-0 items-start gap-2">
                  <FileText className="mt-0.5 h-4 w-4 shrink-0 text-secondary-400" />
                  <div className="min-w-0">
                    <p className="truncate font-medium text-secondary-900">{d.filename}</p>
                    <p className="text-xs text-secondary-500">
                      {d.label}
                      {d.po_id && (
                        <>
                          {' · '}
                          <Link href={`/supplier/purchase-orders/${d.po_id}`} className="text-primary-700 hover:underline">
                            {d.po_number}
                          </Link>
                        </>
                      )}
                      {' · '}
                      {d.uploaded_by || (d.uploaded_by_kind === 'staff' ? me?.buyer.name : 'You')} · {fmtDateTime(d.created_at)}
                      {d.size ? ` · ${fmtSize(d.size)}` : ''}
                    </p>
                  </div>
                </div>
                <button type="button" className={btnSmall} onClick={() => download(d.id)}>
                  <Download className="h-3.5 w-3.5" />
                  Download
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
