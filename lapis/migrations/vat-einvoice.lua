--[[
    E-invoicing readiness (VAT plan phase 11).
    1. vat_einvoice_documents: every e-invoice we produce (out) or receive (in), as
       UBL XML with its validation result. Ready to hand to a Peppol access point
       once the UK model is final; inbound documents are de-duplicated by
       (namespace, direction, document_id = seller VAT id + invoice number).
    Key zz_vat_schemes_6_* sorts after zz_vat_records_*; still checks its tables. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_einvoice_documents (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                namespace_id INTEGER NOT NULL,
                registration_id INTEGER,
                direction VARCHAR(3) NOT NULL CHECK (direction IN ('out', 'in')),
                format VARCHAR(30) NOT NULL DEFAULT 'ubl-peppol-bis3',
                document_id VARCHAR(255) NOT NULL,
                invoice_id BIGINT,
                invoice_number VARCHAR(255),
                issue_date DATE,
                party_name VARCHAR(255),
                party_vat_id VARCHAR(30),
                currency VARCHAR(3),
                total NUMERIC(15,2),
                vat_total NUMERIC(15,2),
                valid BOOLEAN NOT NULL DEFAULT false,
                validation JSONB,
                status VARCHAR(12) NOT NULL DEFAULT 'generated'
                    CHECK (status IN ('generated', 'received', 'recorded', 'rejected', 'sent')),
                expense_ids JSONB,
                xml TEXT NOT NULL,
                created_by INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_vat_einvoice_documents_doc
            ON vat_einvoice_documents (namespace_id, direction, document_id)]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_vat_einvoice_documents_ns
            ON vat_einvoice_documents (namespace_id, created_at DESC)]])
    end,
}
