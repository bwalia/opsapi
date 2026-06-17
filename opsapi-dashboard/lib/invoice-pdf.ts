import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';
import type { Invoice } from '@/services/invoices.service';

// The "from" party printed at the top of the invoice. Name is required (the
// namespace name); the rest are optional and omitted from the header when absent.
export interface InvoiceCompany {
  name: string;
  address?: string;
  email?: string;
  phone?: string;
  taxId?: string;
}

// Optional extra customer detail the Invoice type doesn't formally declare but
// the backend may carry through (customer_address).
type InvoiceWithAddress = Invoice & { customer_address?: string | null };

// ---- Palette ----
const NAVY: [number, number, number] = [15, 23, 42]; // header band
const ACCENT: [number, number, number] = [37, 99, 235]; // primary-600
const DARK: [number, number, number] = [30, 41, 59]; // body text
const MUTED: [number, number, number] = [100, 116, 139]; // secondary-500
const FAINT: [number, number, number] = [148, 163, 184]; // on-navy subtext
const LINE: [number, number, number] = [226, 232, 240]; // hairlines
const SOFT: [number, number, number] = [248, 250, 252]; // zebra / card bg
const ACCENT_SOFT: [number, number, number] = [219, 234, 254]; // blue-100 highlight

const STATUS_COLORS: Record<string, [number, number, number]> = {
  draft: [100, 116, 139],
  sent: [37, 99, 235],
  paid: [22, 163, 74],
  partially_paid: [202, 138, 4],
  overdue: [220, 38, 38],
  cancelled: [100, 116, 139],
  void: [100, 116, 139],
};

function money(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency || 'GBP' }).format(
      Number(amount) || 0
    );
  } catch {
    return `${currency} ${(Number(amount) || 0).toFixed(2)}`;
  }
}

function initials(name: string): string {
  const parts = (name || '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return 'IN';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function invoiceFileName(invoice: InvoiceWithAddress): string {
  return `Invoice-${invoice.invoice_number || invoice.uuid.slice(0, 8)}.pdf`;
}

/**
 * Build the polished, professional invoice PDF document (no I/O).
 * Pure client-side (jsPDF) — crisp vector text, no server tooling required.
 * The namespace/company name is featured in a branded header band up top.
 */
function buildInvoiceDoc(invoice: InvoiceWithAddress, company: InvoiceCompany): jsPDF {
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const pageH = doc.internal.pageSize.getHeight();
  const margin = 44;
  const right = pageW - margin;
  const currency = invoice.currency || 'GBP';

  // ============================================================
  // Header band (branded) — namespace name + INVOICE
  // ============================================================
  const bandH = 120;
  doc.setFillColor(...NAVY);
  doc.rect(0, 0, pageW, bandH, 'F');
  // Accent stripe along the bottom of the band.
  doc.setFillColor(...ACCENT);
  doc.rect(0, bandH, pageW, 4, 'F');

  // Monogram badge.
  const badgeCx = margin + 17;
  const badgeCy = 50;
  doc.setFillColor(...ACCENT);
  doc.circle(badgeCx, badgeCy, 17, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(13);
  doc.setTextColor(255, 255, 255);
  doc.text(initials(company.name), badgeCx, badgeCy + 4.5, { align: 'center' });

  // Company / namespace name + contact lines.
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(19);
  doc.setTextColor(255, 255, 255);
  doc.text(company.name || 'Your Company', margin + 44, 50);

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8.5);
  doc.setTextColor(...FAINT);
  let hy = 70;
  for (const line of [company.address, company.email, company.phone, company.taxId ? `Tax ID: ${company.taxId}` : undefined]) {
    if (line) {
      doc.text(String(line), margin + 44, hy);
      hy += 12;
    }
  }

  // INVOICE title + number (right side of the band).
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(30);
  doc.setTextColor(255, 255, 255);
  doc.text('INVOICE', right, 50, { align: 'right' });
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(11);
  doc.setTextColor(...FAINT);
  doc.text(`# ${invoice.invoice_number || invoice.uuid.slice(0, 8)}`, right, 70, { align: 'right' });

  // Status pill (right, inside band).
  const statusColor = STATUS_COLORS[invoice.status] || MUTED;
  const statusLabel = (invoice.status || 'draft').replace('_', ' ').toUpperCase();
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(8.5);
  const pillW = doc.getTextWidth(statusLabel) + 18;
  doc.setFillColor(...statusColor);
  doc.roundedRect(right - pillW, 82, pillW, 17, 8.5, 8.5, 'F');
  doc.setTextColor(255, 255, 255);
  doc.text(statusLabel, right - pillW / 2, 93.5, { align: 'center' });

  // ============================================================
  // Bill-to + meta row
  // ============================================================
  const y = bandH + 36;

  // Bill To (left).
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  doc.text('BILLED TO', margin, y);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(13);
  doc.setTextColor(...DARK);
  doc.text(invoice.customer_name || 'Customer', margin, y + 18);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9.5);
  doc.setTextColor(...MUTED);
  let by = y + 34;
  for (const line of [invoice.customer_email, invoice.customer_address]) {
    if (line) {
      doc.text(String(line), margin, by);
      by += 14;
    }
  }

  // Meta (right): issue date, due date.
  const metaLabelX = right - 190;
  const metaRows: [string, string][] = [
    ['Issue Date', invoice.issue_date || '—'],
    ['Due Date', invoice.due_date || '—'],
  ];
  let myy = y;
  for (const [label, value] of metaRows) {
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9.5);
    doc.setTextColor(...MUTED);
    doc.text(label, metaLabelX, myy);
    doc.setFont('helvetica', 'bold');
    doc.setTextColor(...DARK);
    doc.text(String(value), right, myy, { align: 'right' });
    myy += 17;
  }
  // Amount Due call-out (right, emphasized).
  doc.setFillColor(...ACCENT_SOFT);
  doc.roundedRect(metaLabelX - 12, myy - 2, right - metaLabelX + 12, 30, 5, 5, 'F');
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9);
  doc.setTextColor(...MUTED);
  doc.text('Amount Due', metaLabelX, myy + 13);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(13);
  doc.setTextColor(...ACCENT);
  doc.text(money(invoice.balance_due, currency), right - 8, myy + 14, { align: 'right' });

  // ============================================================
  // Line items
  // ============================================================
  const items = invoice.items || [];
  autoTable(doc, {
    startY: Math.max(by, myy + 44) + 10,
    margin: { left: margin, right: margin },
    head: [['#', 'Description', 'Qty', 'Unit Price', 'Tax', 'Amount']],
    body: items.map((it, i) => [
      String(i + 1),
      it.description || '—',
      (Number(it.quantity) || 0).toString(),
      money(Number(it.unit_price) || 0, currency),
      money(Number(it.tax_amount) || 0, currency),
      money(Number(it.total) || 0, currency),
    ]),
    styles: { font: 'helvetica', fontSize: 9.5, cellPadding: 9, textColor: DARK, lineColor: LINE, lineWidth: 0.5 },
    headStyles: {
      fillColor: NAVY,
      textColor: [255, 255, 255],
      fontStyle: 'bold',
      fontSize: 8.5,
      cellPadding: { top: 8, bottom: 8, left: 9, right: 9 },
    },
    bodyStyles: { lineColor: LINE, lineWidth: { top: 0, bottom: 0.5, left: 0, right: 0 } },
    alternateRowStyles: { fillColor: SOFT },
    columnStyles: {
      0: { cellWidth: 26, halign: 'center', textColor: MUTED },
      1: { cellWidth: 'auto' },
      2: { halign: 'right', cellWidth: 46 },
      3: { halign: 'right', cellWidth: 78 },
      4: { halign: 'right', cellWidth: 64 },
      5: { halign: 'right', cellWidth: 82, fontStyle: 'bold' },
    },
  });

  // ============================================================
  // Totals card (right) + notes (left)
  // ============================================================
  const afterTable = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 18;
  const boxW = 250;
  const boxX = right - boxW;

  const rows: { label: string; value: string; strong?: boolean }[] = [
    { label: 'Subtotal', value: money(invoice.subtotal, currency) },
    { label: 'Tax', value: money(invoice.tax_total, currency) },
    { label: 'Total', value: money(invoice.total, currency), strong: true },
    { label: 'Amount Paid', value: money(invoice.amount_paid, currency) },
  ];

  let ty = afterTable;
  for (const r of rows) {
    if (r.strong) {
      doc.setDrawColor(...LINE);
      doc.setLineWidth(0.5);
      doc.line(boxX, ty - 5, right, ty - 5);
    }
    doc.setFont('helvetica', r.strong ? 'bold' : 'normal');
    doc.setFontSize(r.strong ? 11 : 10);
    doc.setTextColor(...(r.strong ? DARK : MUTED));
    doc.text(r.label, boxX, ty + 8);
    doc.setTextColor(...DARK);
    doc.text(r.value, right, ty + 8, { align: 'right' });
    ty += r.strong ? 22 : 17;
  }

  // Balance Due — emphasized accent band.
  ty += 2;
  doc.setFillColor(...ACCENT);
  doc.roundedRect(boxX, ty, boxW, 30, 5, 5, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(11);
  doc.setTextColor(255, 255, 255);
  doc.text('Balance Due', boxX + 12, ty + 19);
  doc.setFontSize(13);
  doc.text(money(invoice.balance_due, currency), right - 12, ty + 19, { align: 'right' });

  // Notes (left, aligned with the totals top).
  if (invoice.notes) {
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(8.5);
    doc.setTextColor(...MUTED);
    doc.text('NOTES', margin, afterTable + 8);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9.5);
    doc.setTextColor(...DARK);
    const noteLines = doc.splitTextToSize(invoice.notes, boxX - margin - 24);
    doc.text(noteLines, margin, afterTable + 23);
  }

  // ============================================================
  // Footer
  // ============================================================
  doc.setDrawColor(...LINE);
  doc.setLineWidth(0.5);
  doc.line(margin, pageH - 58, right, pageH - 58);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(9.5);
  doc.setTextColor(...DARK);
  doc.text('Thank you for your business.', margin, pageH - 40);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  const terms = invoice.payment_terms_days ? `Payment terms: net ${invoice.payment_terms_days} days` : '';
  if (terms) doc.text(terms, margin, pageH - 28);
  doc.text(`${company.name || ''}`, right, pageH - 40, { align: 'right' });
  doc.text(`Invoice ${invoice.invoice_number || ''}`, right, pageH - 28, { align: 'right' });

  return doc;
}

/** Build the invoice PDF and trigger a download. */
export function generateInvoicePdf(invoice: InvoiceWithAddress, company: InvoiceCompany): void {
  buildInvoiceDoc(invoice, company).save(invoiceFileName(invoice));
}

/**
 * Build the invoice PDF and return an object URL for in-app preview (e.g. an
 * <iframe>). Caller owns the URL and must URL.revokeObjectURL() it when done.
 */
export function previewInvoicePdfUrl(invoice: InvoiceWithAddress, company: InvoiceCompany): string {
  const blob = buildInvoiceDoc(invoice, company).output('blob');
  return URL.createObjectURL(blob);
}
