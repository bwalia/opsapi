---
title: Settings
pages: /dashboard/settings
api: /api/v2/users
modules: users
tools:
suggestions: Update my phone number | Change my address | How do I change my password?
readonly: false
---
# Settings
The signed-in user's personal account settings. Tabs: Profile, Notifications, Security, Appearance. Workspace-wide settings (members, roles, API keys, plugins, webhooks) are in My Workspace (/dashboard/namespace), not here.

## Using the page
- Profile: First Name, Last Name, Email Address, Phone Number, Address → Save Changes.
- Notifications: Email Notifications toggles (Order Updates, Product Alerts, Marketing Emails) and push toggles → Save Preferences. These choices are not stored on the server yet.
- Security: Change Password (Current Password, New Password, Confirm New Password → Update Password; you are signed out afterwards). Delete account → "Delete my account" asks for your password and deactivates the account. The user must do both themselves — never handle passwords or account deletion.
- Appearance: links to Themes (/dashboard/themes).

## Rules
- New password: at least 8 characters, must match the confirmation, current password required.
- Saving the profile needs the users "update" permission in this workspace; without it the save fails with 403 — suggest asking a workspace admin.
- On this page only ever update the CURRENT user's own record. Never change another user, never send `active`, never delete.
- Changing the email changes the login email.

## API
- `GET /api/v2/users/search?q=<the user's name or email>` — find the current user's uuid (needs users read)
- `PUT /api/v2/users/{uuid} {first_name, last_name, email, phone_no, address}` — update the profile (send only the fields being changed; at least one)
