'use client';

/**
 * One bank-statement upload control for every tax screen (Statements, Bank
 * accounts, the chat agent): PDF + CSV (+ images where allowed), several files
 * at once, drag & drop, and a per-file status row.
 *
 * The parent owns the queue (useStatementQueue) and the actual upload, so each
 * screen keeps its own flow (detect → pick account → upload, or upload → process)
 * while the control, validation and status rows look the same everywhere.
 */

import React, { useCallback, useRef, useState } from 'react';
import { AlertCircle, CheckCircle, FileText, Loader2, Paperclip, Upload, X } from 'lucide-react';
import { cn } from '@/lib/utils';

export const MAX_STATEMENT_BYTES = 25 * 1024 * 1024;
const DOC_EXTENSIONS = ['pdf', 'csv'];
const IMAGE_EXTENSIONS = ['jpg', 'jpeg', 'png', 'gif', 'webp'];

export type StatementItemStatus = 'queued' | 'detecting' | 'ready' | 'uploading' | 'done' | 'error';

export interface StatementItem {
  id: string;
  file: File;
  status: StatementItemStatus;
  /** Short result / error line shown under the file name. */
  message?: string;
}

export function statementAccept(allowImages = true): string {
  const exts = allowImages ? [...DOC_EXTENSIONS, ...IMAGE_EXTENSIONS] : DOC_EXTENSIONS;
  return exts.map((e) => `.${e}`).join(',');
}

function extensionOf(name: string): string {
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.slice(i + 1).toLowerCase() : '';
}

/** Why a file can't be uploaded as a statement, or null when it can. */
export function validateStatementFile(file: File, allowImages = true): string | null {
  const ext = extensionOf(file.name);
  const ok = DOC_EXTENSIONS.includes(ext) || (allowImages && IMAGE_EXTENSIONS.includes(ext));
  if (!ok) return allowImages ? 'Use a PDF, CSV or image (JPG, PNG, GIF, WebP)' : 'Use a PDF or CSV file';
  if (file.size === 0) return 'The file is empty';
  if (file.size > MAX_STATEMENT_BYTES) return 'The file is larger than 25MB';
  return null;
}

let seq = 0;
const nextId = () => `stmt_${Date.now()}_${seq++}`;

/** Queue state for StatementUploader. `add` validates and returns the accepted items. */
export function useStatementQueue(opts: { allowImages?: boolean; multiple?: boolean } = {}) {
  const { allowImages = true, multiple = true } = opts;
  const [items, setItems] = useState<StatementItem[]>([]);

  const add = useCallback(
    (files: File[]): StatementItem[] => {
      const picked = multiple ? files : files.slice(0, 1);
      const created = picked.map((file): StatementItem => {
        const problem = validateStatementFile(file, allowImages);
        return problem
          ? { id: nextId(), file, status: 'error', message: problem }
          : { id: nextId(), file, status: 'queued' };
      });
      setItems((prev) => (multiple ? [...prev, ...created] : created));
      return created.filter((i) => i.status !== 'error');
    },
    [allowImages, multiple],
  );

  const update = useCallback((id: string, patch: Partial<Omit<StatementItem, 'id' | 'file'>>) => {
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...patch } : i)));
  }, []);

  const remove = useCallback((id: string) => {
    setItems((prev) => prev.filter((i) => i.id !== id));
  }, []);

  const clear = useCallback(() => setItems([]), []);

  return { items, add, update, remove, clear };
}

const STATUS_STYLE: Record<StatementItemStatus, { label: string; classes: string }> = {
  queued: { label: 'Ready', classes: 'text-secondary-500' },
  detecting: { label: 'Reading bank details…', classes: 'text-primary-600' },
  ready: { label: 'Ready', classes: 'text-secondary-600' },
  uploading: { label: 'Uploading…', classes: 'text-primary-600' },
  done: { label: 'Uploaded', classes: 'text-green-700' },
  error: { label: 'Failed', classes: 'text-red-600' },
};

function StatusIcon({ status }: { status: StatementItemStatus }) {
  if (status === 'detecting' || status === 'uploading') {
    return <Loader2 className="h-4 w-4 shrink-0 animate-spin text-primary-600" />;
  }
  if (status === 'done') return <CheckCircle className="h-4 w-4 shrink-0 text-green-600" />;
  if (status === 'error') return <AlertCircle className="h-4 w-4 shrink-0 text-red-500" />;
  return <FileText className="h-4 w-4 shrink-0 text-secondary-400" />;
}

export interface StatementUploadListProps {
  items: StatementItem[];
  onRemove?: (id: string) => void;
  /** Extra per-file content (e.g. the detected account and an account picker). */
  renderExtra?: (item: StatementItem) => React.ReactNode;
  className?: string;
}

/** Per-file status rows. Rendered by StatementUploader; usable on its own (chat). */
export function StatementUploadList({ items, onRemove, renderExtra, className }: StatementUploadListProps) {
  if (items.length === 0) return null;
  return (
    <ul className={cn('divide-y divide-secondary-100 rounded-lg border border-secondary-200', className)} data-testid="statement-upload-list">
      {items.map((item) => {
        const style = STATUS_STYLE[item.status];
        const busy = item.status === 'detecting' || item.status === 'uploading';
        return (
          <li key={item.id} className="px-3 py-2 text-sm" data-status={item.status}>
            <div className="flex items-start gap-2">
              <StatusIcon status={item.status} />
              <div className="min-w-0 flex-1">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate font-medium text-secondary-900" title={item.file.name}>
                    {item.file.name}
                  </span>
                  <span className="shrink-0 text-xs text-secondary-400">{(item.file.size / 1024).toFixed(1)} KB</span>
                </div>
                <p className={cn('text-xs', style.classes)}>{item.message || style.label}</p>
                {renderExtra && item.status !== 'error' && <div className="mt-1.5">{renderExtra(item)}</div>}
              </div>
              {onRemove && !busy && item.status !== 'done' && (
                <button
                  type="button"
                  onClick={() => onRemove(item.id)}
                  className="rounded p-0.5 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600"
                  aria-label={`Remove ${item.file.name}`}
                >
                  <X className="h-4 w-4" />
                </button>
              )}
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export interface StatementUploaderProps {
  items: StatementItem[];
  /** Called with the picked/dropped files (validate + queue them with useStatementQueue().add). */
  onFiles: (files: File[]) => void;
  onRemove?: (id: string) => void;
  renderExtra?: (item: StatementItem) => React.ReactNode;
  multiple?: boolean;
  allowImages?: boolean;
  disabled?: boolean;
  /** 'dropzone' (default) or 'compact' — a paperclip button only (the list is rendered separately). */
  variant?: 'dropzone' | 'compact';
  title?: string;
  className?: string;
  /** Exposes the file input so other buttons (e.g. a chat prompt) can open the picker. */
  inputRef?: React.RefObject<HTMLInputElement | null>;
}

export default function StatementUploader({
  items,
  onFiles,
  onRemove,
  renderExtra,
  multiple = true,
  allowImages = true,
  disabled = false,
  variant = 'dropzone',
  title,
  className,
  inputRef: externalRef,
}: StatementUploaderProps) {
  const ownRef = useRef<HTMLInputElement>(null);
  const inputRef = externalRef ?? ownRef;
  const [dragging, setDragging] = useState(false);

  const take = (list: FileList | null) => {
    const files = list ? Array.from(list) : [];
    if (files.length > 0) onFiles(multiple ? files : files.slice(0, 1));
  };

  const input = (
    <input
      ref={inputRef}
      type="file"
      accept={statementAccept(allowImages)}
      multiple={multiple}
      className="hidden"
      disabled={disabled}
      data-testid="statement-file-input"
      onChange={(e) => {
        take(e.target.files);
        e.target.value = '';
      }}
    />
  );

  const kinds = allowImages ? 'PDF, CSV or images (JPG, PNG, GIF, WebP)' : 'PDF or CSV';

  if (variant === 'compact') {
    return (
      <>
        <button
          type="button"
          onClick={() => inputRef.current?.click()}
          disabled={disabled}
          title={title || `Upload bank statements (${kinds})`}
          aria-label={title || 'Upload bank statements'}
          className={cn(
            'shrink-0 rounded-lg border border-secondary-300 px-3 py-2 text-secondary-600 hover:bg-secondary-50 disabled:opacity-50',
            className,
          )}
        >
          <Paperclip className="h-4 w-4" />
        </button>
        {input}
      </>
    );
  }

  return (
    <div className={cn('space-y-3', className)}>
      <div
        role="button"
        tabIndex={disabled ? -1 : 0}
        aria-disabled={disabled}
        onClick={() => !disabled && inputRef.current?.click()}
        onKeyDown={(e) => {
          if (!disabled && (e.key === 'Enter' || e.key === ' ')) {
            e.preventDefault();
            inputRef.current?.click();
          }
        }}
        onDragOver={(e) => {
          e.preventDefault();
          if (!disabled) setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          if (!disabled) take(e.dataTransfer.files);
        }}
        className={cn(
          'cursor-pointer rounded-lg border-2 border-dashed p-6 text-center transition-colors',
          dragging ? 'border-primary-500 bg-primary-50' : 'border-secondary-300 hover:border-primary-400',
          disabled && 'cursor-not-allowed opacity-60',
        )}
      >
        <Upload className="mx-auto mb-2 h-8 w-8 text-secondary-400" />
        <p className="text-secondary-700">
          {title || (multiple ? 'Drop statements here or click to choose' : 'Drop a statement here or click to choose')}
        </p>
        <p className="mt-1 text-xs text-secondary-400">
          {kinds} · max 25MB{multiple ? ' each · several files at once' : ''}
        </p>
      </div>
      {input}
      <StatementUploadList items={items} onRemove={onRemove} renderExtra={renderExtra} />
    </div>
  );
}
