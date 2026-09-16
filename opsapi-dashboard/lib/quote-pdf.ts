import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';
import type { FsJobDetail, FsJobItem } from '@/services/field-service.service';

// The "from" party printed at the top of the quote. Only the name is required.
export interface QuoteCompany {
  name: string;
  address?: string;
  email?: string;
  phone?: string;
  taxId?: string;
}

// ---- Palette (matches the invoice PDF for a consistent brand) ----
const NAVY: [number, number, number] = [15, 23, 42];
const ACCENT: [number, number, number] = [37, 99, 235];
const DARK: [number, number, number] = [30, 41, 59];
const MUTED: [number, number, number] = [100, 116, 139];
const FAINT: [number, number, number] = [148, 163, 184];
const LINE: [number, number, number] = [226, 232, 240];
const SOFT: [number, number, number] = [248, 250, 252];

const LABOUR_LABEL: Record<string, string> = {
  engineer_nt: 'Engineer — normal time',
  engineer_ot: 'Engineer — overtime',
  mate_nt: 'Mate — normal time',
  mate_ot: 'Mate — overtime',
};

const TYPE_LABEL: Record<string, string> = {
  labour: 'Labour',
  part: 'Material',
  material: 'Material',
  hire: 'Hire',
  expense: 'Expense',
  other: 'Other',
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
  if (parts.length === 0) return 'CO';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function plusDays(days: number): string {
  return new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10);
}

function quoteRef(job: FsJobDetail): string {
  return `QUO-${job.job_number || job.uuid.slice(0, 8)}`;
}

function quoteFileName(job: FsJobDetail): string {
  return `Quote-${job.job_number || job.uuid.slice(0, 8)}.pdf`;
}

/** One line as it should read in the Description column (kind-specific detail). */
function describe(it: FsJobItem): string {
  const bits: string[] = [];
  if (it.item_type === 'labour') {
    bits.push(LABOUR_LABEL[it.labour_category || ''] || 'Labour');
    if (it.days) bits.push(`${it.days} day(s)`);
    if (it.description) bits.push(it.description);
  } else {
    if (it.description) bits.push(it.description);
    if (it.part_number) bits.push(it.part_number);
    if (it.days) bits.push(`${it.days} day(s)`);
    if (it.supplier) bits.push(it.supplier);
  }
  return bits.filter(Boolean).join(' · ') || '—';
}

/**
 * Build the customer-facing quotation PDF from a job's quote-sheet lines
 * (labour / materials / hire). Pure client-side (jsPDF) — the same brand as the
 * invoice PDF, but framed as a pre-work estimate: quote ref, valid-until, an
 * "Estimated total", and no amount-due.
 */
function buildQuoteDoc(job: FsJobDetail, company: QuoteCompany): jsPDF {
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const pageH = doc.internal.pageSize.getHeight();
  const margin = 44;
  const right = pageW - margin;
  const currency = job.currency || 'GBP';

  // ---- Header band ----
  const bandH = 120;
  doc.setFillColor(...NAVY);
  doc.rect(0, 0, pageW, bandH, 'F');
  doc.setFillColor(...ACCENT);
  doc.rect(0, bandH, pageW, 4, 'F');

  const badgeCx = margin + 17;
  const badgeCy = 50;
  doc.setFillColor(...ACCENT);
  doc.circle(badgeCx, badgeCy, 17, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(13);
  doc.setTextColor(255, 255, 255);
  doc.text(initials(company.name), badgeCx, badgeCy + 4.5, { align: 'center' });

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

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(30);
  doc.setTextColor(255, 255, 255);
  doc.text('QUOTATION', right, 50, { align: 'right' });
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(11);
  doc.setTextColor(...FAINT);
  doc.text(`# ${quoteRef(job)}`, right, 70, { align: 'right' });

  // ---- Bill-to + meta ----
  const y = bandH + 36;
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  doc.text('PREPARED FOR', margin, y);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(13);
  doc.setTextColor(...DARK);
  doc.text(job.customer_name || 'Customer', margin, y + 18);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9.5);
  doc.setTextColor(...MUTED);
  let by = y + 34;
  for (const line of [job.customer_email, job.site_name, job.service_address]) {
    if (line) {
      doc.text(String(line), margin, by);
      by += 14;
    }
  }

  const metaLabelX = right - 190;
  const metaRows: [string, string][] = [
    ['Quote Date', today()],
    ['Valid Until', plusDays(30)],
    ['Job', job.job_number || '—'],
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

  // Job title as a sub-header for context.
  const titleY = Math.max(by, myy) + 8;
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(11);
  doc.setTextColor(...DARK);
  doc.text(job.title || 'Quotation', margin, titleY);

  // ---- Line items (labour / materials / hire, in that order) ----
  const order: Record<string, number> = { labour: 0, part: 1, material: 1, hire: 2, expense: 3, other: 4 };
  const items = (job.items || [])
    .filter((it) => it.is_billable !== false)
    .slice()
    .sort((a, b) => (order[a.item_type] ?? 9) - (order[b.item_type] ?? 9));

  let subtotal = 0;
  let taxTotal = 0;
  const body = items.map((it) => {
    const lineTotal = Number(it.line_total) || (Number(it.quantity) || 0) * (Number(it.unit_price) || 0);
    subtotal += lineTotal;
    taxTotal += lineTotal * ((Number(it.tax_rate) || 0) / 100);
    return [
      TYPE_LABEL[it.item_type] || 'Item',
      describe(it),
      (Number(it.quantity) || 0).toString(),
      money(Number(it.unit_price) || 0, currency),
      money(lineTotal, currency),
    ];
  });

  autoTable(doc, {
    startY: titleY + 12,
    margin: { left: margin, right: margin },
    head: [['Type', 'Description', 'Qty', 'Unit Price', 'Amount']],
    body: body.length ? body : [['', 'No lines added yet', '', '', '']],
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
      0: { cellWidth: 66, textColor: MUTED },
      1: { cellWidth: 'auto' },
      2: { halign: 'right', cellWidth: 46 },
      3: { halign: 'right', cellWidth: 84 },
      4: { halign: 'right', cellWidth: 84, fontStyle: 'bold' },
    },
  });

  // ---- Totals card ----
  const afterTable = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 18;
  const boxW = 250;
  const boxX = right - boxW;
  const total = subtotal + taxTotal;

  const rows: { label: string; value: string; strong?: boolean }[] = [
    { label: 'Subtotal', value: money(subtotal, currency) },
    { label: 'VAT', value: money(taxTotal, currency) },
  ];
  let ty = afterTable;
  for (const r of rows) {
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(10);
    doc.setTextColor(...MUTED);
    doc.text(r.label, boxX, ty + 8);
    doc.setTextColor(...DARK);
    doc.text(r.value, right, ty + 8, { align: 'right' });
    ty += 17;
  }

  // Estimated total — emphasized accent band.
  ty += 4;
  doc.setFillColor(...ACCENT);
  doc.roundedRect(boxX, ty, boxW, 30, 5, 5, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(11);
  doc.setTextColor(255, 255, 255);
  doc.text('Estimated Total', boxX + 12, ty + 19);
  doc.setFontSize(13);
  doc.text(money(total, currency), right - 12, ty + 19, { align: 'right' });

  // ---- Footer ----
  doc.setDrawColor(...LINE);
  doc.setLineWidth(0.5);
  doc.line(margin, pageH - 64, right, pageH - 64);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(9);
  doc.setTextColor(...DARK);
  doc.text('This is a quotation, not an invoice.', margin, pageH - 46);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  doc.text('Valid for 30 days from the quote date. Prices are estimates and may change if the scope of work changes.', margin, pageH - 34);
  doc.text(`${company.name || ''}`, right, pageH - 46, { align: 'right' });
  doc.text(quoteRef(job), right, pageH - 34, { align: 'right' });

  return doc;
}

/** Build the quote PDF and trigger a download. */
export function generateQuotePdf(job: FsJobDetail, company: QuoteCompany): void {
  buildQuoteDoc(job, company).save(quoteFileName(job));
}

/** Build the quote PDF and return an object URL for in-app preview. Caller owns
 *  the URL and must URL.revokeObjectURL() it when done. */
export function previewQuotePdfUrl(job: FsJobDetail, company: QuoteCompany): string {
  return URL.createObjectURL(buildQuoteDoc(job, company).output('blob'));
}

/** Build the quote PDF and return raw base64 (no data: prefix) + filename, for emailing. */
export function quotePdfBase64(job: FsJobDetail, company: QuoteCompany): { base64: string; filename: string } {
  const uri = buildQuoteDoc(job, company).output('datauristring');
  const marker = 'base64,';
  const idx = uri.indexOf(marker);
  return { base64: idx >= 0 ? uri.slice(idx + marker.length) : uri, filename: quoteFileName(job) };
}
