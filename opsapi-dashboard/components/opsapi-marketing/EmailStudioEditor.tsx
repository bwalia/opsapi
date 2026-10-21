'use client';

import React, { useEffect } from 'react';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import Placeholder from '@tiptap/extension-placeholder';
import TextAlign from '@tiptap/extension-text-align';
import {
  Bold,
  Italic,
  Link2,
  Image as ImageIcon,
  Undo2,
  Redo2,
  AlignLeft,
  AlignCenter,
  Minus,
  Heading2,
} from 'lucide-react';

type Props = {
  value: string;
  onChange: (html: string) => void;
  placeholder?: string;
};

function Tb({
  onClick,
  active,
  title,
  children,
}: {
  onClick: () => void;
  active?: boolean;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className={`inline-flex h-8 w-8 items-center justify-center rounded text-sm ${
        active ? 'bg-muted text-foreground' : 'text-muted-foreground hover:bg-muted/60'
      }`}
    >
      {children}
    </button>
  );
}

/** Email-safe TipTap editor (no iframes). Link mark comes from StarterKit v3. */
export function EmailStudioEditor({ value, onChange, placeholder }: Props) {
  const editor = useEditor({
    immediatelyRender: false,
    extensions: [
      StarterKit.configure({
        heading: { levels: [1, 2, 3] },
        codeBlock: false,
        code: false,
      }),
      Image.configure({ allowBase64: false }),
      Placeholder.configure({ placeholder: placeholder || 'Write your email…' }),
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
    ],
    content: value || '',
    onUpdate: ({ editor: ed }) => onChange(ed.getHTML()),
    editorProps: {
      attributes: {
        class:
          'prose prose-sm max-w-none min-h-[280px] px-4 py-3 focus:outline-none text-foreground',
      },
    },
  });

  useEffect(() => {
    if (!editor) return;
    const current = editor.getHTML();
    if (value !== current && value !== undefined) {
      editor.commands.setContent(value || '', { emitUpdate: false });
    }
  }, [value, editor]);

  if (!editor) return <div className="min-h-[280px] rounded border border-border bg-muted/20" />;

  const setLink = () => {
    const prev = editor.getAttributes('link').href as string | undefined;
    const url = window.prompt('Link URL (https:// or {{merge_field}})', prev || 'https://');
    if (url === null) return;
    if (url === '') {
      editor.chain().focus().extendMarkRange('link').unsetLink().run();
      return;
    }
    if (!/^(https?:|mailto:|#|{{)/i.test(url) || /^(javascript|data):/i.test(url)) {
      window.alert('Only https, mailto, # or {{merge}} links are allowed');
      return;
    }
    editor.chain().focus().extendMarkRange('link').setLink({ href: url }).run();
  };

  const setImage = () => {
    const url = window.prompt('Image URL (https://)');
    if (!url) return;
    if (!/^https:\/\//i.test(url)) {
      window.alert('Only https image URLs are allowed');
      return;
    }
    editor.chain().focus().setImage({ src: url, alt: '' }).run();
  };

  const insertHtml = (html: string) => {
    editor.chain().focus().insertContent(html).run();
  };

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-background">
      <div className="flex flex-wrap items-center gap-0.5 border-b border-border bg-muted/30 px-2 py-1.5">
        <Tb title="Undo" onClick={() => editor.chain().focus().undo().run()}>
          <Undo2 className="h-4 w-4" />
        </Tb>
        <Tb title="Redo" onClick={() => editor.chain().focus().redo().run()}>
          <Redo2 className="h-4 w-4" />
        </Tb>
        <span className="mx-1 h-4 w-px bg-border" />
        <Tb
          title="Heading"
          active={editor.isActive('heading', { level: 2 })}
          onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
        >
          <Heading2 className="h-4 w-4" />
        </Tb>
        <Tb title="Bold" active={editor.isActive('bold')} onClick={() => editor.chain().focus().toggleBold().run()}>
          <Bold className="h-4 w-4" />
        </Tb>
        <Tb
          title="Italic"
          active={editor.isActive('italic')}
          onClick={() => editor.chain().focus().toggleItalic().run()}
        >
          <Italic className="h-4 w-4" />
        </Tb>
        <Tb title="Link" active={editor.isActive('link')} onClick={setLink}>
          <Link2 className="h-4 w-4" />
        </Tb>
        <Tb title="Image" onClick={setImage}>
          <ImageIcon className="h-4 w-4" />
        </Tb>
        <Tb title="Divider" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
          <Minus className="h-4 w-4" />
        </Tb>
        <Tb
          title="Align left"
          active={editor.isActive({ textAlign: 'left' })}
          onClick={() => editor.chain().focus().setTextAlign('left').run()}
        >
          <AlignLeft className="h-4 w-4" />
        </Tb>
        <Tb
          title="Align center"
          active={editor.isActive({ textAlign: 'center' })}
          onClick={() => editor.chain().focus().setTextAlign('center').run()}
        >
          <AlignCenter className="h-4 w-4" />
        </Tb>
        <span className="mx-1 h-4 w-px bg-border" />
        <button
          type="button"
          className="rounded px-2 py-1 text-xs text-muted-foreground hover:bg-muted"
          onClick={() =>
            insertHtml(
              '<p><a href="https://example.com" style="display:inline-block;background:#111;color:#fff;padding:12px 20px;text-decoration:none;border-radius:4px">Call to action</a></p>',
            )
          }
        >
          CTA
        </button>
        <button
          type="button"
          className="rounded px-2 py-1 text-xs text-muted-foreground hover:bg-muted"
          onClick={() =>
            insertHtml(
              '<p style="font-size:12px;color:#666"><a href="{{unsubscribe_url}}">Unsubscribe</a> · <a href="{{preferences_url}}">Preferences</a></p>',
            )
          }
        >
          Unsubscribe
        </button>
      </div>
      <EditorContent editor={editor} />
    </div>
  );
}
