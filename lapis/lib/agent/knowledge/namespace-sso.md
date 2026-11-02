---
title: Single sign-on (SAML)
pages: /dashboard/namespace/sso
api:
modules: namespace
tools:
suggestions: How do I connect Okta? | What do I give my identity provider? | Why can't someone sign in with SSO?
readonly: true
---
# Single sign-on (SAML 2.0)
Guide only: explain how to set up and troubleshoot SAML; never create, change or delete providers, and never ask for or repeat certificates or private keys.

## Using the page
- **Add identity provider**: give it a Name, then either paste the IdP's metadata XML and press **Fill in from metadata**, or enter the IdP entity ID (Issuer), the IdP sign-in URL (HTTP-Redirect binding) and the IdP signing certificate by hand.
- **Email domains** (at least one required): only addresses at these domains can sign in through the provider.
- **Verify each domain**: the provider card shows a TXT record (name `_opsapi-challenge.<domain>`, value `opsapi-verify=…`) for each domain. Add it at the domain's DNS provider, then press **Check now**. Until a domain shows Verified, nobody at it can sign in with SSO and the login page doesn't offer the provider for it. This stops another workspace claiming your domain and signing in as your people.
- **Role for new members**: a role name in this workspace (e.g. member, viewer). Empty uses the workspace's default role.
- **Create accounts on first sign-in** (auto-provision): on by default; off means people must be invited first.
- **Allow IdP-initiated sign-in**: off by default; turn on to let people start from the IdP's app tile.
- Each provider card shows what to give the IdP: Metadata URL, Entity ID (Audience), ACS URL (Reply URL) and a direct sign-in link.
- Viewing needs `namespace` read; adding, editing, deleting and checking domains need `namespace` manage (workspace owners). Every change is in the workspace audit log.
- Two-factor is up to your identity provider: an SSO sign-in doesn't ask for OpsAPI's emailed code.

## IdP settings to use
- NameID format: email address. Attributes: email, firstName, lastName (other names can be mapped in the provider).
- Sign the SAML response or assertion with RSA-SHA256 (SHA-1 is refused). Do not encrypt assertions.

## Why a sign-in fails
- "Accounts at <domain> can't sign in with this provider": the email domain is not in Email domains.
- "Single sign-on isn't ready for <domain> yet": the domain isn't verified; add the TXT record on the provider card and press Check now.
- "This account can't use single sign-on": the workspace owner, a platform admin, a deactivated account, or an account that is also in other workspaces must sign in with a password; SSO only vouches for this workspace. (The exact reason is in the server log, not shown to the person.)
- "The TXT record isn't there yet": DNS changes can take a few minutes; check the record name and value match the card exactly.
- "invalid signature" / "digest mismatch": the certificate in OpsAPI is not the IdP's current signing certificate.
- "Assertion is not addressed to this service (Audience)": the IdP's Entity ID / Audience doesn't match the one on the card.
- "sign-in request expired or was started in another browser": start again from the login page, or enable IdP-initiated sign-in.

## Rules
- Do not call any API from this page.
