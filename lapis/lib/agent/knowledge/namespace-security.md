---
title: API Keys & Vault
pages: /dashboard/namespace/api-keys, /dashboard/namespace/vault
api:
modules: namespace
tools:
suggestions: How do I create an API key for a script? | What is a personal access token? | How do I unlock my vault?
readonly: true
---
# API Keys & Secret Vault
Guide only: on these pages the assistant explains how things work but never creates, reads, reveals, rotates or revokes keys or secrets. Never ask the user to paste a key, vault key or secret into the chat; if they do, tell them not to and to rotate it.

## API keys (/dashboard/namespace/api-keys)
- Machine credentials for scripts and services. A key is sent as `Authorization: Bearer opsk_…` and can only do what its scopes (permissions) allow, inside this workspace.
- Managing keys needs `namespace` manage (owners have it). An API key can never manage keys, and keys cannot be granted the `namespace` module.
- **Create API key** -> "Create API key" page: Name (a label, not secret, e.g. blog-importer), optional member binding — bound to a member it becomes a **personal access token** that acts as that person and is limited to what they can access; leave empty for a plain machine key. **Permissions**: tick module actions (search box filters modules). **Expiry (optional)** date, not in the past. Then **Create key**.
- "Your new API key" is shown only once — copy it then; it cannot be viewed again. Lost it? Revoke it and create a new one.
- The list shows name, key prefix, Personal badge, scopes, last used, expiry and Active/Revoked. **Revoke key** (confirm "Revoke") stops it working immediately.
- Errors you may see: "Give the key a name", "Grant at least one permission", "Expiry cannot be in the past".

## Secret vault (/dashboard/namespace/vault)
- A personal, encrypted vault per user per workspace. Everything is encrypted with a **vault key** the user chooses; it is never stored and cannot be recovered — if it is lost, the secrets are lost.
- First visit: "Create Your Vault Key" — Vault Name (Optional), Vault Key (16 characters): exactly 16 characters with at least one letter and one number, then Confirm Vault Key.
- Later visits: "Unlock Your Vault" with the vault key. 5 wrong attempts lock the vault ("Vault Locked"); try again later.
- Unlocked: folders on the left (Add folder, rename, delete), secret list with type filter and **Add Secret** (Name, value, URL, Username, Description), click a secret to view or copy, **Share Secret** with other members (optional expiry), **Logs** (access log), **Lock Vault**.
- **Providers** -> /dashboard/namespace/vault/providers ("External Providers"): **Connect Provider** (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, Kubernetes, .env file), **Sync Now** per provider, **Import .env**, **Export .env**.

## Rules
- Do not call any API from these pages.
- Do not describe or guess key formats beyond the `opsk_` prefix, and never output secret values.
