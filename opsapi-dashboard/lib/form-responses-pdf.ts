import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';

/**
 * Form responses as a PDF: one block per response (heading, meta line, then a
 * question / answer table). Answers arrive already formatted as text by the
 * caller (FormResponses' showAnswer), so this file knows nothing about field types.
 */

export interface PdfResponse {
  heading: string;
  meta: string;
  answers: [string, string][];
}

type RGB = [number, number, number];
const DARK: RGB = [30, 41, 59];
const MUTED: RGB = [100, 116, 139];
const LINE: RGB = [226, 232, 240];
const SOFT: RGB = [248, 250, 252];

export function formPdfFilename(title: string, suffix = 'responses'): string {
  const slug = (title || 'form').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'form';
  return `${slug}-${suffix}-${new Date().toISOString().slice(0, 10)}.pdf`;
}

export function buildFormResponsesPdf(title: string, responses: PdfResponse[], subtitle?: string): jsPDF {
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const margin = 40;

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(16);
  doc.setTextColor(...DARK);
  doc.text(title || 'Form responses', margin, 50, { maxWidth: pageW - margin * 2 });
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9);
  doc.setTextColor(...MUTED);
  doc.text(subtitle || `${responses.length} response${responses.length === 1 ? '' : 's'} · exported ${new Date().toLocaleString()}`,
    margin, 66);

  let y = 88;
  responses.forEach((r, i) => {
    const pageH = doc.internal.pageSize.getHeight();
    if (i > 0 && y > pageH - 120) { doc.addPage(); y = 50; }
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(11);
    doc.setTextColor(...DARK);
    doc.text(r.heading, margin, y);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(8.5);
    doc.setTextColor(...MUTED);
    const meta = doc.splitTextToSize(r.meta, pageW - margin * 2) as string[];
    doc.text(meta, margin, y + 13);
    autoTable(doc, {
      startY: y + 13 + meta.length * 10,
      margin: { left: margin, right: margin },
      head: [['Question', 'Answer']],
      body: r.answers.length ? r.answers : [['—', 'No answers']],
      theme: 'grid',
      styles: { font: 'helvetica', fontSize: 9, cellPadding: 5, textColor: DARK, lineColor: LINE, lineWidth: 0.5, overflow: 'linebreak' },
      headStyles: { fillColor: SOFT, textColor: MUTED, fontStyle: 'bold' },
      columnStyles: { 0: { cellWidth: 170, textColor: MUTED } },
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 26;
  });

  const pages = doc.getNumberOfPages();
  for (let p = 1; p <= pages; p++) {
    doc.setPage(p);
    doc.setFontSize(8);
    doc.setTextColor(...MUTED);
    doc.text(`Page ${p} of ${pages}`, pageW - margin, doc.internal.pageSize.getHeight() - 20, { align: 'right' });
  }
  return doc;
}
