'use client';

import toast from 'react-hot-toast';
import { confirmDialog } from '@/components/ui';

/** "Easy editor | HTML code" for an email body. */
export function EditorModeSwitch({ easy, onChange }: { easy: boolean; onChange: (easy: boolean) => void }) {
  return (
    <div
      className="inline-flex rounded-lg border border-secondary-200 p-0.5 text-xs"
      role="group"
      aria-label="How to edit"
    >
      {(
        [
          [true, 'Easy editor'],
          [false, 'HTML code'],
        ] as [boolean, string][]
      ).map(([value, label]) => (
        <button
          key={label}
          type="button"
          aria-pressed={easy === value}
          className={`rounded-md px-2.5 py-1 ${easy === value ? 'bg-primary-600 text-white' : 'text-secondary-600 hover:bg-secondary-100'}`}
          onClick={() => onChange(value)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

/** Someone pasted a whole HTML email into the easy editor: may it replace the email? (asks only if there is one) */
export async function acceptPastedHtml(current: string): Promise<boolean> {
  const hasContent =
    current
      .replace(/<[^>]*>/g, '')
      .replace(/&nbsp;/g, ' ')
      .trim() !== '';
  const ok =
    !hasContent ||
    (await confirmDialog({
      title: 'Use the HTML you pasted?',
      message:
        'It replaces what is in this email now. We open the HTML code view so your HTML stays exactly as pasted.',
      confirmText: 'Use my HTML',
    }));
  if (ok) toast.success('Your HTML is in. The preview shows how it looks.');
  return ok;
}
