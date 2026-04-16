#!/usr/bin/env python3
"""Dedupe reference data in migration [47] using amount-banded strategy.

Strategy: Group by (description, category, hmrc_category, client_business_type,
user_profile_type, industry, transaction_type, amount_band). Keep first row per
group. Preserves amount variance while eliminating near-duplicates.

Amount bands:
  - small:  amount < 50
  - medium: 50 <= amount < 200
  - large:  amount >= 200

Usage:
    python3 scripts/dedupe_reference_data.py

Writes the deduped migration to stdout. To apply:
    python3 scripts/dedupe_reference_data.py > /tmp/migration_47_new.lua
    # then manually replace the [47] function body in tax-copilot-system.lua
"""

import re
import sys
from pathlib import Path

MIGRATION_FILE = Path(__file__).parent.parent / "lapis/migrations/tax-copilot-system.lua"

# Regex to match one INSERT row. Handles escaped quotes (''), dates, numbers.
# Captures each field in order.
ROW_PATTERN = re.compile(
    r"\(gen_random_uuid\(\)::text, "
    r"'((?:[^']|'')*)', "       # 1: description
    r"'((?:[^']|'')*)', "       # 2: description_raw
    r"([\d.]+), "               # 3: amount
    r"'([A-Z]+)', "             # 4: transaction_type
    r"'([\d-]+)', "             # 5: transaction_date
    r"'([a-z_]+)', "            # 6: category
    r"'([a-zA-Z]*)', "          # 7: hmrc_category
    r"([\d.]+), "               # 8: confidence
    r"(true|false), "           # 9: is_tax_deductible
    r"'((?:[^']|'')*)', "       # 10: reasoning
    r"'((?:[^']|'')*)', "       # 11: original_label
    r"'([a-z_]+)', "            # 12: client_business_type
    r"'([a-z_]+)', "            # 13: user_profile_type
    r"'([a-z_]+)', "            # 14: industry
    r"'([^']+)', "              # 15: source_file
    r"(\d+), "                  # 16: row_index
    r"(\d+), "                  # 17: namespace_id
    r"NOW\(\), NOW\(\)\)"
)


def amount_band(amount: float) -> str:
    if amount < 50:
        return "small"
    if amount < 200:
        return "medium"
    return "large"


def parse_migration():
    """Extract all INSERT rows from migration [47]."""
    content = MIGRATION_FILE.read_text()
    rows = []
    for m in ROW_PATTERN.finditer(content):
        rows.append({
            "description": m.group(1),
            "description_raw": m.group(2),
            "amount": float(m.group(3)),
            "transaction_type": m.group(4),
            "transaction_date": m.group(5),
            "category": m.group(6),
            "hmrc_category": m.group(7),
            "confidence": m.group(8),
            "is_tax_deductible": m.group(9),
            "reasoning": m.group(10),
            "original_label": m.group(11),
            "client_business_type": m.group(12),
            "user_profile_type": m.group(13),
            "industry": m.group(14),
            "source_file": m.group(15),
            "row_index": int(m.group(16)),
            "namespace_id": m.group(17),
        })
    return rows


def dedupe(rows):
    """Amount-banded dedup. Keep first row per (description, category, hmrc,
    business_type, profile_type, industry, txn_type, amount_band) group."""
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
    """Format a row as a Lua INSERT value tuple."""
    return (
        f"                (gen_random_uuid()::text, "
        f"'{row['description']}', "
        f"'{row['description_raw']}', "
        f"{row['amount']}, "
        f"'{row['transaction_type']}', "
        f"'{row['transaction_date']}', "
        f"'{row['category']}', "
        f"'{row['hmrc_category']}', "
        f"{row['confidence']}, "
        f"{row['is_tax_deductible']}, "
        f"'{row['reasoning']}', "
        f"'{row['original_label']}', "
        f"'{row['client_business_type']}', "
        f"'{row['user_profile_type']}', "
        f"'{row['industry']}', "
        f"'{row['source_file']}', "
        f"{row['row_index']}, "
        f"{row['namespace_id']}, NOW(), NOW())"
    )


def main():
    rows = parse_migration()
    sys.stderr.write(f"Parsed {len(rows)} rows from migration\n")

    deduped = dedupe(rows)
    sys.stderr.write(f"After amount-banded dedup: {len(deduped)} rows\n")
    sys.stderr.write(f"Reduction: {len(rows) - len(deduped)} rows removed "
                     f"({100 * (len(rows) - len(deduped)) // len(rows)}%)\n\n")

    # Summary by description + category
    from collections import Counter
    before = Counter((r["description"], r["category"]) for r in rows)
    after = Counter((r["description"], r["category"]) for r in deduped)
    sys.stderr.write("Top groups (before → after):\n")
    for (desc, cat), count in before.most_common(10):
        sys.stderr.write(f"  {desc:40} | {cat:25} | {count:3} → {after[(desc, cat)]}\n")

    # Sort output by (client_business_type, source_file, row_index) for readability
    deduped.sort(key=lambda r: (r["client_business_type"], r["source_file"], r["row_index"]))

    # Output the INSERT values
    print("-- AUTO-GENERATED by scripts/dedupe_reference_data.py")
    print(f"-- {len(deduped)} deduped rows (from {len(rows)} original)")
    print(f"-- Strategy: amount-banded dedup (small <£50, medium £50-200, large £200+)")
    print()
    for i, row in enumerate(deduped):
        line = format_row(row)
        if i < len(deduped) - 1:
            line += ","
        print(line)


if __name__ == "__main__":
    main()
