import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';
import type { PurchaseOrder } from '@/services/purchase-orders.service';
import type { InvoiceCompany } from '@/lib/invoice-pdf';

// Same look as lib/invoice-pdf.ts (navy band, accent stripe, zebra table) so
// invoices and purchase orders from one workspace match.
const NAVY: [number, number, number] = [15, 23, 42];
const ACCENT: [number, number, number] = [37, 99, 235];
const DARK: [number, number, number] = [30, 41, 59];
const MUTED: [number, number, number] = [100, 116, 139];
const FAINT: [number, number, number] = [148, 163, 184];
const LINE: [number, number, number] = [226, 232, 240];
const SOFT: [number, number, number] = [248, 250, 252];

function money(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency || 'GBP' }).format(
      Number(amount) || 0
    );
  } catch {
    return `${currency} ${(Number(amount) || 0).toFixed(2)}`;
  }
}

function fileName(po: PurchaseOrder): string {
  return `PurchaseOrder-${po.po_number || po.uuid.slice(0, 8)}.pdf`;
}

function buildDoc(po: PurchaseOrder, company: InvoiceCompany): jsPDF {
  const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const pageH = doc.internal.pageSize.getHeight();
  const margin = 44;
  const right = pageW - margin;
  const currency = po.currency || 'GBP';

  // Header band
  const bandH = 110;
  doc.setFillColor(...NAVY);
  doc.rect(0, 0, pageW, bandH, 'F');
  doc.setFillColor(...ACCENT);
  doc.rect(0, bandH, pageW, 4, 'F');

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(19);
  doc.setTextColor(255, 255, 255);
  doc.text(company.name || 'Your Company', margin, 50);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8.5);
  doc.setTextColor(...FAINT);
  let hy = 68;
  for (const line of [company.address, company.email, company.phone]) {
    if (line) {
      doc.text(String(line), margin, hy);
      hy += 12;
    }
  }

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(24);
  doc.setTextColor(255, 255, 255);
  doc.text('PURCHASE ORDER', right, 50, { align: 'right' });
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(11);
  doc.setTextColor(...FAINT);
  doc.text(`# ${po.po_number || po.uuid.slice(0, 8)}`, right, 70, { align: 'right' });

  // Supplier (left) + meta (right)
  const y = bandH + 36;
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  doc.text('SUPPLIER', margin, y);
  doc.setFontSize(13);
  doc.setTextColor(...DARK);
  doc.text(po.supplier_name || 'Supplier', margin, y + 18);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9.5);
  doc.setTextColor(...MUTED);
  let by = y + 34;
  for (const line of [po.supplier_email, po.supplier_phone, po.supplier_address]) {
    if (line) {
      const wrapped = doc.splitTextToSize(String(line), 230);
      doc.text(wrapped, margin, by);
      by += 14 * wrapped.length;
    }
  }

  const metaX = right - 200;
  const metaRows: [string, string][] = [
    ['Issue Date', po.issue_date || '—'],
    ['Required By', po.expected_date || '—'],
  ];
  if (po.reference) metaRows.push(['Reference', po.reference]);
  let my = y;
  for (const [label, value] of metaRows) {
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9.5);
    doc.setTextColor(...MUTED);
    doc.text(label, metaX, my);
    doc.setFont('helvetica', 'bold');
    doc.setTextColor(...DARK);
    doc.text(String(value), right, my, { align: 'right' });
    my += 17;
  }
  if (po.delivery_address) {
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(8.5);
    doc.setTextColor(...MUTED);
    doc.text('DELIVER TO', metaX, my + 6);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9.5);
    doc.setTextColor(...DARK);
    const wrapped = doc.splitTextToSize(po.delivery_address, right - metaX);
    doc.text(wrapped, metaX, my + 20);
    my += 20 + 12 * wrapped.length;
  }

  autoTable(doc, {
    startY: Math.max(by, my) + 18,
    margin: { left: margin, right: margin },
    head: [['#', 'Description', 'Qty', 'Unit Price', 'Tax', 'Amount']],
    body: po.items.map((it, i) => [
      String(i + 1),
      it.description || '—',
      String(it.quantity),
      money(it.unit_price, currency),
      it.tax_rate ? `${it.tax_rate}%` : '—',
      money(it.line_total, currency),
    ]),
    styles: { font: 'helvetica', fontSize: 9.5, cellPadding: 9, textColor: DARK, lineColor: LINE, lineWidth: 0.5 },
    headStyles: { fillColor: NAVY, textColor: [255, 255, 255], fontStyle: 'bold', fontSize: 8.5 },
    bodyStyles: { lineColor: LINE, lineWidth: { top: 0, bottom: 0.5, left: 0, right: 0 } },
    alternateRowStyles: { fillColor: SOFT },
    columnStyles: {
      0: { cellWidth: 26, halign: 'center', textColor: MUTED },
      1: { cellWidth: 'auto' },
      2: { halign: 'right', cellWidth: 46 },
      3: { halign: 'right', cellWidth: 78 },
      4: { halign: 'right', cellWidth: 50 },
      5: { halign: 'right', cellWidth: 82, fontStyle: 'bold' },
    },
  });

  const afterTable = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 18;
  const boxW = 230;
  const boxX = right - boxW;
  let ty = afterTable;
  for (const [label, value] of [
    ['Subtotal', money(po.subtotal, currency)],
    ['Tax', money(po.tax_total, currency)],
  ]) {
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(10);
    doc.setTextColor(...MUTED);
    doc.text(label, boxX, ty + 8);
    doc.setTextColor(...DARK);
    doc.text(value, right, ty + 8, { align: 'right' });
    ty += 17;
  }
  doc.setFillColor(...ACCENT);
  doc.roundedRect(boxX, ty + 2, boxW, 30, 5, 5, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(11);
  doc.setTextColor(255, 255, 255);
  doc.text('Order Total', boxX + 12, ty + 21);
  doc.setFontSize(13);
  doc.text(money(po.total, currency), right - 12, ty + 21, { align: 'right' });

  let ny = afterTable + 8;
  for (const [label, text] of [
    ['NOTES', po.notes],
    ['TERMS', po.terms],
  ]) {
    if (!text) continue;
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(8.5);
    doc.setTextColor(...MUTED);
    doc.text(label as string, margin, ny);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9.5);
    doc.setTextColor(...DARK);
    const lines = doc.splitTextToSize(text as string, boxX - margin - 24);
    doc.text(lines, margin, ny + 15);
    ny += 30 + 12 * lines.length;
  }

  doc.setDrawColor(...LINE);
  doc.setLineWidth(0.5);
  doc.line(margin, pageH - 58, right, pageH - 58);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(9.5);
  doc.setTextColor(...DARK);
  doc.text('Please quote the PO number on your invoice and delivery note.', margin, pageH - 40);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(8.5);
  doc.setTextColor(...MUTED);
  doc.text(company.name || '', right, pageH - 40, { align: 'right' });
  doc.text(`Purchase Order ${po.po_number || ''}`, right, pageH - 28, { align: 'right' });

  return doc;
}

/** Build the PO PDF and trigger a download. */
export function generatePurchaseOrderPdf(po: PurchaseOrder, company: InvoiceCompany): void {
  buildDoc(po, company).save(fileName(po));
}

/** Same PDF as raw base64 (no data: prefix) + filename, for emailing. */
export function purchaseOrderPdfBase64(
  po: PurchaseOrder,
  company: InvoiceCompany
): { base64: string; filename: string } {
  const uri = buildDoc(po, company).output('datauristring');
  const idx = uri.indexOf('base64,');
  return { base64: idx >= 0 ? uri.slice(idx + 7) : uri, filename: fileName(po) };
}
