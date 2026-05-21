'use client';

import React, { useEffect, useRef } from 'react';
import { cn } from '@/lib/utils';
import { X, AlertTriangle, AlertCircle, Info } from 'lucide-react';
import Button from './Button';
import type { ConfirmDialogProps } from '@/types';

export interface ModalProps {
  isOpen: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
  size?: 'sm' | 'md' | 'lg' | 'xl' | '2xl';
  showClose?: boolean;
}

const Modal: React.FC<ModalProps> = ({
  isOpen,
  onClose,
  title,
  children,
  size = 'md',
  showClose = true,
}) => {
  const modalRef = useRef<HTMLDivElement>(null);
  const titleId = title ? `modal-title-${title.replace(/\s+/g, '-').toLowerCase()}` : undefined;

  // Keep a stable ref to the latest onClose so the Escape listener never needs
  // onClose in its dependency array. Callers commonly pass an inline arrow
  // (new identity each render); without this, the effect below would re-run on
  // every parent render and the focus() call would steal focus out of inputs
  // mid-typing.
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  // Focus the modal ONLY when it transitions open — depends on isOpen alone,
  // so re-renders while open (e.g. typing in a field) don't re-trigger focus.
  useEffect(() => {
    if (isOpen) {
      modalRef.current?.focus();
    }
  }, [isOpen]);

  // Escape-to-close + body scroll lock. Keyed on isOpen only; uses onCloseRef
  // so a changing onClose identity doesn't re-subscribe the listener.
  useEffect(() => {
    if (!isOpen) return;

    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onCloseRef.current();
    };
    document.addEventListener('keydown', handleEscape);
    document.body.style.overflow = 'hidden';

    return () => {
      document.removeEventListener('keydown', handleEscape);
      document.body.style.overflow = '';
    };
  }, [isOpen]);

  if (!isOpen) return null;

  const sizes = {
    sm: 'max-w-sm',
    md: 'max-w-md',
    lg: 'max-w-lg',
    xl: 'max-w-2xl',
    '2xl': 'max-w-3xl',
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto"
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
    >
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-secondary-900/50 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Modal Content */}
      <div
        ref={modalRef}
        tabIndex={-1}
        className={cn(
          'relative w-full bg-surface-elevated rounded-2xl shadow-2xl my-8 max-h-[90vh] flex flex-col',
          sizes[size]
        )}
      >
        {/* Header */}
        {(title || showClose) && (
          <div className="flex items-center justify-between px-6 py-4 border-b border-secondary-200 flex-shrink-0">
            {title && (
              <h2 id={titleId} className="text-lg font-semibold text-secondary-900">{title}</h2>
            )}
            {showClose && (
              <button
                onClick={onClose}
                className="p-2 text-secondary-400 hover:text-secondary-600 hover:bg-secondary-100 rounded-lg transition-colors min-w-[40px] min-h-[40px] flex items-center justify-center"
                aria-label="Close dialog"
              >
                <X className="w-5 h-5" />
              </button>
            )}
          </div>
        )}

        {/* Body - Scrollable */}
        <div className="p-6 overflow-y-auto flex-1">{children}</div>
      </div>
    </div>
  );
};

export const ConfirmDialog: React.FC<ConfirmDialogProps> = ({
  isOpen,
  onClose,
  onConfirm,
  title,
  message,
  confirmText = 'Confirm',
  cancelText = 'Cancel',
  variant = 'danger',
  isLoading = false,
}) => {
  const icons = {
    danger: <AlertTriangle className="w-12 h-12 text-error-500" aria-hidden="true" />,
    warning: <AlertCircle className="w-12 h-12 text-warning-500" aria-hidden="true" />,
    info: <Info className="w-12 h-12 text-info-500" aria-hidden="true" />,
  };

  const buttonVariants = {
    danger: 'danger' as const,
    warning: 'primary' as const,
    info: 'primary' as const,
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} size="sm" showClose={false}>
      <div className="text-center" role="alertdialog" aria-describedby="confirm-message">
        <div className="flex justify-center mb-4">{icons[variant]}</div>
        <h3 className="text-lg font-semibold text-secondary-900 mb-2">{title}</h3>
        <p id="confirm-message" className="text-secondary-600 mb-6">{message}</p>
        <div className="flex gap-3 justify-center">
          <Button variant="ghost" onClick={onClose} disabled={isLoading}>
            {cancelText}
          </Button>
          <Button
            variant={buttonVariants[variant]}
            onClick={onConfirm}
            isLoading={isLoading}
          >
            {confirmText}
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default Modal;
