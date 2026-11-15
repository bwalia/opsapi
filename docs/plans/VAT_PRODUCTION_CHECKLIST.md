# VAT (MTD) production go-live checklist (VAT plan phase 7)

Filing real VAT returns needs HMRC's approval. Production refuses to file until `VAT_FILING_ENABLED=true` is set in `values-workstation-prod.yaml`, and that stays `false` until everything below is done.

**Owner:** steps marked **(you)** need the HMRC Developer Hub account holder. Steps marked **(code)** are in this repository.

## 1. Sandbox evidence (before applying)

- **(code)** Every VAT endpoint has been called in the sandbox and works:
  - obligations;
  - submit return;
  - view return;
  - liabilities;
  - payments;
  - penalties.

  The end-to-end test on int files a return through the VAT page with an organisation test user from `/hmrc-test-users`.
- **(code)** Fraud-prevention headers are sent on every call (`helper/hmrc.lua` `build_fraud_headers`) and pass HMRC's *Test Fraud Prevention Headers* API for the WEB_APP_VIA_SERVER connection method. Re-run the validator with a VAT call before applying.
- **(you)** In the sandbox application, subscribe to **VAT (MTD)** and to *Test Fraud Prevention Headers*.

## 2. Production application (you)

1. Developer Hub → your production application → **Add API: VAT (MTD)**. This starts HMRC's checks for the VAT API.
2. Fill in HMRC's production questionnaire: software name, what it does, how fraud headers are collected, and the connection method (WEB_APP_VIA_SERVER).
3. HMRC reviews the sandbox usage and may ask for:
   - screenshots of the VAT screen: obligations, the 9 boxes, the declaration and the receipt;
   - logs of each endpoint call;
   - error handling (the runbook has the cases).
4. Once approved, HMRC enables production credentials for VAT on the application.

## 3. Production configuration (code + you)

- **(you)** Put the production `HMRC_CLIENT_ID` and `HMRC_CLIENT_SECRET` in Vault (the existing ExternalSecret). Never put them in a values file.
- **(code)** `HMRC_ENVIRONMENT=production` already switches the VAT client to `api.service.hmrc.gov.uk` and stops sending `Gov-Test-Scenario` (covered by `spec/hmrc-vat-client_spec.lua`).
- **(code)** `HMRC_SERVER_PUBLIC_IP` must be set, for the `Gov-Vendor-Public-IP` header.
- **(code)** In production, filing checks that the period is open at HMRC (obligations), which the sandbox doesn't require.

## 4. Switch on

1. Set `VAT_FILING_ENABLED: "true"` in `values-workstation-prod.yaml` and deploy.
2. File one real return for a business that has agreed to be first, then compare our figures with HMRC's copy on the VAT page.
3. Watch the alerts `VatReturnNotFiled` and `VatFilingMostlyFailing`.

To switch off again, set `"false"` and deploy. Drafts are kept, and nothing filed is affected.

## 5. Recognised software listing (you)

After approval, apply for the HMRC list of software compatible with MTD for VAT, with product name, contact and pricing.
