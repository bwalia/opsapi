#!/usr/bin/env python3
"""Re-import reference data from Numbers files + apply amount-banded dedup.

Reads the 4 source bank statement files (Client C + D used), maps the
accountant's category labels to our 61 system categories, cleans merchant
names, and applies amount-banded dedup.

Strategy: Group by (description, category, hmrc_category, client_business_type,
user_profile_type, industry, transaction_type, amount_band). Keep first row
per group. Amount bands: small (<£50), medium (£50-200), large (£200+).

Usage:
    python3 scripts/dedupe_reference_data.py > /tmp/new_migration_47.sql
"""

import re
import sys
from pathlib import Path
from collections import Counter
from datetime import datetime
from numbers_parser import Document

# ============================================================================
# Source files + profile mapping
# ============================================================================
SOURCES = [
    {
        "file": "/Users/sukhvirsingh/Downloads/Bank statements/For Client C.numbers",
        "source_file_label": "For Client C.numbers",
        "client_business_type": "amazon_seller",
        "user_profile_type": "sole_trader",
        "industry": "ecommerce",
        "reasoning_suffix": "for ecommerce business",
    },
    {
        "file": "/Users/sukhvirsingh/Downloads/Bank statements/For Client D.numbers",
        "source_file_label": "For Client D.numbers",
        "client_business_type": "construction_company",
        "user_profile_type": "limited_company",
        "industry": "construction",
        "reasoning_suffix": "for construction business",
    },
]

# ============================================================================
# Accountant category → (system_category, hmrc_category, is_tax_deductible)
# ============================================================================
CATEGORY_MAP = {
    # Purchases / cost of goods
    "purchase": ("purchases", "costOfGoods", True),
    "cost of sales": ("cost_of_sales", "costOfGoods", True),

    # Income
    "debtors": ("income_sales", "", False),
    "split income": ("income_sales", "", False),
    "refund": ("income_refund", "", False),
    "amazon refunds": ("income_refund", "", False),

    # Transfers (internal)
    "tax account": ("transfer", "", False),
    "lloyds bank trust account": ("transfer", "", False),
    "credit card": ("transfer", "", False),
    "creditors": ("transfer", "", False),

    # Loans
    "amazon loans": ("loan_repayments", "", False),
    "paragon loan": ("loan_repayments", "", False),
    "paragone": ("loan_repayments", "", False),
    "aldemore hp loan": ("loan_repayments", "", False),
    "federal capital loan": ("loan_repayments", "", False),
    "quantum loan": ("loan_repayments", "", False),
    "iwoca loan": ("loan_repayments", "", False),
    "bounce back loan": ("loan_repayments", "", False),
    "funding circle": ("loan_repayments", "", False),
    "investec asset": ("loan_repayments", "", False),
    "swishfund loan": ("loan_repayments", "", False),
    "equipment leasing": ("loan_repayments", "", False),

    # Directors / drawings / dividends
    "directors loan accounts": ("directors_loan_account", "", False),
    "director's current account": ("directors_loan_account", "", False),
    "owners drawings": ("drawings", "", False),
    "dividends": ("dividend_payments", "", False),

    # Tax
    "corporation tax": ("tax_payments", "", False),
    "paye and ni payable": ("employer_ni", "staffCosts", True),
    "paye and ni": ("employer_ni", "staffCosts", True),

    # Wages / staff
    "wages control": ("salaries_wages", "staffCosts", True),
    "salaries": ("salaries_wages", "staffCosts", True),
    "subcontracted services": ("subcontractors", "staffCosts", True),
    "staff training and welfare": ("staff_welfare", "staffCosts", True),
    "staff welfare": ("staff_welfare", "staffCosts", True),
    "staff training": ("training_expense", "adminCosts", True),
    "pensions": ("pension_expense", "staffCosts", True),

    # Travel
    "travel expense": ("travel_expense", "travelCosts", True),
    "travelling expenses": ("travel_expense", "travelCosts", True),
    "motor expenses": ("travel_expense", "travelCosts", True),
    "fuel": ("travel_expense", "travelCosts", True),
    "parking": ("travel_expense", "travelCosts", True),
    "auto": ("travel_expense", "travelCosts", True),

    # Professional fees
    "accountancy": ("accountancy_fees", "professionalFees", True),
    "legal and professional fees": ("legal_and_professional_fees", "professionalFees", True),
    "legal & professional fees": ("legal_and_professional_fees", "professionalFees", True),
    "professional fees": ("professional_fees", "professionalFees", True),

    # Office / admin
    "software": ("software_subscriptions", "adminCosts", True),
    "dues and subscriptions": ("dues_and_subscriptions", "adminCosts", True),
    "subscriptions": ("dues_and_subscriptions", "adminCosts", True),
    "telephone expense": ("telephone_expense", "adminCosts", True),
    "telephone": ("telephone_expense", "adminCosts", True),
    "printing and reproduction": ("printing_and_reproduction", "adminCosts", True),
    "postage and delivery": ("shipping_and_delivery", "adminCosts", True),
    "shipping, freight, and delivery": ("shipping_and_delivery", "adminCosts", True),
    "office expenses, repairs & maintenance": ("repair_and_maintenance", "maintenanceCosts", True),
    "office/general administrative expenses": ("general_admin_expenses", "adminCosts", True),
    "sundry": ("general_admin_expenses", "adminCosts", True),
    "sundry expenses": ("general_admin_expenses", "adminCosts", True),
    "equipment expensed": ("equipment_rental", "otherExpenses", True),

    # Other expenses
    "insurance": ("insurance_expense", "otherExpenses", True),
    "insurance expense": ("insurance_expense", "otherExpenses", True),
    "bank charges": ("bank_charges", "otherExpenses", True),
    "entertaining": ("meals_and_entertainment", "businessEntertainmentCosts", False),
    "meals and entertainment": ("meals_and_entertainment", "businessEntertainmentCosts", False),
    "charitable donations": ("charitable_contributions", "otherExpenses", False),
    "charitable contributions": ("charitable_contributions", "otherExpenses", False),

    # Split expense — internal money movement, treat as transfer
    "split expense": ("transfer", "", False),
}

# ============================================================================
# Merchant name cleaner (matches backend/app/services/merchant_cleaner.py logic)
# ============================================================================
_PREFIX_PATTERN = re.compile(
    r"^(?:VIS|BP|DD|SO|CR|FPI|BGC|FPO|TFR|DR|STO|DEB)\s+", re.IGNORECASE
)
_TRANSFER_PREFIX = re.compile(
    r"^TRANSFER\s+VIA\s+FASTER\s+PAYMENT\s+TO\s+", re.IGNORECASE
)
_DATE_PATTERNS = re.compile(
    r"\b\d{2}/\d{2}(?:/\d{2,4})?\b"
    r"|\b\d{2}(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\d{2,4}\b"
    r"|\b\d{4}-\d{2}-\d{2}\b",
    re.IGNORECASE,
)
_CARD_FRAGMENT = re.compile(r"\s+CD\s+\d{4}\b", re.IGNORECASE)
_REF_MANDATE = re.compile(
    r"\s*\bREF\s*[:;]?\s*.*$"
    r"|\s*\bMANDATE\s+NO\s*[:;]?\s*\w+.*$",
    re.IGNORECASE,
)
_ASTERISK_REF = re.compile(r"\*([A-Z0-9]{5,})\b", re.IGNORECASE)
_TRAILING_DIGITS = re.compile(r"\s+\d{7,}\s*$")
_L_REF = re.compile(r"\s+L\s+REF\b.*$", re.IGNORECASE)
_CORP_SUFFIX = re.compile(
    r"\s+(?:LTD|PLC|LIMITED|LLP|INC|CORP|CO)\s*\.?\s*$", re.IGNORECASE
)


def clean_merchant(description: str) -> str:
    if not description or not description.strip():
        return ""
    original = description.strip().upper()
    text = description.strip()
    text = _TRANSFER_PREFIX.sub("", text)
    text = _PREFIX_PATTERN.sub("", text)
    text = _ASTERISK_REF.sub("", text)
    text = text.replace("*", " ")
    text = _CARD_FRAGMENT.sub("", text)
    text = _DATE_PATTERNS.sub("", text)
    text = _L_REF.sub("", text)
    text = _REF_MANDATE.sub("", text)
    text = _TRAILING_DIGITS.sub("", text)
    text = _CORP_SUFFIX.sub("", text)
    text = re.sub(r"\s*,\s*$", "", text)
    text = re.sub(r"^\s*,\s*", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if text else original


def extract_category(added_or_matched: str) -> tuple[str, str] | tuple[None, None]:
    """Extract (prefix, accountant_category) from the 'ADDED OR MATCHED' column."""
    if not added_or_matched:
        return (None, None)
    val = str(added_or_matched).strip()
    # Order matters: more specific prefixes first (e.g., "Tax Payment:" before "Payment:")
    for prefix in ['Credit Card Payment:', 'Bill Payment:', 'Tax Payment:',
                   'Journal Entry:', 'Expense:', 'Payment:', 'Transfer:', 'Deposit:']:
        if prefix in val:
            after = val.split(prefix, 1)[1].strip()
            # Remove trailing date + amount
            cat_name = re.sub(r'\d{1,2}/\d{1,2}/\d{4}.*$', '', after).strip()
            cat_name = re.sub(r'£[\d,]+\.?\d*$', '', cat_name).strip()
            return (prefix.rstrip(':').strip(), cat_name)
    return (None, None)


def map_category(prefix: str, accountant_cat: str) -> tuple[str, str, bool] | None:
    """Map (prefix, accountant_category) to (system_key, hmrc_key, is_deductible) or None to skip."""
    if prefix is None:
        return None
    key = accountant_cat.lower().strip() if accountant_cat else ""

    # Special handling for specific prefixes
    if prefix == "Credit Card Payment":
        return ("transfer", "", False)
    if prefix == "Tax Payment":
        # HMRC tax payments, regardless of subcategory
        return ("tax_payments", "", False)
    if prefix == "Journal Entry":
        # Split income entries
        if "split income" in key:
            return ("income_sales", "", False)
        return ("transfer", "", False)
    if prefix == "Bill Payment":
        # Bill payments with unmapped subcategory (e.g., "Split expense") → transfer
        pass  # fall through to keyword matching, else default below

    # Debtors/Creditors by prefix
    if prefix in ("Payment", "Deposit") and key == "debtors":
        return ("income_sales", "", False)
    if prefix == "Payment" and key == "creditors":
        return ("transfer", "", False)
    if prefix == "Deposit":
        # Deposits not explicitly mapped above → treat as income_refund
        for substr, result in CATEGORY_MAP.items():
            if substr in key and result[0]:
                # If mapped, convert expense→income for deposits
                return ("income_refund", "", False)
        return ("income_refund", "", False)

    # Direct key lookup
    if key in CATEGORY_MAP:
        result = CATEGORY_MAP[key]
        return result if result[0] is not None else None

    # Fuzzy substring match (for named loans, etc.)
    for substr, result in CATEGORY_MAP.items():
        if substr in key or key in substr:
            return result if result[0] is not None else None

    # Prefix-based fallbacks for unmapped subcategories
    if prefix in ("Bill Payment", "Transfer"):
        # Unmapped bill payments and transfers → treat as transfer (safest for
        # internal money movements like "Loan from Vicky", "Split expense")
        return ("transfer", "", False)
    if prefix == "Payment":
        return ("transfer", "", False)
    if prefix == "Expense":
        return ("uncategorised_expense", "otherExpenses", True)

    return None  # unmappable → skip


def amount_band(amount: float) -> str:
    if amount < 50:
        return "small"
    if amount < 200:
        return "medium"
    return "large"


def parse_date(raw: str) -> str:
    """Parse DD/MM/YYYY or YYYY-MM-DD to YYYY-MM-DD."""
    if not raw:
        return ""
    s = str(raw).strip()
    # Already ISO
    if re.match(r"\d{4}-\d{2}-\d{2}", s):
        return s[:10]
    # DD/MM/YYYY
    m = re.match(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        d, mn, y = m.groups()
        return f"{y}-{int(mn):02d}-{int(d):02d}"
    return ""


def escape_sql(s: str) -> str:
    """Escape single quotes for SQL string literal."""
    return (s or "").replace("'", "''")


def parse_numbers_file(src: dict) -> list[dict]:
    """Parse a Numbers file and return a list of cleaned transaction dicts."""
    doc = Document(src["file"])
    table = doc.sheets[0].tables[0]
    headers = [str(table.cell(0, c).value).strip() if table.cell(0, c).value else ""
               for c in range(table.num_cols)]

    # Find column indices
    def idx(name_substr: str) -> int | None:
        for i, h in enumerate(headers):
            if name_substr.lower() in h.lower():
                return i
        return None

    date_col = idx("date")
    desc_col = idx("description")
    amount_col = idx("amount")
    payee_col = idx("payee")
    cat_col = None
    for i, h in enumerate(headers):
        hl = h.lower()
        if "added" in hl or "matched" in hl or "posted" in hl:
            cat_col = i
            break

    rows = []
    skipped = Counter()
    for r in range(1, table.num_rows):
        date_raw = table.cell(r, date_col).value if date_col is not None else None
        desc_raw = table.cell(r, desc_col).value if desc_col is not None else None
        amount_raw = table.cell(r, amount_col).value if amount_col is not None else None
        payee_raw = table.cell(r, payee_col).value if payee_col is not None else None
        cat_raw = table.cell(r, cat_col).value if cat_col is not None else None

        if not desc_raw or amount_raw is None:
            skipped["missing_desc_or_amount"] += 1
            continue

        # Extract and map category
        prefix, acc_cat = extract_category(str(cat_raw) if cat_raw else "")
        mapping = map_category(prefix, acc_cat)
        if mapping is None:
            skipped[f"unmapped_{prefix}_{acc_cat[:30] if acc_cat else 'none'}"] += 1
            continue
        system_cat, hmrc_cat, is_deductible = mapping

        try:
            amount = float(str(amount_raw))
        except (ValueError, TypeError):
            skipped["invalid_amount"] += 1
            continue

        transaction_type = "CREDIT" if amount > 0 else "DEBIT"
        amount_abs = abs(amount)

        # Clean description — prefer Payee if available and non-empty
        raw_desc = str(desc_raw).strip()
        if payee_raw and str(payee_raw).strip():
            raw_desc = str(payee_raw).strip()
        cleaned = clean_merchant(raw_desc)
        if not cleaned:
            skipped["empty_after_clean"] += 1
            continue

        # Original label for the reasoning text
        original_label = acc_cat if acc_cat else "Other"

        rows.append({
            "description": cleaned,
            "description_raw": str(desc_raw).strip(),
            "amount": round(amount_abs, 2),
            "transaction_type": transaction_type,
            "transaction_date": parse_date(date_raw) or "2025-01-01",
            "category": system_cat,
            "hmrc_category": hmrc_cat,
            "confidence": "1.0000",
            "is_tax_deductible": "true" if is_deductible else "false",
            # reasoning stored unescaped — escape_sql is applied in format_row
            "reasoning": f"Accountant classified as '{original_label}' {src['reasoning_suffix']}",
            "original_label": original_label,
            "client_business_type": src["client_business_type"],
            "user_profile_type": src["user_profile_type"],
            "industry": src["industry"],
            "source_file": src["source_file_label"],
            "row_index": r,
            "namespace_id": 0,
        })

    return rows, skipped


def dedupe(rows: list[dict]) -> list[dict]:
    """Amount-banded dedup."""
    seen = {}
    for row in rows:
        key = (
            row["description"].lower().strip(),
            row["category"],
            row["hmrc_category"],
            row["client_business_type"],
            row["user_profile_type"],
            row["industry"],
            row["transaction_type"],
            amount_band(row["amount"]),
        )
        if key not in seen:
            seen[key] = row
    return list(seen.values())


def format_row(row: dict) -> str:
    """Format a row as a Lua INSERT value tuple. Escapes single quotes for SQL."""
    return (
        f"                (gen_random_uuid()::text, "
        f"'{escape_sql(row['description'])}', "
        f"'{escape_sql(row['description_raw'])}', "
        f"{row['amount']}, "
        f"'{row['transaction_type']}', "
        f"'{row['transaction_date']}', "
        f"'{row['category']}', "
        f"'{row['hmrc_category']}', "
        f"{row['confidence']}, "
        f"{row['is_tax_deductible']}, "
        f"'{escape_sql(row['reasoning'])}', "
        f"'{escape_sql(row['original_label'])}', "
        f"'{row['client_business_type']}', "
        f"'{row['user_profile_type']}', "
        f"'{row['industry']}', "
        f"'{escape_sql(row['source_file'])}', "
        f"{row['row_index']}, "
        f"{row['namespace_id']}, NOW(), NOW())"
    )


def main():
    all_rows = []
    all_skipped = Counter()
    for src in SOURCES:
        rows, skipped = parse_numbers_file(src)
        sys.stderr.write(f"{src['client_business_type']}: parsed {len(rows)} rows, "
                         f"skipped {sum(skipped.values())}\n")
        all_rows.extend(rows)
        all_skipped.update(skipped)

    sys.stderr.write(f"\nTotal parsed: {len(all_rows)} rows\n")
    sys.stderr.write(f"Total skipped: {sum(all_skipped.values())}\n")

    # Show top skip reasons
    if all_skipped:
        sys.stderr.write("\nTop skip reasons:\n")
        for reason, count in all_skipped.most_common(15):
            sys.stderr.write(f"  {count:4d}  {reason}\n")

    deduped = dedupe(all_rows)
    sys.stderr.write(f"\nAfter dedup: {len(deduped)} rows "
                     f"(reduction: {len(all_rows) - len(deduped)})\n")

    # Per-profile count
    by_profile = Counter(r["client_business_type"] for r in deduped)
    sys.stderr.write("\nPer profile:\n")
    for profile, count in by_profile.most_common():
        sys.stderr.write(f"  {profile}: {count}\n")

    # Sort for readable output
    deduped.sort(key=lambda r: (r["client_business_type"], r["source_file"], r["row_index"]))

    # Output
    print(f"-- AUTO-GENERATED by scripts/dedupe_reference_data.py")
    print(f"-- {len(deduped)} deduped rows (from {len(all_rows)} parsed, "
          f"{sum(all_skipped.values())} skipped as unmappable)")
    print(f"-- Strategy: amount-banded dedup (small <£50, medium £50-200, large £200+)")
    print(f"-- Source: Client C (amazon_seller) + Client D (construction_company) Numbers files")
    print()
    for i, row in enumerate(deduped):
        line = format_row(row)
        if i < len(deduped) - 1:
            line += ","
        print(line)


if __name__ == "__main__":
    main()
