---
title: Customers
pages: /dashboard/customers
api: /api/v2/customers
modules: customers
tools: create_customer, list_customers, find_customer
suggestions: Add a customer | Find a customer by email | Mark a customer as tax exempt
readonly: false
---
# Customers
The workspace's customer database (people you sell to or bill). Each customer has an email, name, phone, addresses, tags, notes, marketing preferences and an account status (`state`): enabled | disabled | invited | declined. Order stats (orders_count, total_spent, last_order_date) are filled in by orders and are read-only.

## Using the page
- **Add Customer** (shown only with customers.create) opens "Add New Customer": Email Address (required), First/Last Name, Phone, Date of Birth, an address (Address Line 1/2, City, State / Province, Country, Postal / ZIP Code), Tags (comma-separated), Notes, and an accepts-marketing checkbox.
- Table columns: Customer, Contact, Location (first address), Joined. The search box only filters the current page; use find_customer to search all customers.
- Click a row (or the edit icon) to open `/dashboard/customers/{uuid}`: summary cards Orders, Total spent, Last order; sections Basic information, Primary address, Preferences & notes (Tags, Account status, Marketing opt-in level, Notes, checkboxes Accepts marketing / Email verified / Tax exempt). Buttons **Save changes** and **Delete**.

## Rules
- Permissions (module `customers`): list/view needs read, Add needs create, Save needs update, Delete needs delete. Members without them get 403.
- `email` is required and must be a valid address (DB check). The create_customer tool does not enforce this — always collect an email first.
- UI validation: first/last name at least 2 characters if given; date of birth not in the future; postal code ≤ 20 chars.
- `addresses` is replaced as a whole on update: GET the customer, edit its array, send the full array back. Keep the primary address first with `is_default: true`.
- `tags` is one comma-separated string, e.g. "vip, wholesale".
- Delete is permanent (hard delete).
- Only available when the e-commerce module is deployed; otherwise these routes return 404.

## API
- `GET /api/v2/customers?page&perPage&orderBy=created_at|updated_at|first_name|last_name|email|phone&orderDir=asc|desc` — perPage default 10; no server-side search (use find_customer)
- `GET /api/v2/customers/{uuid}`
- `POST /api/v2/customers {email*, first_name, last_name, phone, date_of_birth: YYYY-MM-DD, addresses: [{address1, address2, city, province, country, zip, is_default: true}], notes, tags: "a, b", accepts_marketing: boolean}`
- `PUT /api/v2/customers/{uuid} {any of: email, first_name, last_name, phone, date_of_birth, addresses (full array), notes, tags, accepts_marketing, verified_email, tax_exempt (booleans), marketing_opt_in_level: single_opt_in|confirmed_opt_in|unknown, state: enabled|disabled|invited|declined}`
- `DELETE /api/v2/customers/{uuid}`
