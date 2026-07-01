# Test Report — OpsAPI Dashboard

**Environment:** https://dev-opsapi-remote.fictionally.org/dashboard/
**Date:** 2026-07-01
**Tested by:** QA

---

## Summary

| # | Test Point | Status |
|---|------------|--------|
| 1 | HMRC is connected properly | ✅ Pass |
| 2 | Application page load time | ⚠️ Needs attention |
| 3 | All 6 steps work flawlessly | ✅ Pass |
| 4 | Transaction, Bank Account & Statements section present | ✅ Pass |
| 5 | Projects section — can add any project | ✅ Pass |
| 6 | Customers section — CRUD operations | ✅ Pass |

---

## 1. HMRC Connection

**Status:** ✅ Pass

- HMRC integration is connected properly.
- OAuth authorization completes and returns a valid session.
- Connection status displays as connected in the dashboard.

---

## 2. Application Page Load Time

**Status:** ⚠️ Needs attention

- The application takes too much time to load pages.
- Navigation between sections feels slow and impacts the user experience.
- **Recommendation:** Investigate and optimize page load performance (bundle size, API response times, caching).

---

## 3. Six-Step Wizard Flow

**Status:** ✅ Pass

- All 6 steps of the flow work flawlessly.
- Each step advances correctly without errors.
- Data is carried through the steps and submitted as expected.

---

## 4. Transaction, Bank Account & Statements

**Status:** ✅ Pass

- The Transaction section is present and accessible.
- The Bank Account section is present and accessible.
- The Statements section is present and accessible.

---

## 5. Projects Section

**Status:** ✅ Pass

- The Projects section is present and working.
- Any project can be added successfully.
- Newly created projects appear in the list as expected.

---

## 6. Customers Section (CRUD)

**Status:** ✅ Pass

- The Customers section is working fine.
- Create, Read, Update, and Delete operations all work correctly.
- Customer records persist and reflect changes accurately.

---

## Overall Conclusion

The application is functional — HMRC connectivity, the 6-step flow, and the
Transaction / Bank Account / Statements sections all work as expected. The main
issue to address is **slow page load times**, which should be prioritized for
performance optimization.
