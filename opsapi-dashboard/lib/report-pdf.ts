import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';
import type { Report, ReportColumn } from '@/services/simpro-crm.service';

/**
 * Render any report from the Simpro report pack as a branded PDF.
 *
 * The server returns every report in one envelope (columns with a type, rows,
 * summary), so this single renderer covers the whole pack. The layout follows
 * the sample Simpro report DBS publish: company letterhead at the top, the
 * report body, and a footer carrying the address, company number and VAT
 * number on every page.
 */

export interface ReportCompany {
  name: string;
  legalName?: string;
  strapline?: string;
  address?: string;
  phone?: string;
  email?: string;
  companyNumber?: string;
  vatNumber?: string;
}

type RGB = [number, number, number];
const NAVY: RGB = [11, 37, 69];
const TEAL: RGB = [19, 168, 158];
const DARK: RGB = [30, 41, 59];
const MUTED: RGB = [100, 116, 139];
const LINE: RGB = [226, 232, 240];
const SOFT: RGB = [248, 250, 252];

const NUMERIC: ReportColumn['type'][] = ['number', 'money', 'hours'];

/** Pull the letterhead out of namespace settings (seeded as settings.company). */
export function companyFromNamespace(ns?: { name?: string; settings?: unknown } | null): ReportCompany {
  let settings: Record<string, unknown> = {};
  if (typeof ns?.settings === 'string') {
    try {
      settings = JSON.parse(ns.settings);
    } catch {
      settings = {};
    }
  } else if (ns?.settings && typeof ns.settings === 'object') {
    settings = ns.settings as Record<string, unknown>;
  }
  const c = (settings.company || {}) as Record<string, string | undefined>;
  return {
    name: c.display_name || ns?.name || 'Report',
    legalName: c.legal_name,
    strapline: c.strapline,
    address: c.address,
    phone: c.phone,
    email: c.email,
    companyNumber: c.company_number,
    vatNumber: c.vat_number,
  };
}

/** Format one cell the same way on screen, in the PDF and in tests. */
export function formatReportCell(value: unknown, type: ReportColumn['type']): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (type === 'money') {
    const n = Number(value);
    return isFinite(n)
      ? new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' }).format(n)
      : String(value);
  }
  if (type === 'number' || type === 'hours') {
    const n = Number(value);
    if (!isFinite(n)) return String(value);
    const text = n.toLocaleString('en-GB', { maximumFractionDigits: 2 });
    return type === 'hours' ? `${text} h` : text;
  }
  if (type === 'date' || type === 'datetime') {
    const raw = String(value);
    const iso = raw.includes('T') || raw.length <= 10 ? raw : `${raw.replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1')}Z`;
    const d = new Date(iso);
    if (isNaN(d.getTime())) return raw;
    return type === 'date' || raw.length <= 10
      ? d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
      : d.toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
  return String(value);
}

/** Human label for a summary key: "failure_rate_pct" -> "Failure rate %". */
export function summaryLabel(key: string): string {
  const text = key.replace(/_pct$/, ' %').replace(/_/g, ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** Summary values worth printing: scalars only (nested breakdowns stay on screen). */
export function summaryEntries(summary: Record<string, unknown>): [string, string][] {
  return Object.entries(summary)
    .filter(([, v]) => v !== null && v !== undefined && typeof v !== 'object')
    .map(([k, v]) => [summaryLabel(k), typeof v === 'number' ? v.toLocaleString('en-GB') : String(v)]);
}

export function buildReportPdf(report: Report, company: ReportCompany): jsPDF {
  // Wide reports (the Power BI extract has 29 columns) need landscape A3; the
  // rest read comfortably on landscape A4.
  const wide = report.columns.length > 14;
  const doc = new jsPDF({ orientation: 'landscape', unit: 'mm', format: wide ? 'a3' : 'a4' });
  const pageW = doc.internal.pageSize.getWidth();
  const pageH = doc.internal.pageSize.getHeight();
  const margin = 12;

  // ---- Letterhead ----
  doc.setFillColor(...NAVY);
  doc.rect(0, 0, pageW, 24, 'F');
  doc.setFillColor(...TEAL);
  doc.rect(0, 24, pageW, 1.6, 'F');
  doc.setTextColor(255, 255, 255);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(18);
  doc.text(company.name, margin, 12);
  if (company.strapline) {
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(8.5);
    doc.text(company.strapline, margin, 18.5);
  }
  doc.setFontSize(8.5);
  const contact = [company.phone && `Tel: ${company.phone}`, company.email].filter(Boolean).join('   ');
  if (contact) doc.text(contact, pageW - margin, 12, { align: 'right' });

  // ---- Title block ----
  let y = 36;
  doc.setTextColor(...DARK);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(15);
  doc.text(report.title, margin, y);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(9);
  doc.setTextColor(...MUTED);
  y += 5.5;
  doc.text(doc.splitTextToSize(report.description, pageW - margin * 2 - 70), margin, y);
  doc.text(`Generated ${formatReportCell(report.generated_at, 'datetime')}`, pageW - margin, 36, { align: 'right' });

  const filterText = Object.entries(report.filters || {})
    .filter(([, v]) => v !== null && v !== undefined && v !== '')
    .map(([k, v]) => `${summaryLabel(k)}: ${String(v)}`)
    .join('   ·   ');
  if (filterText) doc.text(filterText, pageW - margin, 41.5, { align: 'right' });
  y += 6;

  // ---- Asset card (asset history report) ----
  if (report.asset) {
    const a = report.asset as Record<string, unknown>;
    const pairs: [string, unknown][] = [
      ['Asset', `${a.asset_tag ?? ''} ${a.name ?? ''}`.trim()],
      ['Type', a.asset_type],
      ['Customer / site', [a.customer_name, a.site_name].filter(Boolean).join(' — ')],
      ['Make / model', [a.manufacturer, a.model].filter(Boolean).join(' ')],
      ['Serial', a.serial_number],
      ['Condition', a.condition_rating ? `${a.condition_rating} of 6` : null],
      ['Refrigerant', a.refrigerant_type ? `${a.refrigerant_type} · ${a.refrigerant_charge_kg ?? '?'} kg` : null],
      ['Contract', a.contract_name],
    ];
    autoTable(doc, {
      startY: y,
      body: pairs.filter(([, v]) => v).map(([k, v]) => [k, String(v)]),
      theme: 'plain',
      styles: { fontSize: 8.5, cellPadding: 1.2, textColor: DARK },
      columnStyles: { 0: { fontStyle: 'bold', cellWidth: 34, textColor: MUTED } },
      margin: { left: margin, right: margin },
      tableWidth: 150,
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 4;
  }

  // ---- Summary strip ----
  const summary = summaryEntries(report.summary || {});
  if (summary.length) {
    const cellW = Math.min(46, (pageW - margin * 2) / summary.length);
    doc.setDrawColor(...LINE);
    summary.forEach(([label, value], i) => {
      const x = margin + i * cellW;
      doc.setFillColor(...SOFT);
      doc.roundedRect(x, y, cellW - 2, 14, 1.5, 1.5, 'FD');
      doc.setFontSize(7);
      doc.setTextColor(...MUTED);
      doc.text(doc.splitTextToSize(label, cellW - 6)[0], x + 2.5, y + 4.8);
      doc.setFont('helvetica', 'bold');
      doc.setFontSize(11);
      doc.setTextColor(...NAVY);
      doc.text(value, x + 2.5, y + 11);
      doc.setFont('helvetica', 'normal');
    });
    y += 18;
  }

  // ---- Rows ----
  const columnStyles: Record<number, { halign: 'right' }> = {};
  report.columns.forEach((c, i) => {
    if (NUMERIC.includes(c.type)) columnStyles[i] = { halign: 'right' };
  });

  autoTable(doc, {
    startY: y,
    head: [report.columns.map((c) => c.label)],
    body: report.rows.map((row) => report.columns.map((c) => formatReportCell(row[c.key], c.type))),
    theme: 'grid',
    styles: { fontSize: wide ? 6.5 : 7.5, cellPadding: 1.6, textColor: DARK, lineColor: LINE, lineWidth: 0.1 },
    headStyles: { fillColor: NAVY, textColor: [255, 255, 255], fontStyle: 'bold' },
    alternateRowStyles: { fillColor: SOFT },
    columnStyles,
    margin: { left: margin, right: margin, bottom: 18 },
    didDrawPage: () => {
      // Footer on every page, as on DBS's own Simpro report pack.
      doc.setDrawColor(...LINE);
      doc.line(margin, pageH - 13, pageW - margin, pageH - 13);
      doc.setFontSize(7);
      doc.setTextColor(...MUTED);
      const legal = [
        company.legalName,
        company.address,
        company.companyNumber && `Company Registration No ${company.companyNumber}`,
        company.vatNumber && `VAT No ${company.vatNumber}`,
      ]
        .filter(Boolean)
        .join('  ·  ');
      if (legal) doc.text(legal, pageW / 2, pageH - 8.5, { align: 'center' });
      const page = doc.getCurrentPageInfo().pageNumber;
      doc.text(`Page ${page}`, pageW - margin, pageH - 4.5, { align: 'right' });
    },
  });

  if (!report.rows.length) {
    doc.setFontSize(10);
    doc.setTextColor(...MUTED);
    doc.text('No rows for these filters.', margin, y + 14);
  }

  return doc;
}

export function downloadReportPdf(report: Report, company: ReportCompany) {
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  buildReportPdf(report, company).save(`${report.key}-${stamp}.pdf`);
}
