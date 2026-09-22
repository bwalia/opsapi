'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useEditor, EditorContent, type Editor } from '@tiptap/react';
import { Node, mergeAttributes } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Mention from '@tiptap/extension-mention';
import type { SuggestionOptions, SuggestionProps, SuggestionKeyDownProps } from '@tiptap/suggestion';
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
  Youtube as YoutubeIcon,
} from 'lucide-react';
import styles from './RichTextEditor.module.css';

// ------------------------------------------------------------
// Video embed node (YouTube / Vimeo)
// ------------------------------------------------------------
// StarterKit has no iframe node, so any embedded video in existing content would
// be silently dropped on load — and wiped on the next save. This atom node
// parses existing <iframe> embeds, renders them in the editor, and preserves
// them in the serialized HTML. Only trusted hosts are kept (the learner site
// sanitises again on render).
const ALLOWED_VIDEO_HOSTS =
  /^(https:)?\/\/(www\.)?(youtube\.com|youtube-nocookie\.com|player\.vimeo\.com)\//i;

/** Normalise a pasted YouTube/Vimeo URL to its embeddable form. */
function toEmbedUrl(raw: string): string | null {
  const url = raw.trim();
  if (!url) return null;
  const yt =
    url.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([\w-]{6,})/i);
  if (yt) return `https://www.youtube.com/embed/${yt[1]}`;
  const vimeo = url.match(/vimeo\.com\/(?:video\/)?(\d+)/i);
  if (vimeo) return `https://player.vimeo.com/video/${vimeo[1]}`;
  return ALLOWED_VIDEO_HOSTS.test(url) ? url : null;
}

const VideoEmbed = Node.create({
  name: 'videoEmbed',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: true,
  addAttributes() {
    return {
      src: { default: null },
      title: { default: 'Lesson video' },
    };
  },
  parseHTML() {
    // Match any iframe; keep only trusted video hosts.
    return [
      {
        tag: 'iframe',
        getAttrs: (el) => {
          const src = (el as HTMLElement).getAttribute('src') || '';
          return ALLOWED_VIDEO_HOSTS.test(src) ? { src } : false;
        },
      },
    ];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      'div',
      { class: 'academy-video' },
      [
        'iframe',
        mergeAttributes(HTMLAttributes, {
          frameborder: '0',
          allow:
            'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture',
          allowfullscreen: 'true',
        }),
      ],
    ];
  },
});

export interface MentionItem {
  id: string;
  label: string;
}

// ------------------------------------------------------------
// @mention suggestion (inline "@" → member dropdown)
// ------------------------------------------------------------
// A dependency-light popup: no tippy.js. The dropdown is a plain fixed-position
// element appended to <body> and positioned at the caret's client rect. `getItems`
// is read lazily so async-loaded members are picked up without re-mounting the editor.
function buildMentionSuggestion(getItems: () => MentionItem[]): Omit<SuggestionOptions, 'editor'> {
  return {
    char: '@',
    items: ({ query }) => {
      const q = query.toLowerCase();
      return getItems()
        .filter((i) => i.label.toLowerCase().includes(q))
        .slice(0, 8);
    },
    render: () => {
      let el: HTMLDivElement | null = null;
      let items: MentionItem[] = [];
      let selected = 0;
      let command: ((item: MentionItem) => void) | null = null;

      const paint = () => {
        if (!el) return;
        if (items.length === 0) { el.style.display = 'none'; return; }
        el.style.display = 'block';
        el.innerHTML = '';
        items.forEach((item, idx) => {
          const b = document.createElement('button');
          b.type = 'button';
          b.textContent = `@${item.label}`;
          b.style.cssText =
            `display:block;width:100%;text-align:left;padding:6px 12px;font-size:13px;` +
            `border:0;cursor:pointer;background:${idx === selected ? '#eff6ff' : 'transparent'};` +
            `color:${idx === selected ? '#1d4ed8' : '#334155'};`;
          b.onmousedown = (e) => { e.preventDefault(); command?.(item); };
          el!.appendChild(b);
        });
      };

      const place = (rect: DOMRect | null | undefined) => {
        if (!el || !rect) return;
        el.style.left = `${rect.left}px`;
        el.style.top = `${rect.bottom + 4}px`;
      };

      return {
        onStart: (props: SuggestionProps<MentionItem>) => {
          items = props.items; selected = 0; command = props.command;
          el = document.createElement('div');
          el.style.cssText =
            'position:fixed;z-index:9999;min-width:180px;max-height:240px;overflow-y:auto;' +
            'background:#fff;border:1px solid #e2e8f0;border-radius:8px;' +
            'box-shadow:0 8px 24px rgba(0,0,0,.12);padding:4px 0;';
          document.body.appendChild(el);
          paint();
          place(props.clientRect?.());
        },
        onUpdate: (props: SuggestionProps<MentionItem>) => {
          items = props.items; selected = 0; command = props.command;
          paint();
          place(props.clientRect?.());
        },
        onKeyDown: (props: SuggestionKeyDownProps) => {
          if (!items.length) return false;
          const { key } = props.event;
          if (key === 'ArrowDown') { selected = (selected + 1) % items.length; paint(); return true; }
          if (key === 'ArrowUp') { selected = (selected - 1 + items.length) % items.length; paint(); return true; }
          if (key === 'Enter' || key === 'Tab') { command?.(items[selected]); return true; }
          if (key === 'Escape') { el?.remove(); el = null; return true; }
          return false;
        },
        onExit: () => { el?.remove(); el = null; },
      };
    },
  };
}

export interface RichTextEditorProps {
  /** Initial / controlled HTML value */
  value?: string;
  /** Fired on every change with serialized HTML + ProseMirror JSON string */
  onChange?: (html: string, json: string) => void;
  placeholder?: string;
  editable?: boolean;
  /** When provided, typing "@" opens a mention picker over these items. */
  mentionItems?: MentionItem[];
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

const Toolbar: React.FC<{
  editor: Editor;
  sourceMode?: boolean;
  onToggleSource?: () => void;
}> = ({ editor, sourceMode, onToggleSource }) => {
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

  const addVideo = useCallback(() => {
    const url = window.prompt('YouTube or Vimeo URL');
    if (!url) return;
    const src = toEmbedUrl(url);
    if (!src) {
      window.alert('Please paste a valid YouTube or Vimeo link.');
      return;
    }
    editor
      .chain()
      .focus()
      .insertContent({ type: 'videoEmbed', attrs: { src } })
      .run();
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

  // In HTML source mode the rich buttons would act on a hidden editor, so show
  // a slim toolbar with just the toggle back to the visual editor. (Placed after
  // all hooks above so the Rules of Hooks are respected.)
  if (sourceMode) {
    return (
      <div className={styles.toolbar} role="toolbar" aria-label="HTML source">
        <TbButton title="Back to visual editor" active onClick={() => onToggleSource?.()}>
          <Code2 size={16} />
        </TbButton>
        <span className="ml-2 text-xs font-medium text-secondary-500">Editing HTML source</span>
      </div>
    );
  }

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
      <TbButton title="Insert video (YouTube / Vimeo)" onClick={addVideo}>
        <YoutubeIcon size={16} />
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

      {onToggleSource && (
        <>
          <Divider />
          <TbButton title="View / edit HTML source" onClick={() => onToggleSource()}>
            <Code2 size={16} />
          </TbButton>
        </>
      )}
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
  mentionItems,
}) => {
  // Read the latest items lazily so async-loaded members work without remounting.
  const mentionItemsRef = useRef<MentionItem[]>(mentionItems ?? []);
  useEffect(() => { mentionItemsRef.current = mentionItems ?? []; }, [mentionItems]);
  const withMentions = mentionItems !== undefined;

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
      VideoEmbed,
      Subscript,
      Superscript,
      Table.configure({ resizable: true }),
      TableRow,
      TableHeader,
      TableCell,
      Placeholder.configure({ placeholder }),
      ...(withMentions
        ? [Mention.configure({
            HTMLAttributes: { class: 'mention', style: 'color:#2563eb;font-weight:500' },
            // The getter is invoked by TipTap on keystroke (never during render),
            // so reading the ref here is safe.
            // eslint-disable-next-line react-hooks/refs
            suggestion: buildMentionSuggestion(() => mentionItemsRef.current),
          })]
        : []),
    ],
    content: value,
    onUpdate: ({ editor: ed }) => {
      onChange?.(ed.getHTML(), JSON.stringify(ed.getJSON()));
    },
  });

  // HTML source ("code view") mode — lets you paste/edit raw HTML directly, the
  // way CKEditor's source view does. sourceValue holds the raw textarea text.
  const [sourceMode, setSourceMode] = useState(false);
  const [sourceValue, setSourceValue] = useState('');

  const toggleSource = useCallback(() => {
    if (!editor) return;
    if (sourceMode) {
      // Leaving source view: push the edited HTML back into the editor. TipTap
      // parses/sanitises it and emitUpdate fires onChange with normalised HTML+JSON.
      editor.commands.setContent(sourceValue || '', { emitUpdate: true });
      setSourceMode(false);
    } else {
      setSourceValue(editor.getHTML());
      setSourceMode(true);
    }
  }, [editor, sourceMode, sourceValue]);

  // Sync external value changes (e.g. async-loaded content) without disrupting
  // typing — and never while the user is hand-editing HTML in source view.
  useEffect(() => {
    if (!editor || sourceMode) return;
    if (value !== editor.getHTML() && !editor.isFocused) {
      editor.commands.setContent(value || '', { emitUpdate: false });
    }
  }, [value, editor, sourceMode]);

  return (
    <div className={styles.editorShell}>
      {/* No toolbar in read-only mode — used to render stored HTML safely. */}
      {editor && editable && <Toolbar editor={editor} sourceMode={sourceMode} onToggleSource={toggleSource} />}
      {sourceMode ? (
        <textarea
          className="block w-full min-h-80 resize-y bg-surface p-4 font-mono text-[13px] leading-relaxed text-secondary-900 focus:outline-none"
          value={sourceValue}
          spellCheck={false}
          readOnly={!editable}
          aria-label="HTML source"
          placeholder="<p>Paste or write raw HTML here…</p>"
          onChange={(e) => {
            const html = e.target.value;
            setSourceValue(html);
            // Keep the parent form in sync as you type raw HTML. content_json is
            // rebuilt from HTML on load, so an empty JSON here is fine.
            onChange?.(html, '');
          }}
        />
      ) : (
        <EditorContent editor={editor} className={styles.editorContent} />
      )}
    </div>
  );
};

export default RichTextEditor;
