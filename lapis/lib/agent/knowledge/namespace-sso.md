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
- **Email domains**: only addresses at these domains can sign in through the provider, and the login page's "Sign in with SSO" finds the provider from the domain.
- **Role for new members**: a role name in this workspace (e.g. member, viewer). Empty uses the workspace's default role.
- **Create accounts on first sign-in** (auto-provision): on by default; off means people must be invited first.
- **Allow IdP-initiated sign-in**: off by default; turn on to let people start from the IdP's app tile.
- Each provider card shows what to give the IdP: Metadata URL, Entity ID (Audience), ACS URL (Reply URL) and a direct sign-in link.
- Viewing needs `namespace` read; adding, editing and deleting need `namespace` manage (workspace owners).

## IdP settings to use
- NameID format: email address. Attributes: email, firstName, lastName (other names can be mapped in the provider).
- Sign the SAML response or assertion with RSA-SHA256 (SHA-1 is refused). Do not encrypt assertions.

## Why a sign-in fails
- "Accounts at <domain> can't sign in with this provider": the email domain is not in Email domains.
- "This account belongs to other workspaces too": an account in more than one workspace (or a platform admin) must sign in with a password; SSO only vouches for this workspace.
- "invalid signature" / "digest mismatch": the certificate in OpsAPI is not the IdP's current signing certificate.
- "Assertion is not addressed to this service (Audience)": the IdP's Entity ID / Audience doesn't match the one on the card.
- "sign-in request expired or was started in another browser": start again from the login page, or enable IdP-initiated sign-in.

## Rules
- Do not call any API from this page.
