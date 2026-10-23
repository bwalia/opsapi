'use client';

/**
 * Themed replacements for the browser's confirm(), prompt() and alert().
 *
 *   if (!(await confirmDialog({ title: 'Delete this list?', danger: true }))) return;
 *   const url = await promptDialog({ title: 'Link address', defaultValue: 'https://' });
 *   await alertDialog({ title: 'Upload failed', message: err.message });
 *
 * One <DialogHost /> (in DashboardLayout) shows them, one at a time.
 */

import React, { useEffect, useRef, useState } from 'react';
import { create } from 'zustand';
import { AlertTriangle, Info } from 'lucide-react';
import Modal from './Modal';
import Button from './Button';

type Base = {
  title: string;
  message?: React.ReactNode;
  confirmText?: string;
  cancelText?: string;
  /** Red confirm button for destructive actions. */
  danger?: boolean;
};

export type ConfirmOptions = Base;
export type AlertOptions = Omit<Base, 'cancelText' | 'danger'>;
export type PromptOptions = Base & {
  label?: string;
  defaultValue?: string;
  placeholder?: string;
  inputType?: 'text' | 'url' | 'email' | 'number';
  /** Return an error message to keep the dialog open, or nothing when the value is fine. */
  validate?: (value: string) => string | undefined | null;
};

type Request =
  | { kind: 'confirm'; opts: ConfirmOptions; resolve: (v: boolean) => void }
  | { kind: 'alert'; opts: AlertOptions; resolve: () => void }
  | { kind: 'prompt'; opts: PromptOptions; resolve: (v: string | null) => void };

const useDialogs = create<{ queue: Request[]; push: (r: Request) => void; shift: () => void }>((set) => ({
  queue: [],
  push: (r) => set((s) => ({ queue: [...s.queue, r] })),
  shift: () => set((s) => ({ queue: s.queue.slice(1) })),
}));

export const confirmDialog = (opts: ConfirmOptions) =>
  new Promise<boolean>((resolve) => useDialogs.getState().push({ kind: 'confirm', opts, resolve }));

export const promptDialog = (opts: PromptOptions) =>
  new Promise<string | null>((resolve) => useDialogs.getState().push({ kind: 'prompt', opts, resolve }));

export const alertDialog = (opts: AlertOptions) =>
  new Promise<void>((resolve) => useDialogs.getState().push({ kind: 'alert', opts, resolve }));

function PromptBody({
  opts,
  value,
  error,
  onChange,
  onSubmit,
}: {
  opts: PromptOptions;
  value: string;
  error: string | null;
  onChange: (v: string) => void;
  onSubmit: () => void;
}) {
  const ref = useRef<HTMLInputElement>(null);
  // After the Modal has focused itself (it does on open), put the cursor in the box.
  useEffect(() => {
    const t = window.setTimeout(() => {
      ref.current?.focus();
      ref.current?.select();
    }, 0);
    return () => window.clearTimeout(t);
  }, []);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit();
      }}
    >
      {opts.message && <div className="mb-3 text-sm text-secondary-600">{opts.message}</div>}
      <label className="block">
        {opts.label && <span className="text-sm font-medium text-secondary-800">{opts.label}</span>}
        <input
          ref={ref}
          type={opts.inputType || 'text'}
          value={value}
          placeholder={opts.placeholder}
          onChange={(e) => onChange(e.target.value)}
          aria-invalid={!!error}
          className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base text-secondary-900 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
        />
      </label>
      {error && (
        <p role="alert" className="mt-2 text-sm text-error-600">
          {error}
        </p>
      )}
    </form>
  );
}

/** Shows the queued dialogs. Mount once. */
export function DialogHost() {
  const current = useDialogs((s) => s.queue[0]);
  const shift = useDialogs((s) => s.shift);
  const [value, setValue] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [shownFor, setShownFor] = useState<Request | undefined>(undefined);
  const okRef = useRef<HTMLButtonElement>(null);

  // Escape answers only this dialog: caught before it reaches a window underneath (whose
  // Modal would otherwise close too).
  useEffect(() => {
    if (!current) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      e.stopPropagation();
      if (current.kind === 'confirm') current.resolve(false);
      else if (current.kind === 'alert') current.resolve();
      else current.resolve(null);
      shift();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [current, shift]);

  // Enter/Space answers a confirm or alert straight away (the Modal focuses itself on open).
  useEffect(() => {
    if (!current || current.kind === 'prompt') return;
    const t = window.setTimeout(() => okRef.current?.focus(), 0);
    return () => window.clearTimeout(t);
  }, [current]);

  // A new dialog: start from its default value.
  if (current !== shownFor) {
    setShownFor(current);
    setValue(current?.kind === 'prompt' ? (current.opts.defaultValue ?? '') : '');
    setError(null);
  }

  if (!current) return null;

  const close = (answer: 'ok' | 'cancel') => {
    if (current.kind === 'confirm') current.resolve(answer === 'ok');
    else if (current.kind === 'alert') current.resolve();
    else {
      if (answer === 'ok') {
        const problem = current.opts.validate?.(value);
        if (problem) {
          setError(problem);
          return;
        }
        current.resolve(value);
      } else current.resolve(null);
    }
    shift();
  };

  const { opts } = current;
  const danger = current.kind !== 'alert' && (opts as ConfirmOptions).danger;
  const cancelText = current.kind !== 'alert' ? ((opts as ConfirmOptions).cancelText ?? 'Cancel') : null;
  const confirmText = opts.confirmText ?? (current.kind === 'alert' ? 'OK' : current.kind === 'prompt' ? 'Save' : 'Continue');

  return (
    <Modal
      isOpen
      onClose={() => close('cancel')}
      title={opts.title}
      size="sm"
      footer={
        <>
          {cancelText && (
            <Button variant="ghost" onClick={() => close('cancel')}>
              {cancelText}
            </Button>
          )}
          <Button ref={okRef} variant={danger ? 'danger' : 'primary'} onClick={() => close('ok')}>
            {confirmText}
          </Button>
        </>
      }
    >
      {current.kind === 'prompt' ? (
        <PromptBody
          opts={current.opts}
          value={value}
          error={error}
          onChange={(v) => {
            setValue(v);
            setError(null);
          }}
          onSubmit={() => close('ok')}
        />
      ) : (
        opts.message && (
          <div className="flex items-start gap-3 text-sm text-secondary-700">
            {danger ? (
              <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-error-500" aria-hidden="true" />
            ) : (
              <Info className="mt-0.5 h-5 w-5 shrink-0 text-primary-500" aria-hidden="true" />
            )}
            <div className="min-w-0 whitespace-pre-line">{opts.message}</div>
          </div>
        )
      )}
    </Modal>
  );
}
