'use client';

import React, { useCallback, useEffect } from 'react';
import { useEditor, EditorContent, type Editor } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import TextAlign from '@tiptap/extension-text-align';
import Placeholder from '@tiptap/extension-placeholder';
import Highlight from '@tiptap/extension-highlight';
import { TextStyle } from '@tiptap/extension-text-style';
import { Color } from '@tiptap/extension-color';
import { Table } from '@tiptap/extension-table';
import TableRow from '@tiptap/extension-table-row';
import TableHeader from '@tiptap/extension-table-header';
import TableCell from '@tiptap/extension-table-cell';
import Subscript from '@tiptap/extension-subscript';
import Superscript from '@tiptap/extension-superscript';
import {
  Bold,
  Italic,
  Underline,
  Strikethrough,
  Code,
  Code2,
  Highlighter,
  List,
  ListOrdered,
  Quote,
  Minus,
  Link2,
  Link2Off,
  Image as ImageIcon,
  Table as TableIcon,
  Undo2,
  Redo2,
  AlignLeft,
  AlignCenter,
  AlignRight,
  AlignJustify,
  Subscript as SubscriptIcon,
  Superscript as SuperscriptIcon,
  Palette,
  RemoveFormatting,
} from 'lucide-react';
import styles from './RichTextEditor.module.css';

export interface RichTextEditorProps {
  /** Initial / controlled HTML value */
  value?: string;
  /** Fired on every change with serialized HTML + ProseMirror JSON string */
  onChange?: (html: string, json: string) => void;
  placeholder?: string;
  editable?: boolean;
}

// ------------------------------------------------------------
// Toolbar building blocks
// ------------------------------------------------------------

interface TbButtonProps {
  onClick: () => void;
  active?: boolean;
  disabled?: boolean;
  title: string;
  children: React.ReactNode;
}

const TbButton: React.FC<TbButtonProps> = ({ onClick, active, disabled, title, children }) => (
  <button
    type="button"
    title={title}
    aria-label={title}
    aria-pressed={active}
    disabled={disabled}
    onClick={onClick}
    className={[
      styles.tbBtn,
      active ? styles.tbBtnActive : '',
      disabled ? styles.tbBtnDisabled : '',
    ].join(' ')}
  >
    {children}
  </button>
);

const Divider: React.FC = () => <span className={styles.divider} aria-hidden="true" />;

// ------------------------------------------------------------
// Toolbar
// ------------------------------------------------------------

const Toolbar: React.FC<{ editor: Editor }> = ({ editor }) => {
  const setLink = useCallback(() => {
    const previous = editor.getAttributes('link').href as string | undefined;
    const url = window.prompt('Link URL', previous ?? 'https://');
    if (url === null) return; // cancelled
    if (url.trim() === '') {
      editor.chain().focus().extendMarkRange('link').unsetLink().run();
      return;
    }
    editor.chain().focus().extendMarkRange('link').setLink({ href: url.trim() }).run();
  }, [editor]);

  const addImage = useCallback(() => {
    const url = window.prompt('Image URL (https://…)');
    if (url && url.trim()) {
      editor.chain().focus().setImage({ src: url.trim() }).run();
    }
  }, [editor]);

  const insertTable = useCallback(() => {
    editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run();
  }, [editor]);

  const onBlockTypeChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const v = e.target.value;
      const chain = editor.chain().focus();
      if (v === 'paragraph') {
        chain.setParagraph().run();
      } else {
        const level = Number(v.replace('h', '')) as 1 | 2 | 3 | 4;
        chain.toggleHeading({ level }).run();
      }
    },
    [editor]
  );

  const currentBlock = (): string => {
    for (const level of [1, 2, 3, 4] as const) {
      if (editor.isActive('heading', { level })) return `h${level}`;
    }
    return 'paragraph';
  };

  const currentColor = (editor.getAttributes('textStyle').color as string) || '#111827';

  return (
    <div className={styles.toolbar} role="toolbar" aria-label="Formatting">
      <TbButton title="Undo" onClick={() => editor.chain().focus().undo().run()} disabled={!editor.can().undo()}>
        <Undo2 size={16} />
      </TbButton>
      <TbButton title="Redo" onClick={() => editor.chain().focus().redo().run()} disabled={!editor.can().redo()}>
        <Redo2 size={16} />
      </TbButton>

      <Divider />

      <select
        className={styles.blockSelect}
        value={currentBlock()}
        onChange={onBlockTypeChange}
        title="Text style"
        aria-label="Text style"
      >
        <option value="paragraph">Paragraph</option>
        <option value="h1">Heading 1</option>
        <option value="h2">Heading 2</option>
        <option value="h3">Heading 3</option>
        <option value="h4">Heading 4</option>
      </select>

      <Divider />

      <TbButton title="Bold" active={editor.isActive('bold')} onClick={() => editor.chain().focus().toggleBold().run()}>
        <Bold size={16} />
      </TbButton>
      <TbButton title="Italic" active={editor.isActive('italic')} onClick={() => editor.chain().focus().toggleItalic().run()}>
        <Italic size={16} />
      </TbButton>
      <TbButton title="Underline" active={editor.isActive('underline')} onClick={() => editor.chain().focus().toggleUnderline().run()}>
        <Underline size={16} />
      </TbButton>
      <TbButton title="Strikethrough" active={editor.isActive('strike')} onClick={() => editor.chain().focus().toggleStrike().run()}>
        <Strikethrough size={16} />
      </TbButton>
      <TbButton title="Inline code" active={editor.isActive('code')} onClick={() => editor.chain().focus().toggleCode().run()}>
        <Code size={16} />
      </TbButton>
      <TbButton title="Highlight" active={editor.isActive('highlight')} onClick={() => editor.chain().focus().toggleHighlight().run()}>
        <Highlighter size={16} />
      </TbButton>

      <label className={styles.colorWrap} title="Text color">
        <Palette size={16} />
        <input
          type="color"
          className={styles.colorInput}
          value={currentColor}
          onChange={(e) => editor.chain().focus().setColor(e.target.value).run()}
          aria-label="Text color"
        />
      </label>

      <Divider />

      <TbButton title="Align left" active={editor.isActive({ textAlign: 'left' })} onClick={() => editor.chain().focus().setTextAlign('left').run()}>
        <AlignLeft size={16} />
      </TbButton>
      <TbButton title="Align center" active={editor.isActive({ textAlign: 'center' })} onClick={() => editor.chain().focus().setTextAlign('center').run()}>
        <AlignCenter size={16} />
      </TbButton>
      <TbButton title="Align right" active={editor.isActive({ textAlign: 'right' })} onClick={() => editor.chain().focus().setTextAlign('right').run()}>
        <AlignRight size={16} />
      </TbButton>
      <TbButton title="Justify" active={editor.isActive({ textAlign: 'justify' })} onClick={() => editor.chain().focus().setTextAlign('justify').run()}>
        <AlignJustify size={16} />
      </TbButton>

      <Divider />

      <TbButton title="Bullet list" active={editor.isActive('bulletList')} onClick={() => editor.chain().focus().toggleBulletList().run()}>
        <List size={16} />
      </TbButton>
      <TbButton title="Numbered list" active={editor.isActive('orderedList')} onClick={() => editor.chain().focus().toggleOrderedList().run()}>
        <ListOrdered size={16} />
      </TbButton>
      <TbButton title="Quote" active={editor.isActive('blockquote')} onClick={() => editor.chain().focus().toggleBlockquote().run()}>
        <Quote size={16} />
      </TbButton>
      <TbButton title="Code block" active={editor.isActive('codeBlock')} onClick={() => editor.chain().focus().toggleCodeBlock().run()}>
        <Code2 size={16} />
      </TbButton>
      <TbButton title="Horizontal rule" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
        <Minus size={16} />
      </TbButton>

      <Divider />

      <TbButton title="Subscript" active={editor.isActive('subscript')} onClick={() => editor.chain().focus().toggleSubscript().run()}>
        <SubscriptIcon size={16} />
      </TbButton>
      <TbButton title="Superscript" active={editor.isActive('superscript')} onClick={() => editor.chain().focus().toggleSuperscript().run()}>
        <SuperscriptIcon size={16} />
      </TbButton>

      <Divider />

      <TbButton title="Insert / edit link" active={editor.isActive('link')} onClick={setLink}>
        <Link2 size={16} />
      </TbButton>
      <TbButton title="Remove link" disabled={!editor.isActive('link')} onClick={() => editor.chain().focus().unsetLink().run()}>
        <Link2Off size={16} />
      </TbButton>
      <TbButton title="Insert image" onClick={addImage}>
        <ImageIcon size={16} />
      </TbButton>
      <TbButton title="Insert table" onClick={insertTable}>
        <TableIcon size={16} />
      </TbButton>

      <Divider />

      <TbButton
        title="Clear formatting"
        onClick={() => editor.chain().focus().unsetAllMarks().clearNodes().run()}
      >
        <RemoveFormatting size={16} />
      </TbButton>
    </div>
  );
};

// ------------------------------------------------------------
// Editor
// ------------------------------------------------------------

const RichTextEditor: React.FC<RichTextEditorProps> = ({
  value = '',
  onChange,
  placeholder = 'Start writing your lesson content…',
  editable = true,
}) => {
  const editor = useEditor({
    immediatelyRender: false, // required for Next.js SSR (avoids hydration mismatch)
    editable,
    extensions: [
      StarterKit.configure({
        heading: { levels: [1, 2, 3, 4] },
      }),
      TextStyle,
      Color,
      Highlight.configure({ multicolor: true }),
      // Underline, Link, CodeBlock and Heading are bundled in StarterKit v3.
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
      Image.configure({ inline: false, allowBase64: true, HTMLAttributes: { class: 'academy-img' } }),
      Subscript,
      Superscript,
      Table.configure({ resizable: true }),
      TableRow,
      TableHeader,
      TableCell,
      Placeholder.configure({ placeholder }),
    ],
    content: value,
    onUpdate: ({ editor: ed }) => {
      onChange?.(ed.getHTML(), JSON.stringify(ed.getJSON()));
    },
  });

  // Sync external value changes (e.g. async-loaded lesson) without disrupting typing.
  useEffect(() => {
    if (!editor) return;
    if (value !== editor.getHTML() && !editor.isFocused) {
      editor.commands.setContent(value || '', { emitUpdate: false });
    }
  }, [value, editor]);

  return (
    <div className={styles.editorShell}>
      {editor && <Toolbar editor={editor} />}
      <EditorContent editor={editor} className={styles.editorContent} />
    </div>
  );
};

export default RichTextEditor;
