---
title: Getting paid
pages: /dashboard/namespace/payment-methods
api: /api/v2/namespace/payment-methods
modules: namespace
tools:
suggestions: Add our Barclays business account | Which bank account is on our invoices? | Make the EUR account the default
readonly: false
---
# Getting paid
How this workspace gets paid: business bank accounts (bank transfer), card, cheque and other methods. The methods marked "Show on documents" are printed in a **How to pay** block on Order Authorisations (shop), bank-transfer shop orders and invoices; the customer is told to use the document number (OA/order number or invoice number) as the payment reference. Trade customers pay Order Authorisations by bank transfer.

## Using the page
- List of methods with a **Default** badge, kind, label, the bank details and switches for "Show on documents" and "Active".
- **Add payment method**: Kind (Bank transfer, Card, Cheque, Other), Label (e.g. "Barclays GBP business account"), and for a bank account: Account name*, Bank name, Sort code + Account number (UK) and/or IBAN + SWIFT/BIC, Currency (GBP default), Instructions (e.g. "Use the order number as the reference"). Sort codes are shown as 12-34-56; IBANs are checked as you type.
- **Set as default**, **Edit**, **Deactivate** / **Delete** on each row. A live preview shows the How to pay block exactly as customers will see it.

## Rules
- A bank account needs Account name and either sort code + account number or an IBAN. Sort code: 6 digits; account number: 6–10 digits; IBAN must pass its check digits; SWIFT/BIC 8 or 11 characters; currency a 3-letter code.
- One default per workspace. The first active method becomes the default automatically; deleting the default hands it to the next active one. An invoice without its own payment method prints the default bank account.
- Delete removes a method unless an invoice uses it, in which case it is only deactivated (kept for that invoice).
- Changing methods needs `namespace` update (owners always can). Anyone with namespace, invoices or shop read access can list them.
- Never invent bank details: ask the user for them and read them back before saving.

## API
- `GET /api/v2/namespace/payment-methods?include_inactive=true` — list (default first)
- `POST /api/v2/namespace/payment-methods {kind*: bank_transfer|card|cheque|other, label, account_name, bank_name, sort_code, account_number, iban, swift_bic, currency: GBP, instructions, is_default: bool, show_on_documents: bool (default true), is_active: bool (default true), sort_order: int}` — add
- `PUT /api/v2/namespace/payment-methods/{uuid} {same fields, partial}` — update (is_default: true makes it the default)
- `DELETE /api/v2/namespace/payment-methods/{uuid}` — delete (or deactivate when an invoice uses it)
