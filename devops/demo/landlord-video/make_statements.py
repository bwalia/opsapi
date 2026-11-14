"""Invented 2025-26 bank statements for a 100-property landlord (80 houses via letting
agents, 20 commercial units on quarterly leases). Same layout as the Northbridge
fixtures that int's extractor already reads.

usage: venv/bin/python make_statements.py <out dir>
"""
import calendar
import json
import random
import sys
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
rng = random.Random(2526)

# (year, month) for the 2025-26 tax year; April starts on the 6th.
MONTHS = [(2025, m) for m in range(4, 13)] + [(2026, m) for m in range(1, 4)]

AGENTS = [  # name, houses, average monthly rent, fee rate incl. VAT
    ("HARTWELL LETTINGS RENT REMITTANCE", 30, 1050, 0.12),
    ("OAKRIDGE ESTATES RENT REMITTANCE", 28, 960, 0.12),
    ("BRAMLEY HOMES RENT REMITTANCE", 22, 1640, 0.108),
]

# 20 commercial tenants: name, annual rent, quarterly cycle (months they pay in).
CYCLE_A, CYCLE_B, CYCLE_C = (6, 9, 12, 3), (4, 7, 10, 1), (5, 8, 11, 2)
COMMERCIAL = [
    ("BRIGHTSIDE DENTAL LTD", 48000, CYCLE_A), ("KESTREL COFFEE CO", 21600, CYCLE_A),
    ("NORTHGATE PHYSIO CLINIC", 26400, CYCLE_A), ("ALDERMAN ACCOUNTANTS LLP", 39600, CYCLE_A),
    ("CROWN STREET VETS LTD", 57600, CYCLE_A), ("HOLLOWAY BARBERS", 14400, CYCLE_A),
    ("SILVERLINE OPTICIANS LTD", 31200, CYCLE_A),
    ("PINEWOOD NURSERY LTD", 66000, CYCLE_B), ("RIVERSIDE TYRES LTD", 34800, CYCLE_B),
    ("ORCHARD TRADE COUNTER LTD", 72000, CYCLE_B), ("BAYLIS PRINT WORKS", 28800, CYCLE_B),
    ("ELM COURT SOLICITORS", 44400, CYCLE_B), ("TEMPLE YOGA STUDIO", 16800, CYCLE_B),
    ("FERNHILL FOOD HALL", 52800, CYCLE_B),
    ("STATION ROAD CAFE", 18000, CYCLE_C), ("MARSHALL ELECTRICAL SUPPLIES", 42000, CYCLE_C),
    ("QUAYSIDE STORAGE LTD", 60000, CYCLE_C), ("ABBEY LANE BAKERY", 19200, CYCLE_C),
    ("GREENWAY CYCLES LTD", 25200, CYCLE_C), ("WESTFIELD PHARMACY LTD", 38400, CYCLE_C),
]

MORTGAGES = [  # name, monthly payment (interest + capital), day
    ("BIRCHWOOD BUILDING SOCIETY BTL MORTGAGE", 16850.00, 1),
    ("KINGSMEAD BTL MORTGAGE", 13420.00, 3),
    ("HARROWGATE LENDING BTL MORTGAGE", 11780.00, 5),
    ("CASTLEFORD COMMERCIAL MORTGAGE", 14960.00, 8),
]

REPAIRS = [  # name, low, high
    ("PLUMBFAST LTD BOILER REPAIR", 280, 2400), ("SPARKWELL ELECTRICAL EICR", 180, 950),
    ("GASSAFE CERTIFICATES LTD", 240, 1300), ("ROOFLINE REPAIRS LTD", 450, 3800),
    ("CLEARVIEW WINDOWS LTD", 320, 2900), ("DAMPGUARD SOLUTIONS", 600, 3400),
    ("GREENSWARD GARDEN MAINTENANCE", 150, 720), ("KEYSTONE LOCKSMITHS", 95, 380),
    ("BRIGHTCOAT DECORATORS", 900, 4200), ("ACE APPLIANCE REPAIRS", 120, 640),
]

ONE_OFFS = {  # (year, month): [(day, desc, out, in)]
    (2025, 5): [(19, "ELMHURST EPC ASSESSMENTS", 1140.00, None)],
    (2025, 7): [(31, "HMRC SELF ASSESSMENT PAYMENT", 96400.00, None)],
    (2025, 8): [(14, "LANDLORD LAW SOLICITORS POSSESSION", 2650.00, None)],
    (2025, 10): [(9, "BIRMINGHAM CITY COUNCIL BUS RATES", 1386.00, None),
                 (22, "HM LAND REGISTRY", 30.00, None)],
    (2025, 11): [(9, "BIRMINGHAM CITY COUNCIL BUS RATES", 1386.00, None)],
    (2026, 1): [(30, "HMRC SELF ASSESSMENT PAYMENT", 168250.00, None)],
    (2026, 2): [(17, "CLEARVIEW WINDOWS LTD NEW KITCHEN", 7850.00, None)],
}
QUARTERLY_COSTS = {  # month: [(day, desc, low, high)]
    6: [(20, "HARBOUR BLOCK MGMT SERVICE CHARGE", 3600, 3600), (26, "ASHFORD & PARTNERS ACCOUNTANTS", 1850, 1850)],
    9: [(19, "HARBOUR BLOCK MGMT SERVICE CHARGE", 3600, 3600), (25, "ASHFORD & PARTNERS ACCOUNTANTS", 1850, 1850)],
    12: [(19, "HARBOUR BLOCK MGMT SERVICE CHARGE", 3600, 3600), (22, "ASHFORD & PARTNERS ACCOUNTANTS", 1850, 1850)],
    3: [(20, "HARBOUR BLOCK MGMT SERVICE CHARGE", 3600, 3600), (26, "ASHFORD & PARTNERS ACCOUNTANTS", 1850, 1850)],
}


def money(v):
    return f"£{v:,.2f}"


def month_rows(year, month):
    first = 6 if (year, month) == (2025, 4) else 1
    last = calendar.monthrange(year, month)[1]
    day = lambda d: max(first, min(d, last))
    rows = []
    for name, payment, d in MORTGAGES:
        rows.append((day(d), name, payment, None))
    rows.append((day(2), "LANDLORD INSURANCE DIRECT DEBIT", 2140.00, None))
    rows.append((day(4), "PROPDESK SOFTWARE SUBSCRIPTION", 189.00, None))
    # letting agents remit on the 27th-29th, net of fees and with some houses empty
    for i, (name, houses, avg, fee) in enumerate(AGENTS):
        voids = rng.choice([0, 1, 1, 2, 3])
        gross = round((houses - voids) * avg * rng.uniform(0.985, 1.015), 2)
        rows.append((day(27 + i), name, None, round(gross * (1 - fee), 2)))
    # commercial tenants pay their quarter in advance on the 24th/25th
    for j, (name, annual, cycle) in enumerate(COMMERCIAL):
        if month in cycle:
            rows.append((day(rng.choice([20, 21, 22, 23, 24, 25])), f"{name} QTR RENT", None, round(annual / 4, 2)))
    for nm, lo, hi in rng.sample(REPAIRS, rng.choice([2, 2, 3])):
        rows.append((day(rng.randint(6, 26)), nm, round(rng.uniform(lo, hi), 2), None))
    if rng.random() < 0.5:
        rows.append((day(rng.randint(8, 20)), "OCTOPUS ENERGY VOID PROPERTY", round(rng.uniform(60, 240), 2), None))
    if rng.random() < 0.35:
        rows.append((day(rng.randint(8, 20)), "LEEDS CITY COUNCIL CTAX VOID", round(rng.uniform(140, 320), 2), None))
    for d, desc, lo, hi in QUARTERLY_COSTS.get(month, []):
        rows.append((day(d), desc, float(lo), None))
    for d, desc, out, inn in ONE_OFFS.get((year, month), []):
        rows.append((day(d), desc, out, inn))
    rows.append((day(15), "TESCO GROCERIES", round(rng.uniform(140, 320), 2), None))
    rows.append((day(30), "TRANSFER TO PERSONAL ACCOUNT", 15000.00, None))
    rows.sort(key=lambda r: (r[0], r[2] is None))
    return rows


def draw(path, year, month, rows, opening):
    W, H = A4
    c = canvas.Canvas(str(path), pagesize=A4)
    y = lambda top: H - top
    mname = calendar.month_name[month]
    c.setFont("Helvetica-Bold", 16)
    c.drawCentredString(W / 2, y(60), "NORTHBRIDGE DEMO BANK")
    c.setFont("Helvetica-Bold", 13)
    c.drawString(38.4, y(90), "SYNTHETIC TEST DOCUMENT — NOT A REAL BANK STATEMENT")
    c.setFont("Helvetica", 10)
    for i, line in enumerate([
        "Account holder: Jordan Ashby",
        "Account number: TEST-ACCOUNT-7310",
        "Sort code: 00-00-00",
        f"Statement period: {mname} {year}",
        "Test scenario: UK landlord, 80 let houses via agents and 20 commercial units.",
    ]):
        c.drawString(38.4, y(118 + 12 * i), line)
    bal = opening
    for _, _, out, inn in rows:
        bal += (inn or 0) - (out or 0)
    receipts = sum(r[3] or 0 for r in rows)
    c.drawString(38.4, y(188), f"Opening balance: {money(opening)} Closing balance: {money(bal)}")
    c.drawString(38.4, y(200), f"Money in this month: {money(receipts)}")
    c.setFont("Helvetica-Bold", 8)
    c.drawString(57.12, y(224), "Date")
    c.drawString(118.32, y(224), "Description")
    c.drawRightString(353.92, y(224), "Money out (£)")
    c.drawRightString(431.39, y(224), "Money in (£)")
    c.drawRightString(510.2, y(224), "Balance (£)")
    c.setFont("Helvetica", 8)
    bal = opening
    for i, (d, desc, out, inn) in enumerate(rows):
        top = 244 + 20 * i
        bal += (inn or 0) - (out or 0)
        c.drawString(57.12, y(top), f"{d:02d}/{month:02d}/{year}")
        c.drawString(118.32, y(top + 1), desc)
        c.drawRightString(353.92, y(top), money(out) if out else "—")
        c.drawRightString(431.39, y(top), money(inn) if inn else "—")
        c.drawRightString(510.2, y(top), money(bal))
    c.setFont("Helvetica", 7)
    top = 244 + 20 * len(rows) + 20
    c.drawString(38.4, y(top), "Synthetic data for software testing. Names, tenants and amounts are invented.")
    c.save()
    return bal


bal, summary = 185000.00, []
for (yr, mo) in MONTHS:
    rows = month_rows(yr, mo)
    assert len(rows) <= 27, (yr, mo, len(rows))
    path = OUT / f"ashby_property_{yr}_{mo:02d}_{calendar.month_name[mo].lower()}.pdf"
    opening = bal
    bal = draw(path, yr, mo, rows, opening)
    summary.append({"file": path.name, "rows": len(rows),
                    "in": round(sum(r[3] or 0 for r in rows), 2), "out": round(sum(r[2] or 0 for r in rows), 2),
                    "closing": round(bal, 2), "min_balance_ok": bal > 0})
json.dump(summary, open(OUT / "summary.json", "w"), indent=1)
tot_rows = sum(s["rows"] for s in summary)
print(f"{len(summary)} statements, {tot_rows} transactions, money in £{sum(s['in'] for s in summary):,.2f}, "
      f"money out £{sum(s['out'] for s in summary):,.2f}, closing £{bal:,.2f}")
for s in summary:
    print(s["file"], s["rows"], f"in £{s['in']:,.0f}", f"out £{s['out']:,.0f}", f"bal £{s['closing']:,.0f}")
