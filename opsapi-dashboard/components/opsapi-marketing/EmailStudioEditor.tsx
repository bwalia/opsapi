'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { isAxiosError } from 'axios';
import toast from 'react-hot-toast';
import { useEditor, useEditorState, EditorContent, Extension, type Editor } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import Placeholder from '@tiptap/extension-placeholder';
import TextAlign from '@tiptap/extension-text-align';
import { TextStyle } from '@tiptap/extension-text-style';
import { Color } from '@tiptap/extension-color';
import Highlight from '@tiptap/extension-highlight';
import {
  AlignCenter,
  AlignLeft,
  AlignRight,
  Bold,
  Code2,
  Globe,
  Highlighter,
  Image as ImageIcon,
  Italic,
  Link2,
  List,
  ListOrdered,
  Loader2,
  Minus,
  MousePointerClick,
  Pencil,
  Redo2,
  Trash2,
  Underline as UnderlineIcon,
  Undo2,
  Unlink,
} from 'lucide-react';
import { Button, Modal } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { confirmDialog, promptDialog } from '@/components/ui/Dialogs';

export const EMAIL_IMAGE_TYPES = 'image/png,image/jpeg,image/gif,image/webp';
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

/** Upload an image for an email; resolves to its public URL (works in any mail client). */
export async function uploadEmailImage(file: File): Promise<string> {
  if (file.size > MAX_IMAGE_BYTES) throw new Error('Images can be up to 2 MB');
  const content_base64 = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ''));
    reader.onerror = () => reject(new Error('Could not read the image'));
    reader.readAsDataURL(file);
  });
  try {
    const res = await marketingService.uploadImage({ file_name: file.name, content_base64 });
    const url = res.data?.data?.url ?? res.data?.url;
    if (!url) throw new Error('Upload failed');
    return url as string;
  } catch (e: unknown) {
    const msg = isAxiosError(e) ? (e.response?.data as { error?: string } | undefined)?.error : undefined;
    throw new Error(msg || (e instanceof Error ? e.message : 'Upload failed'));
  }
}

type Props = {
  value: string;
  onChange: (html: string) => void;
  placeholder?: string;
  /** Shown as a "Personalise" menu that puts e.g. {{contact.first_name}} at the cursor. */
  mergeFields?: { key: string; label: string }[];
  /** Show the content without editing (e.g. a campaign that was already sent). */
  readOnly?: boolean;
};

/** Keep inline styles (button colours, spacing, image sizes): emails rely on them. */
const KeepStyles = Extension.create({
  name: 'keepStyles',
  addGlobalAttributes() {
    return [
      {
        types: ['paragraph', 'heading', 'link', 'image'],
        attributes: {
          style: {
            default: null,
            parseHTML: (el) => el.getAttribute('style'),
            renderHTML: (attrs) => (attrs.style ? { style: attrs.style } : {}),
          },
        },
      },
    ];
  },
});

/** Links may be https/mailto/# or a merge field such as {{unsubscribe_url}}. */
const allowedHref = (url: string, ctx: { defaultValidate: (u: string) => boolean }) =>
  /^\{\{\s*[\w.]+\s*\}\}$/.test(url) || ctx.defaultValidate(url);

const hrefProblem = (v: string) =>
  /^(https?:\/\/\S+|mailto:\S+|tel:[+\d][\d\s-]*|#\S*|\{\{\s*[\w.]+\s*\}\})$/i.test(v.trim())
    ? undefined
    : 'Start it with https:// (a website), mailto: (an email address) or tel: (a phone number)';

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

const BUTTON_COLOURS = ['#111827', '#e11d48', '#2563eb', '#16a34a', '#ea580c', '#7c3aed', '#0891b2', '#ca8a04'];

/** White words on dark buttons, dark words on light ones. */
function textOn(bg: string): string {
  const m = bg.replace('#', '').match(/^([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i);
  if (!m) return '#ffffff';
  const [r, g, b] = m.slice(1).map((h) => parseInt(h, 16) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 ? '#111827' : '#ffffff';
}

type ButtonSpec = { text: string; href: string; color: string };

/** A button's background as #rrggbb (the editor stores colours as rgb(…)). */
function backgroundHex(style?: string): string {
  const v = (style || '').match(/background(?:-color)?:\s*([^;]+)/i)?.[1]?.trim() || '';
  const rgb = v.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
  if (rgb)
    return `#${rgb
      .slice(1, 4)
      .map((n) => Number(n).toString(16).padStart(2, '0'))
      .join('')}`;
  if (/^#[0-9a-f]{6}$/i.test(v)) return v.toLowerCase();
  if (/^#[0-9a-f]{3}$/i.test(v)) return `#${[...v.slice(1)].map((c) => c + c).join('')}`.toLowerCase();
  return '#111827';
}

const buttonLink = (b: ButtonSpec) =>
  `<a href="${esc(b.href.trim())}" style="display:inline-block;background:${b.color};color:${textOn(b.color)};` +
  `padding:12px 22px;border-radius:6px;text-decoration:none;font-weight:600">${esc(b.text.trim())}</a>`;

/** Add or change a button: its words, where it goes, its colour (with a live preview). */
function ButtonDialog({
  initial,
  onSave,
  onClose,
}: {
  initial: ButtonSpec & { editing: boolean };
  onSave: (b: ButtonSpec) => void;
  onClose: () => void;
}) {
  const [b, setB] = useState<ButtonSpec>(initial);
  const [tried, setTried] = useState(false);
  const textRef = useRef<HTMLInputElement>(null);
  // After the Modal has focused itself on open, put the cursor in the first box.
  useEffect(() => {
    const t = window.setTimeout(() => textRef.current?.focus(), 0);
    return () => window.clearTimeout(t);
  }, []);
  const textErr = b.text.trim() ? undefined : 'Type the words for the button';
  const hrefErr = hrefProblem(b.href);
  const save = () => {
    setTried(true);
    if (!textErr && !hrefErr) onSave(b);
  };
  return (
    <Modal
      isOpen
      onClose={onClose}
      title={initial.editing ? 'Edit button' : 'Add a button'}
      size="md"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={save}>{initial.editing ? 'Save button' : 'Add button'}</Button>
        </>
      }
    >
      <form
        className="space-y-4"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        <label className="block">
          <span className="text-sm font-medium text-secondary-800">Words on the button</span>
          <input
            className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base"
            value={b.text}
            onChange={(e) => setB({ ...b, text: e.target.value })}
            placeholder="e.g. Get a free quote"
            maxLength={60}
            ref={textRef}
          />
          {tried && textErr && <span className="mt-1 block text-sm text-error-600">{textErr}</span>}
        </label>
        <label className="block">
          <span className="text-sm font-medium text-secondary-800">Where it takes people</span>
          <input
            className="mt-1 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base"
            value={b.href}
            onChange={(e) => setB({ ...b, href: e.target.value })}
            placeholder="https://yourwebsite.co.uk/contact"
          />
          <span className="mt-1 block text-xs text-secondary-500">
            A web page (https://…), an email address (mailto:you@yourbusiness.co.uk) or a phone (tel:+44…).
          </span>
          {tried && hrefErr && <span className="mt-1 block text-sm text-error-600">{hrefErr}</span>}
        </label>
        <fieldset>
          <legend className="text-sm font-medium text-secondary-800">Colour</legend>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            {BUTTON_COLOURS.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => setB({ ...b, color: c })}
                aria-label={`Colour ${c}`}
                aria-pressed={b.color === c}
                className={`h-8 w-8 rounded-full border-2 ${b.color === c ? 'border-primary-500 ring-2 ring-primary-500/30' : 'border-white shadow'}`}
                style={{ background: c }}
              />
            ))}
            <label className="flex items-center gap-1.5 text-sm text-secondary-600">
              <input
                type="color"
                value={b.color}
                onChange={(e) => setB({ ...b, color: e.target.value })}
                className="h-8 w-10 cursor-pointer rounded border border-secondary-300 bg-transparent"
                aria-label="Any colour"
              />
              Any colour
            </label>
          </div>
        </fieldset>
        <div className="rounded-lg bg-secondary-50 p-4 text-center dark:bg-secondary-900/40">
          <span className="mb-2 block text-xs text-secondary-500">Preview</span>
          <span
            style={{
              display: 'inline-block',
              background: b.color,
              color: textOn(b.color),
              padding: '12px 22px',
              borderRadius: 6,
              fontWeight: 600,
            }}
          >
            {b.text.trim() || 'Your button'}
          </span>
        </div>
      </form>
    </Modal>
  );
}

function Tb({
  onClick,
  active,
  title,
  disabled,
  children,
}: {
  onClick: () => void;
  active?: boolean;
  title: string;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
      className={`inline-flex h-8 min-w-8 items-center justify-center gap-1 rounded px-1.5 text-sm disabled:opacity-40 ${
        active ? 'bg-primary-500/15 text-primary-700 dark:text-primary-300' : 'text-muted-foreground hover:bg-muted/60'
      }`}
    >
      {children}
    </button>
  );
}

const Sep = () => <span className="mx-1 h-5 w-px bg-border" aria-hidden="true" />;

/** What the cursor is on, for the context bar (link / button / picture). */
function useSelectionInfo(editor: Editor | null) {
  return useEditorState({
    editor,
    selector: ({ editor: ed }) => {
      if (!ed) return { block: 'p', link: null, image: null };
      const block = ed.isActive('heading', { level: 1 })
        ? 'h1'
        : ed.isActive('heading', { level: 2 })
          ? 'h2'
          : ed.isActive('heading', { level: 3 })
            ? 'h3'
            : 'p';
      const a = ed.isActive('link') ? (ed.getAttributes('link') as { href?: string; style?: string }) : null;
      const img = ed.isActive('image') ? (ed.getAttributes('image') as { src?: string; style?: string }) : null;
      return {
        block,
        link: a ? { href: a.href || '', isButton: /background/i.test(a.style || '') } : null,
        image: img ? { src: img.src || '', style: img.style || '' } : null,
      };
    },
  });
}

/** A body that is one styled <div> around the content (the card of the ready-made designs):
 * the editor edits what's inside and keeps the card. */
export function splitFrame(html: string): { open: string; inner: string } {
  const m = html.match(/^\s*(<div\b[^>]*>)([\s\S]*)<\/div>\s*$/i);
  return m ? { open: m[1], inner: m[2].trim() } : { open: '', inner: html };
}

/** The card's inline style as a React style, so editing looks like the email. */
function frameStyle(open: string): React.CSSProperties {
  const css = open.match(/style="([^"]*)"/i)?.[1] ?? '';
  const out: Record<string, string> = {};
  for (const decl of css.split(';')) {
    const i = decl.indexOf(':');
    if (i < 1) continue;
    const prop = decl.slice(0, i).trim().toLowerCase();
    if (!/^(font-family|font-size|line-height|color|background|background-color|padding)$/.test(prop)) continue;
    out[prop.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase())] = decl.slice(i + 1).trim();
  }
  return out as React.CSSProperties;
}

// Table layouts (most hand-coded and imported emails) don't fit TipTap's schema: loading them
// flattens the design and the next keystroke saves it flattened, so they open as HTML source.
const TABLE_LAYOUT = /<(table|tbody|tr|td|center|body|html)\b/i;

/** Pasted text that is HTML source (starts with a tag and has a closing or void tag), not prose. */
const looksLikeHtml = (text: string) =>
  /^\s*<(!doctype|[a-z][a-z0-9]*)[\s>/]/i.test(text) && /<\/[a-z][a-z0-9]*\s*>|<(br|img|hr|meta)\b/i.test(text);
/** A whole email rather than a snippet: it goes to the HTML source so nothing in it is lost. */
const WHOLE_EMAIL = /<(table|tbody|tr|td|center|body|html|style)\b|<!doctype/i;

/** Email-safe TipTap editor (no iframes). Link mark comes from StarterKit v3. */
export function EmailStudioEditor({ value, onChange, placeholder, mergeFields, readOnly = false }: Props) {
  const [mode, setMode] = useState<'visual' | 'html'>(() => (TABLE_LAYOUT.test(value || '') ? 'html' : 'visual'));
  // A layout template picked later must not be flattened either; the editor's own output never
  // contains tables, so typing doesn't flip the mode.
  const [prevValue, setPrevValue] = useState(value);
  if (value !== prevValue) {
    setPrevValue(value);
    if (mode === 'visual' && TABLE_LAYOUT.test(value || '')) setMode('html');
  }
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [buttonDialog, setButtonDialog] = useState<(ButtonSpec & { editing: boolean }) | null>(null);
  const frame = useMemo(() => splitFrame(value || ''), [value]);
  const openRef = useRef(frame.open);
  useEffect(() => {
    openRef.current = frame.open;
  }, [frame.open]);
  // The editor keeps the options it was created with: its paste handler reads the latest props here.
  const latest = useRef({ value, onChange });
  useEffect(() => {
    latest.current = { value, onChange };
  }, [value, onChange]);
  const editorRef = useRef<Editor | null>(null);
  /** A whole HTML email pasted as code: keep it as HTML (asking first if it replaces an email). */
  const pasteWholeEmail = async (html: string) => {
    const { value: current, onChange: change } = latest.current;
    const hasContent =
      (current || '')
        .replace(/<[^>]*>/g, '')
        .replace(/&nbsp;/g, ' ')
        .trim() !== '';
    if (
      hasContent &&
      !(await confirmDialog({
        title: 'Use the HTML you pasted?',
        message:
          'It replaces what is in this email now and opens the HTML source, so your design stays exactly as pasted.',
        confirmText: 'Use my HTML',
      }))
    )
      return;
    change(html);
    setMode('html');
    toast.success('Your HTML is in. Check the preview to see how it looks.');
  };
  const editor = useEditor({
    immediatelyRender: false,
    editable: !readOnly,
    extensions: [
      StarterKit.configure({
        heading: { levels: [1, 2, 3] },
        codeBlock: false,
        code: false,
        link: { openOnClick: false, isAllowedUri: allowedHref },
      }),
      KeepStyles,
      TextStyle,
      Color,
      Highlight,
      Image.configure({ allowBase64: false }),
      Placeholder.configure({ placeholder: placeholder || 'Write your email…' }),
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
    ],
    content: frame.inner,
    onUpdate: ({ editor: ed }) => {
      const html = ed.getHTML();
      onChange(openRef.current ? `${openRef.current}\n${html}\n</div>` : html);
    },
    editorProps: {
      attributes: {
        class: 'prose prose-sm max-w-none min-h-[280px] px-4 py-3 focus:outline-none text-foreground',
      },
      // HTML source pasted as text would otherwise show up as code in the email.
      handlePaste: (_view, event) => {
        const text = (event.clipboardData?.getData('text/plain') ?? '').trim();
        if (!looksLikeHtml(text)) return false;
        if (WHOLE_EMAIL.test(text)) {
          void pasteWholeEmail(text);
          return true;
        }
        // A snippet (e.g. <b>Sale</b> or a paragraph with a link): insert it formatted.
        return editorRef.current?.chain().focus().insertContent(text).run() ?? false;
      },
    },
  });
  const sel = useSelectionInfo(editor);
  useEffect(() => {
    editorRef.current = editor;
  }, [editor]);

  useEffect(() => {
    if (!editor || mode !== 'visual') return;
    if (frame.inner !== editor.getHTML()) {
      // cursor to the top: left at the end it sits in the footer's link and shows that link's bar
      editor.chain().setContent(frame.inner, { emitUpdate: false }).setTextSelection(0).run();
    }
  }, [frame.inner, editor, mode]);

  useEffect(() => {
    editor?.setEditable(!readOnly);
  }, [editor, readOnly]);

  const toggleMode = async () => {
    if (
      mode === 'html' &&
      TABLE_LAYOUT.test(value || '') &&
      !(await confirmDialog({
        title: 'Open in the visual editor?',
        message: 'The visual editor can’t keep this layout (tables), so the design may change.',
        confirmText: 'Open visual editor',
      }))
    )
      return;
    setMode(mode === 'html' ? 'visual' : 'html');
  };

  if (mode === 'html') {
    return (
      <div className="overflow-hidden rounded-lg border border-border bg-background">
        <div className="flex items-center gap-0.5 border-b border-border bg-muted/30 px-2 py-1.5">
          {!readOnly && (
            <Tb title="Visual editor" active onClick={() => void toggleMode()}>
              <Code2 className="h-4 w-4" />
            </Tb>
          )}
          <span className="px-2 text-xs text-muted-foreground">HTML source · check the preview to see the design</span>
        </div>
        <textarea
          aria-label="Email HTML source"
          className="block min-h-[280px] w-full resize-y bg-background px-4 py-3 font-mono text-xs text-foreground focus:outline-none"
          spellCheck={false}
          readOnly={readOnly}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </div>
    );
  }

  if (!editor) return <div className="min-h-[280px] rounded border border-border bg-muted/20" />;

  const chain = () => editor.chain().focus();

  const setLink = async () => {
    const prev = editor.getAttributes('link').href as string | undefined;
    if (!prev && editor.state.selection.empty) {
      toast('Select the words you want to link first, then press the link button.');
      return;
    }
    const url = await promptDialog({
      title: prev ? 'Change the link' : 'Add a link',
      label: 'Where should it take people?',
      message: 'A web page (https://…), an email address (mailto:…) or a phone number (tel:…).',
      defaultValue: prev || 'https://',
      placeholder: 'https://yourwebsite.co.uk',
      confirmText: 'Save link',
      validate: (v) => (v.trim() === '' ? 'Type a web address, or press Cancel' : hrefProblem(v)),
    });
    if (url === null) return;
    chain().extendMarkRange('link').setLink({ href: url.trim() }).run();
  };

  const removeLink = () => chain().extendMarkRange('link').unsetLink().run();

  /** The button the cursor is on: its words and colour, for "Edit button". */
  const currentButton = (): ButtonSpec => {
    chain().extendMarkRange('link').run();
    const { from, to } = editor.state.selection;
    const a = editor.getAttributes('link') as { href?: string; style?: string };
    return { text: editor.state.doc.textBetween(from, to), href: a.href || 'https://', color: backgroundHex(a.style) };
  };

  const saveButton = (b: ButtonSpec) => {
    if (buttonDialog?.editing) chain().extendMarkRange('link').insertContent(buttonLink(b)).run();
    else
      chain()
        .insertContent(`<p>${buttonLink(b)}</p>`)
        .run();
    setButtonDialog(null);
  };

  const uploadImage = async (file: File | undefined) => {
    if (!file) return;
    setUploading(true);
    try {
      const src = await uploadEmailImage(file);
      chain().setImage({ src, alt: '' }).run();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Upload failed');
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const setImageUrl = async () => {
    const url = await promptDialog({
      title: 'Add a picture from the web',
      label: 'Picture address',
      message:
        'Paste the address of a picture that is already online. To use a picture from your computer, use the picture button instead.',
      placeholder: 'https://…/picture.png',
      inputType: 'url',
      confirmText: 'Add picture',
      validate: (v) => (/^https:\/\/\S+$/i.test(v.trim()) ? undefined : 'The address must start with https://'),
    });
    if (!url) return;
    chain().setImage({ src: url.trim(), alt: '' }).run();
  };

  const imageWidth = (w: string) =>
    chain()
      .updateAttributes('image', { style: `width:${w};max-width:100%;height:auto;display:block` })
      .run();

  const setBlock = (b: string) => {
    if (b === 'p') chain().setParagraph().run();
    else
      chain()
        .setHeading({ level: Number(b[1]) as 1 | 2 | 3 })
        .run();
  };

  const color = (editor.getAttributes('textStyle').color as string) || '#111827';

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-background">
      {!readOnly && (
        <div
          className="flex flex-wrap items-center gap-0.5 border-b border-border bg-muted/30 px-2 py-1.5"
          role="toolbar"
          aria-label="Formatting"
        >
          <Tb title="Edit HTML source" onClick={() => void toggleMode()}>
            <Code2 className="h-4 w-4" />
          </Tb>
          <Sep />
          <Tb title="Undo" onClick={() => chain().undo().run()}>
            <Undo2 className="h-4 w-4" />
          </Tb>
          <Tb title="Redo" onClick={() => chain().redo().run()}>
            <Redo2 className="h-4 w-4" />
          </Tb>
          <Sep />
          <select
            className="h-8 rounded border border-border bg-background px-1.5 text-xs text-foreground"
            value={sel?.block ?? 'p'}
            onChange={(e) => setBlock(e.target.value)}
            aria-label="Text style"
            title="Text style"
          >
            <option value="p">Normal text</option>
            <option value="h1">Big heading</option>
            <option value="h2">Heading</option>
            <option value="h3">Small heading</option>
          </select>
          <Tb title="Bold" active={editor.isActive('bold')} onClick={() => chain().toggleBold().run()}>
            <Bold className="h-4 w-4" />
          </Tb>
          <Tb title="Italic" active={editor.isActive('italic')} onClick={() => chain().toggleItalic().run()}>
            <Italic className="h-4 w-4" />
          </Tb>
          <Tb title="Underline" active={editor.isActive('underline')} onClick={() => chain().toggleUnderline().run()}>
            <UnderlineIcon className="h-4 w-4" />
          </Tb>
          <label
            className="inline-flex h-8 cursor-pointer items-center gap-1 rounded px-1.5 text-muted-foreground hover:bg-muted/60"
            title="Text colour"
          >
            <span className="text-sm font-bold" style={{ color }} aria-hidden="true">
              A
            </span>
            <input
              type="color"
              value={/^#[0-9a-f]{6}$/i.test(color) ? color : '#111827'}
              onChange={(e) => chain().setColor(e.target.value).run()}
              className="h-5 w-5 cursor-pointer border-0 bg-transparent p-0"
              aria-label="Text colour"
            />
          </label>
          <Tb title="Highlight" active={editor.isActive('highlight')} onClick={() => chain().toggleHighlight().run()}>
            <Highlighter className="h-4 w-4" />
          </Tb>
          <Sep />
          <Tb
            title="Align left"
            active={editor.isActive({ textAlign: 'left' })}
            onClick={() => chain().setTextAlign('left').run()}
          >
            <AlignLeft className="h-4 w-4" />
          </Tb>
          <Tb
            title="Centre"
            active={editor.isActive({ textAlign: 'center' })}
            onClick={() => chain().setTextAlign('center').run()}
          >
            <AlignCenter className="h-4 w-4" />
          </Tb>
          <Tb
            title="Align right"
            active={editor.isActive({ textAlign: 'right' })}
            onClick={() => chain().setTextAlign('right').run()}
          >
            <AlignRight className="h-4 w-4" />
          </Tb>
          <Tb
            title="Bullet list"
            active={editor.isActive('bulletList')}
            onClick={() => chain().toggleBulletList().run()}
          >
            <List className="h-4 w-4" />
          </Tb>
          <Tb
            title="Numbered list"
            active={editor.isActive('orderedList')}
            onClick={() => chain().toggleOrderedList().run()}
          >
            <ListOrdered className="h-4 w-4" />
          </Tb>
          <Sep />
          <Tb title="Link (select the words first)" active={editor.isActive('link')} onClick={() => void setLink()}>
            <Link2 className="h-4 w-4" />
          </Tb>
          <Tb
            title={uploading ? 'Uploading picture…' : 'Picture from your computer'}
            onClick={() => fileRef.current?.click()}
            disabled={uploading}
          >
            {uploading ? <Loader2 className="h-4 w-4 animate-spin" /> : <ImageIcon className="h-4 w-4" />}
          </Tb>
          <input
            ref={fileRef}
            type="file"
            accept={EMAIL_IMAGE_TYPES}
            className="hidden"
            aria-label="Upload picture"
            onChange={(e) => void uploadImage(e.target.files?.[0])}
          />
          <Tb title="Picture from the web" onClick={() => void setImageUrl()}>
            <Globe className="h-4 w-4" />
          </Tb>
          <Tb title="Divider line" onClick={() => chain().setHorizontalRule().run()}>
            <Minus className="h-4 w-4" />
          </Tb>
          <Sep />
          <Tb
            title="Add a button"
            onClick={() => setButtonDialog({ text: '', href: 'https://', color: BUTTON_COLOURS[0], editing: false })}
          >
            <MousePointerClick className="h-4 w-4" />
            <span className="text-xs">Button</span>
          </Tb>
          <Tb
            title="Add an unsubscribe link"
            onClick={() =>
              chain()
                .insertContent(
                  '<p style="font-size:12px;color:#666"><a href="{{unsubscribe_url}}">Unsubscribe</a> · <a href="{{preferences_url}}">Preferences</a></p>',
                )
                .run()
            }
          >
            <span className="text-xs">Unsubscribe</span>
          </Tb>
          {mergeFields && mergeFields.length > 0 && (
            <select
              className="ml-auto h-8 rounded border border-border bg-background px-2 text-xs text-foreground"
              value=""
              aria-label="Personalise: insert the person's details"
              onChange={(e) => e.target.value && chain().insertContent(`{{${e.target.value}}}`).run()}
            >
              <option value="">Personalise…</option>
              {mergeFields.map((m) => (
                <option key={m.key} value={m.key}>
                  Insert {m.label.toLowerCase()}
                </option>
              ))}
            </select>
          )}
        </div>
      )}

      {!readOnly && sel?.link && (
        <div className="flex flex-wrap items-center gap-2 border-b border-border bg-primary-500/5 px-3 py-2 text-sm">
          <span className="min-w-0 flex-1 truncate text-secondary-700 dark:text-secondary-200">
            {sel.link.isButton ? 'Button goes to ' : 'Link goes to '}
            <span className="font-medium">{sel.link.href}</span>
          </span>
          {sel.link.isButton ? (
            <Button
              size="sm"
              variant="outline"
              leftIcon={<Pencil className="h-3.5 w-3.5" />}
              onClick={() => setButtonDialog({ ...currentButton(), editing: true })}
            >
              Edit button
            </Button>
          ) : (
            <Button
              size="sm"
              variant="outline"
              leftIcon={<Pencil className="h-3.5 w-3.5" />}
              onClick={() => void setLink()}
            >
              Change link
            </Button>
          )}
          {sel.link.isButton ? (
            <Button
              size="sm"
              variant="ghost"
              leftIcon={<Trash2 className="h-3.5 w-3.5" />}
              onClick={() => chain().extendMarkRange('link').deleteSelection().run()}
            >
              Remove button
            </Button>
          ) : (
            <Button size="sm" variant="ghost" leftIcon={<Unlink className="h-3.5 w-3.5" />} onClick={removeLink}>
              Remove link
            </Button>
          )}
        </div>
      )}

      {!readOnly && sel?.image && (
        <div className="flex flex-wrap items-center gap-2 border-b border-border bg-primary-500/5 px-3 py-2 text-sm">
          <span className="text-secondary-700 dark:text-secondary-200">Picture size:</span>
          {(
            [
              ['Small', '200px'],
              ['Medium', '400px'],
              ['Full width', '100%'],
            ] as [string, string][]
          ).map(([label, w]) => (
            <Button
              key={label}
              size="sm"
              variant={sel.image?.style.includes(`width:${w}`) ? 'primary' : 'outline'}
              onClick={() => imageWidth(w)}
            >
              {label}
            </Button>
          ))}
          <Button
            size="sm"
            variant="ghost"
            leftIcon={<Trash2 className="h-3.5 w-3.5" />}
            onClick={() => chain().deleteSelection().run()}
          >
            Remove picture
          </Button>
        </div>
      )}

      <div style={frameStyle(frame.open)}>
        <EditorContent editor={editor} />
      </div>

      {buttonDialog && (
        <ButtonDialog initial={buttonDialog} onSave={saveButton} onClose={() => setButtonDialog(null)} />
      )}
    </div>
  );
}
