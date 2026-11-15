# UK e-invoicing: readiness and tracking

Status of OpsAPI against the UK's mandatory B2B/B2G e-invoicing (VAT plan phase 11,
`docs/plans/VAT_MTD.md`). Update the "Guidance log" whenever HMRC publishes something.

## What OpsAPI does now

| | |
|---|---|
| Format | UBL 2.1, Peppol BIS Billing 3.0 (EN 16931 core invoice, `InvoiceTypeCode` 380) |
| Out | `GET /api/v2/vat/invoices/:uuid/einvoice` builds the XML from an issued invoice; `?check=1` returns the rule check |
| In | `POST /api/v2/vat/einvoice/import { xml, record? }` checks a supplier's invoice, maps VAT categories to our codes, and (workspace VAT) records it as pending expenses with the VAT coded |
| Check | `POST /api/v2/vat/einvoice/check { xml }` — a subset of the EN 16931 and Peppol rules (below) |
| Storage | `vat_einvoice_documents`: every document in/out, its XML, check result and status (`generated`, `received`, `recorded`, `rejected`, `sent`), de-duplicated by seller VAT id + invoice number |
| Code | `lapis/lib/vat-einvoice.lua`, `lapis/queries/VatEinvoiceQueries.lua`, spec `lapis/spec/vat-einvoice_spec.lua` |

Electronic addresses: the seller's is Peppol EAS `9932` (UK VAT number); the buyer's is
`9932` when they have a UK VAT number, otherwise `EM` (email).

VAT categories: STD20/RED5 → `S`, ZERO → `Z`, EXEMPT → `E`, OUTSIDE → `O`,
RC_SERVICES/RC_CIS → `AE`, NI_EU_GOODS → `K`, MARGIN → `E` with `VATEX-EU-F`. Reading back,
`AE` from a UK supplier is CIS reverse charge, from abroad reverse charge on services.

Rules checked: PEPPOL-EN16931-R003/R004/R007/R010/R020; BR-02..BR-07, BR-09, BR-11..BR-16,
BR-22..BR-27; BR-CO-04, -09, -10, -13..-18; BR-S-02, BR-S-05, BR-x-05 (0% categories),
BR-x-08 (taxable per category), BR-x-10 (exemption reasons), BR-AE-02.

## Not done yet (on purpose)

- **Full XSD and Schematron validation.** We check the business rules above, not the UBL
  schema or the full Peppol Schematron. Before going live, run documents through the
  official Peppol validator (or bundle the Schematron) in CI.
- **Sending/receiving through a Peppol access point.** The documents table is the outbox and
  inbox; a connector to a certified access point (and an SMP lookup of the buyer) is the
  next step once the UK operating model is final.
- Credit notes (UBL `CreditNote`), invoice-level allowances/charges, and non-GBP VAT
  amounts (`TaxCurrencyCode`).
- Any HMRC reporting/clearance: the first UK phase isn't expected to include it.

## Guidance log

| Date | What | Action |
|---|---|---|
| Nov 2025 | Budget: mandatory e-invoicing for VAT B2B/B2G invoices from April 2029 | Phase 11 planned |
| 2026 (reported) | Peppol confirmed as the core interoperability network | Built on Peppol BIS 3.0 |
| Oct 2026 (reported) | Implementation roadmap: single 1 April 2029 start; first phase without clearance or real-time reporting | Check the primary gov.uk roadmap and record the detail here |

The 2026 entries come from secondary sources (KPMG, vendor summaries); confirm against the
gov.uk publications before relying on them.
