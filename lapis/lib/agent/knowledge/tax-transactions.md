---
title: Tax transactions
pages: /dashboard/tax/transactions
api: /api/v2/tax/transactions, /api/v2/tax/categories, /api/v2/tax/bank-accounts, /api/v2/tax/statements
modules: tax_categories
tools:
suggestions: Show my pending transactions | Recategorise Amazon payments as office supplies | Mark the Tesco payments as personal
readonly: false
---
# Tax transactions
Every line from the user's bank statements. Each row has a `category` (tax category key, e.g. office_supplies), an `hmrc_category` (HMRC box key, e.g. telephone_office) and a `classification_status`: PENDING (not classified), CLASSIFIED (AI), NEEDS_REVIEW (AI, flagged), CONFIRMED (user checked). Only CLASSIFIED and CONFIRMED rows with an hmrc_category go into the HMRC return.

## Using the page
- Cards: Total Income, Total Expenses, Pending Classification, Total Records.
- Filters: "Search transactions..." (description), All Types / Income (Credit) / Expense (Debit), All Status / Confirmed / Pending / Modified. Click Date, Description, Amount, Category or Confirmed headers to sort.
- Click a Category cell → searchable picker; choosing saves at once.
- "Confirmed" Yes/No button toggles: No → CONFIRMED, Yes → PENDING.
- Red ⚠ = a credit (money in) in an expense category; HMRC rejects these. "Fix" offers Business income (sales / turnover), Other business income, Personal / transfer — exclude. A red banner counts them on the page.

## Rules
- {uuid} is the transaction `uuid` from the list.
- `category` must be an existing key from GET /api/v2/tax/categories (never the display name).
- When changing category also send the matching hmrc_category and classification_status CONFIRMED (as Fix does); category alone keeps the old HMRC box. Find the box by reusing hmrc_category from a row already in that category (`GET /api/v2/tax/transactions?category={key}&limit=1`), else the table below.
- Personal / non-business: category personal_expense (transfer = between own accounts, drawings = owner withdrawals), hmrc_category "" (excluded from the return), is_tax_deductible false.
- A CREDIT must not sit in an expense category: use sales_income + turnover, income_other + other_income, or transfer + "".
- classification_status filter accepts only PENDING, CONFIRMED, MODIFIED (others are ignored and return everything). For NEEDS_REVIEW/CLASSIFIED rows use sort_by=classification_status or the statement's transactions.
- Confirm only rows the user asked about. Never change transaction_date, description or amount.
- Before updating more than 5 rows, list them and ask the user to confirm.
- amount_min/amount_max compare the absolute amount.

hmrc_category → example category keys:
- turnover: sales_income, consulting_income
- other_income: income_other, interest_income, refund_income, rental_income
- cost_of_goods: inventory_stock, materials_supplies, cost_of_sales
- car_van_travel: vehicle_fuel, vehicle_maintenance, vehicle_insurance, travel_transport, mileage
- wages_staff: salaries_wages, subcontractors, employer_ni, pension_contributions, staff_welfare
- rent_rates: rent_business, business_rates, utilities, premises_insurance
- repairs_maintenance: repairs_property, equipment_repairs
- accountancy_legal: accountancy_fees, legal_fees, professional_fees
- interest_finance: bank_charges, loan_interest, finance_charges
- telephone_office: telephone, internet, software_subscriptions, office_supplies, postage_delivery, shipping_and_delivery, printing_and_reproduction, general_admin_expenses
- other_expenses: marketing_advertising, website_costs, training_courses, professional_memberships, business_insurance, uncategorised_expense
- Other box keys: advertising_marketing, subcontractor_payments, entertainment_costs, bad_debts, depreciation. use_of_home (home_office) and capital_allowances (equipment_purchase) are not in the period return.

## API
- `GET /api/v2/tax/transactions?page&limit&search&transaction_type=CREDIT|DEBIT&category={key}&hmrc_category={key}&classification_status=PENDING|CONFIRMED|MODIFIED&is_tax_deductible=true|false&amount_min&amount_max&date_from&date_to&bank_account_uuid&statement_uuid&sort_by=transaction_date|amount|description|category|classification_status|confidence_score|bank_name&sort_order=ASC|DESC` — rows in `items` (+ total, total_pages); limit max 100, default 25; dates YYYY-MM-DD
- `GET /api/v2/tax/transactions/summary` — total_transactions, total_income, total_expenses, pending_classification
- `GET /api/v2/tax/transactions/categories` — category and hmrc_category keys in use, with counts
- `GET /api/v2/tax/transactions/{uuid}` — one row (llm_response = AI reasoning)
- `GET /api/v2/tax/transactions/{uuid}/history` — change history
- `PUT /api/v2/tax/transactions/{uuid} {category, hmrc_category, classification_status: CONFIRMED|PENDING, is_tax_deductible: bool, user_notes, change_reason}` — send only fields to change
- `GET /api/v2/tax/categories` — data[]: key, name, category_type income|expense, is_deductible, is_global
- `GET /api/v2/tax/bank-accounts` — find an account's uuid (`id`) by bank_name
- `GET /api/v2/tax/statements?search` — find a statement's uuid (`id`) by file or bank name
