# OpsAPI Theming Guide

A complete, plain-language guide to customizing the look of your OpsAPI workspace — colors, fonts, logos, spacing, and more. Written so **non-technical users** can follow along, with deeper notes at the end for admins and developers.

---

## Table of contents

1. [What is a theme?](#1-what-is-a-theme)
2. [Who can change themes?](#2-who-can-change-themes)
3. [Quick start — change your workspace colors in 60 seconds](#3-quick-start--change-your-workspace-colors-in-60-seconds)
4. [The six built-in starter themes](#4-the-six-built-in-starter-themes)
5. [Making your own theme (duplicate & customize)](#5-making-your-own-theme-duplicate--customize)
6. [Every setting explained](#6-every-setting-explained)
7. [Uploading your logo and favicon](#7-uploading-your-logo-and-favicon)
8. [Previewing before you commit](#8-previewing-before-you-commit)
9. [Activating a theme (making it live)](#9-activating-a-theme-making-it-live)
10. [Revisions — undoing a change](#10-revisions--undoing-a-change)
11. [Sharing themes between workspaces](#11-sharing-themes-between-workspaces)
12. [Accessibility & brand best practices](#12-accessibility--brand-best-practices)
13. [Troubleshooting / FAQ](#13-troubleshooting--faq)
14. [Glossary](#14-glossary)
15. [For developers & admins](#15-for-developers--admins)

---

## 1. What is a theme?

A **theme** is the complete visual "skin" of your OpsAPI workspace. One theme controls:

- The **colors** of buttons, links, alerts, and the background
- The **fonts** used for text and headings
- How **rounded** buttons and cards look (corner radius)
- How **tight or airy** the layout feels (density)
- Your **logo**, **brand name**, and **favicon** (the little icon in the browser tab)
- Whether motion animations are **on or off**
- Any extra **custom CSS** you want to add for fine-tuning

Every workspace (called a "namespace" in OpsAPI) has **one active theme at a time**. Changing the active theme updates the whole dashboard instantly for everyone in your workspace — no redeploy, no downtime.

> **Key idea:** Think of themes like outfits in your wardrobe. You can have as many as you like — one for winter, one for presentations, one for your brand — but only one is "worn" at a time.

---

## 2. Who can change themes?

Access is controlled by your namespace role:

| Role | What they can do |
|------|------------------|
| **Owner / Admin** | Create, edit, delete, activate, publish, and duplicate any theme |
| **Member with `themes:update` permission** | Edit existing themes |
| **Member with `themes:activate` permission** | Switch the active theme |
| **Regular members** | See the active theme (they can't change it) |

If you don't see the "Themes" menu item, ask your workspace admin to grant you the `themes` permissions.

---

## 3. Quick start — change your workspace colors in 60 seconds

The fastest path for someone who just wants their workspace to look a bit different:

1. Sign in to your OpsAPI dashboard.
2. In the left sidebar, click **Themes**. (Direct URL: `/dashboard/themes`)
3. You'll see a list of pre-built themes at the top (**Light**, **Dark**, **Corporate Blue**, **Minimal**, **Vibrant**, **High Contrast**).
4. Hover over the one you like and click **Activate**.
5. The whole dashboard instantly updates. Done.

That's the entire journey for 80% of users. If you want to tweak things further, read on.

---

## 4. The six built-in starter themes

OpsAPI ships with six curated presets. They're **read-only** — you can't edit them directly, but you can duplicate any of them and then change everything. This keeps the originals available as a "reset" any time.

| Theme | Best for | Personality |
|-------|----------|-------------|
| **Light** | Most dashboards, daytime work | Clean white background, blue accents |
| **Dark** | Long sessions, low-light environments | Near-black background, indigo + purple accents, reduces eye strain |
| **Corporate Blue** | Financial services, legal, professional B2B | Trustworthy navy + slate, serif headings, tight corners |
| **Minimal** | Content-heavy sites, writing apps | Grayscale-first, almost no shadows, no animations |
| **Vibrant** | Creative studios, consumer apps, retail | Magenta + teal, rounded corners, subtle glass effects |
| **High Contrast** | Accessibility (WCAG AAA), vision impairment | Pure black on white, bold focus rings, no animations, square corners |

> **Tip:** Start with the preset closest to your brand, then duplicate it and tweak. You'll get a polished result ten times faster than starting from a blank theme.

---

## 5. Making your own theme (duplicate & customize)

Because the six presets are locked, you customize by duplicating:

1. Go to **Themes**.
2. Click the preset that's closest to what you want (e.g. **Light**).
3. On the editor page you'll see a banner: **"This is a system theme (read-only). Duplicate it to customize."** Click **Duplicate to customize**.
4. You'll land in a new editable copy named `Light (copy)` or similar.
5. Rename it to something memorable (e.g. *"Acme 2026 Brand"*).
6. Change any setting on the left (they're grouped: Brand, Surface, Typography, etc.). Each change is shown live in the preview on the right.
7. Click **Save**.
8. Click **Activate** to make it the live theme — or keep it as a draft to activate later.

**Alternative: Create from scratch**

1. On the main Themes page, click **+ New theme**.
2. Fill in a name (and an optional description).
3. *Optionally* tick **"Activate immediately"** so the theme goes live the moment it's created.
4. Click **Create** — you'll be taken to the editor with sensible defaults.

---

## 6. Every setting explained

The editor groups every tweakable setting under logical headings. Here's what each one does, in plain English.

### 6.1 Brand colors

These are your signature colors. Set these first — most other colors derive from them.

| Setting | What it does | Example |
|---------|--------------|---------|
| **Primary** | Your main brand color. Used on primary buttons, links, active menu items. This is a **scale** of 10 shades (50 = very light, 900 = very dark). | Pick a hex like `#2563eb` for the 600 shade; the editor fills in the rest, or you can set each shade by hand. |
| **Secondary** | A complementary / neutral scale used for cards, borders, subtle text. Usually a gray or muted tone. | Slate or zinc grays. |
| **Accent** | A single pop color used sparingly (e.g. a callout badge). | A contrasting warm tone like `#f97316` (orange). |

**What's a color scale?** Instead of one blue, you pick ten blues from pale (50) to near-black (900). This is standard in modern design systems (Tailwind, Material Design) — it means buttons, hover states, and disabled states all look cohesive without you having to pick each one.

**Easy route:** Set only the `500` shade (the "true" middle) and the system will auto-generate the other shades. Advanced users can hand-tune each step.

### 6.2 Surface colors

These control your page background and default text.

| Setting | What it does |
|---------|--------------|
| **Background** | The base page color. `#ffffff` for white, `#09090b` for near-black. |
| **Foreground** | The default text color on that background. Should contrast strongly with the background. |

### 6.3 Semantic colors

These map to **meaning**, not brand. They rarely need to change.

| Setting | Used for |
|---------|----------|
| **Success** | Confirmation messages, "saved" toasts — usually green |
| **Warning** | Caution banners — usually amber |
| **Danger** | Errors, delete buttons — usually red |
| **Info** | Informational callouts — usually cyan/blue |

### 6.4 Typography

| Setting | What it does | Tips |
|---------|--------------|------|
| **Body font** | The font used for most text | Keep it a readable sans-serif like Inter, Roboto, or the default system stack |
| **Heading font** | The font for titles and section headers | A serif here (e.g. Georgia) gives a more formal look |
| **Monospace font** | The font for code blocks and numeric data | JetBrains Mono, Menlo, or Consolas |
| **Base size** | The size of normal text. `16px` is standard. Lower = denser, higher = easier to read. | Range: `12px` – `20px` |
| **Line height** | The vertical space between lines of text | `1.5` is a comfortable default. `1.2` is tight, `1.8` is airy. |
| **Letter spacing** | How far apart letters sit | Leave at `0` unless you're making a specific brand statement |

> Fonts must either be web-safe (Arial, Georgia, etc.) or already loaded by your app (e.g. Google Fonts). The theme doesn't fetch fonts for you.

### 6.5 Radius (how rounded things look)

Controls the corner radius of buttons, cards, modals, and inputs.

| Setting | Default | Effect |
|---------|---------|--------|
| **Small** | `4px` | Form inputs, checkboxes |
| **Medium** | `8px` | Most buttons, cards |
| **Large** | `12px` | Modals, large cards |
| **XL** | `16px` | Hero cards, feature panels |
| **Full** | `9999px` | Pill-shaped buttons, avatars |

Set them all to `0px` for a sharp "architectural" feel. Crank them up for a playful rounded look (see the Vibrant preset).

### 6.6 Spacing scale

A single number (default `4`) that multiplies every gap in the UI. A scale of `4` means small gaps are 4px, medium 8px, large 16px, etc.

- Lower value (`2` or `3`) = more compact, data-dense
- Higher value (`6` or `8`) = airy, generous padding

Range: `2` to `8`.

### 6.7 Shadows

Four levels of drop shadows for elevated surfaces.

| Setting | Where it's used |
|---------|-----------------|
| **Small** | Subtle lift on resting cards |
| **Medium** | Hovered buttons, active cards |
| **Large** | Modals, dropdowns |
| **XL** | Popovers, command palette |

You can paste any valid CSS `box-shadow` string. The Minimal preset uses almost-flat shadows; Vibrant uses stronger ones.

### 6.8 Layout

| Setting | What it does |
|---------|--------------|
| **Sidebar width** | How wide the left navigation is. Default `280px`. |
| **Container max width** | How wide the main content area can grow before it stops. `1280px` is a good middle ground. Use `100%` for full-bleed. |
| **Density** | `compact` / `comfortable` / `spacious` — controls padding inside list rows, form fields, and menu items |
| **Navigation style** | `fixed` (pinned to top), `floating` (card-style), or `minimal` (thin bar) |

### 6.9 Branding

| Setting | What it does |
|---------|--------------|
| **Logo** | Upload your company logo. Shown top-left in the dashboard. Recommended: transparent PNG or SVG, around 200×40px. |
| **Logo text** | Fallback text shown when no logo is uploaded (or next to a small icon logo). |
| **Favicon** | The tiny icon in the browser tab. Recommended: 32×32px or 64×64px PNG/ICO. |
| **Brand name** | Your company name — used in the page `<title>` and email templates. |

See [Section 7](#7-uploading-your-logo-and-favicon) for the upload workflow.

### 6.10 Effects

| Setting | What it does |
|---------|--------------|
| **Enable animations** | Toggle all motion (transitions, fades). Turn off for accessibility or very slow devices. |
| **Animation speed** | `fast` / `normal` / `slow` — how quickly menus slide, modals fade in, etc. |
| **Glass morphism** | Adds a frosted-glass effect (blur + translucency) to modals and overlays. A modern stylistic touch — looks great on Vibrant themes, looks out of place on Corporate Blue. |

### 6.11 Custom CSS (advanced)

At the bottom of the editor there's a **Custom CSS** textarea. Anything you paste here is appended to the page's stylesheet after every other token is applied. Use it for:

- Very specific tweaks the schema doesn't expose
- Brand-specific micro-fixes (e.g. repositioning the logo on small screens)
- Overriding a particular component's style

> **Caution:** Custom CSS can break the layout if you target the wrong selectors. Keep it short and well-commented. If something looks wrong after an edit, your custom CSS is the first place to check. You can empty this box to safely revert.

**Custom CSS is validated** for length and basic sanity (max ~20,000 characters), but it is **not sandboxed**. Don't paste CSS from untrusted sources.

---

## 7. Uploading your logo and favicon

1. In the theme editor, scroll to the **Branding** section.
2. Click the **Logo** upload area — a file picker opens.
3. Choose a PNG, JPG, or SVG file (max ~5 MB).
4. The file uploads to secure storage and the preview refreshes.
5. Repeat for **Favicon**.
6. Click **Save** to store the changes against your theme.

**Logo specs (recommended):**
- Transparent background (PNG or SVG)
- Wide aspect ratio (e.g. 200×40 px) — horizontal logos work best
- A version that looks good on both light and dark backgrounds (or upload a theme-specific variant)

**Favicon specs:**
- 32×32 px or 64×64 px
- PNG preferred (ICO also accepted)
- Square, simple design (it will be shown very small)

---

## 8. Previewing before you commit

Every change in the editor updates the preview panel on the right **immediately** — no save needed. The preview shows:

- A sample button in each color
- A card with sample text
- A mock form
- Your typography at different sizes
- A sample alert

If you want to see the theme applied to the **real** dashboard before activating it, click **Preview in dashboard** (opens in a new tab with your unsaved changes applied locally). Close the tab to revert to the currently active theme.

**Important:** Preview is just for you. Other users in your workspace keep seeing the currently active theme until you hit **Activate**.

---

## 9. Activating a theme (making it live)

Activating a theme is the act of saying *"this is now the look of the workspace for everyone."*

1. Open the theme you want to make live.
2. Click the **Activate** button at the top right.
3. A confirmation appears — click **Confirm**.
4. Within a few seconds, every open dashboard tab across your whole workspace picks up the new theme automatically. No one needs to refresh or log out.

**Fine print:**
- Only **one theme per namespace** is active at a time. Activating a new one automatically deactivates the old one.
- The change is **instant for authenticated pages**. Unauthenticated pages (login, sign-up) pick up the new theme on next page load.
- Activation generates a new version number which busts browser caches — so users don't see stale styles.

---

## 10. Revisions — undoing a change

Every time you save a theme, OpsAPI keeps a **revision** — a snapshot of exactly what the theme looked like at that moment.

To undo a change:

1. Open the theme in the editor.
2. Click the **Revisions** tab (top right).
3. You'll see a list of saved versions with timestamps and who saved them.
4. Click **Preview** on any revision to see it without changing anything.
5. Click **Revert** to restore that revision. (A new revision is created so you can re-undo the revert.)

Revisions cover **all** token changes and custom CSS. Uploaded logo/favicon files are also preserved.

---

## 11. Sharing themes between workspaces

If you run multiple workspaces (or you're a partner building themes for clients), you can publish a theme so others can install it.

### Publishing

1. Open your theme.
2. Click **Publish**.
3. Choose a visibility:
   - **Private (default)** — only people in your workspace see it
   - **Public** — listed in the shared Marketplace, anyone can install it
4. A shareable marketplace listing is created.

### Installing a theme someone else published

1. Go to **Themes → Marketplace**.
2. Browse or search. Click **Install** on any theme.
3. A fresh editable copy is created in **your** workspace. You can customize and activate it like any other theme.
4. The original stays owned by its creator — they can update it, but your installed copy is yours to edit without affecting them.

### Unpublishing

Click **Unpublish** on your theme to remove it from the marketplace. People who've already installed it keep their copies (they're independent).

---

## 12. Accessibility & brand best practices

A beautiful theme that no one can read is a bad theme. A short checklist:

**Contrast**
- Foreground text should have at least **4.5:1 contrast ratio** against the background for body text. Use a tool like https://webaim.org/resources/contrastchecker/.
- The **High Contrast** preset is WCAG AAA compliant out of the box — start there if accessibility is a hard requirement.

**Colorblindness**
- Don't rely on color alone to convey meaning (e.g. green = success, red = error). Combine with icons or text labels.
- Test your theme with a colorblindness simulator (e.g. Chrome DevTools → Rendering → Emulate vision deficiencies).

**Font size**
- Keep the base size at `16px` or above. `12px` is too small for anyone over 40.

**Motion**
- Offer an animation-off mode for users who are sensitive to motion (vestibular disorders). The **Enable animations** toggle is there for this.

**Brand consistency**
- Lock the Primary color to your brand's actual hex value.
- Match the heading font to your marketing site if possible.
- Use the logo upload for a real logo, not logo text, wherever possible.

---

## 13. Troubleshooting / FAQ

**Q: I activated a theme but the dashboard still looks the same.**
1. Do a hard refresh (Ctrl+Shift+R / Cmd+Shift+R) to bust any stale browser cache.
2. Open a different tab — does it show the new theme? If yes, the first tab just needs a reload.
3. If still stuck, check the bottom-right of the page for a **theme version indicator**. It should bump each activation. If it doesn't, contact your admin — the theme cache may need manual clearing.

**Q: The preset I clicked is read-only and I can't edit it.**
That's by design. Click **Duplicate to customize** — it makes an editable copy in 1 second.

**Q: I broke my theme with custom CSS. How do I get back?**
1. Open the theme editor.
2. Click **Revisions**.
3. Pick a revision from before the custom CSS change and click **Revert**. Done.

If you can't access the editor (because CSS broke the UI itself), your admin can revert via API. See the **For developers** section.

**Q: Can I have a different theme for different sub-brands or departments?**
Each **namespace** (workspace) has its own active theme. If you serve two sub-brands from one OpsAPI instance, give each its own namespace and its own active theme.

**Q: How do I export a theme to give to a designer?**
On the theme page, click **Export JSON**. The full token tree downloads as a `.json` file. They can edit it and send it back; you can **Import JSON** to create a new theme from their file.

**Q: Does the theme affect emails and PDFs?**
Partially. The **brand name** and **logo** are pulled into transactional emails and PDF receipts. Color/typography changes only affect the in-browser dashboard today — emails use a curated subset.

**Q: Is the preview I see exactly what other people will see?**
Yes, as long as they use the same browser family. Some very old browsers (IE11) don't support CSS custom properties, but OpsAPI doesn't support them anyway.

**Q: What happens to the currently active theme if I delete it?**
You can't. Deleting the active theme is blocked — activate a different theme first, then delete the old one.

**Q: My logo looks stretched / pixelated.**
The logo is displayed at the width the header reserves (roughly 200 px wide). Upload an image that matches that aspect ratio. PNG at 2x resolution (400×80) or SVG is ideal — SVG never pixelates.

---

## 14. Glossary

| Term | Plain English |
|------|---------------|
| **Theme** | The full visual skin of the workspace — one bundle of colors, fonts, and settings |
| **Preset** | One of the six built-in starter themes that ship with OpsAPI |
| **Token** | A single value inside a theme (e.g. "primary color = `#2563eb`"). A theme is a collection of ~60 tokens. |
| **Color scale** | A set of 10 related shades (50 → 900) of a single color, used so the UI looks harmonious across states |
| **Namespace** | One workspace / tenant on the platform. Each namespace has its own themes and active theme. |
| **Active theme** | The one theme that's currently displayed to everyone in the namespace |
| **Revision** | An automatic snapshot of a theme created every time you save |
| **Marketplace** | The public listing where you can publish themes for other workspaces to install |
| **Custom CSS** | Raw stylesheet rules you can append to a theme for edge-case tweaks |
| **System theme** | A platform preset (Light / Dark / etc.) that can be duplicated but not edited directly |
| **Favicon** | The tiny icon shown in browser tabs, bookmarks, and phone home screens |

---

## 15. For developers & admins

This section is deliberately separate so the guide can be handed to end users without the technical baggage. Everything below is **optional reading** for people running the platform.

### API surface

All endpoints are prefixed with `/api/v2/themes`. Authentication is standard JWT + namespace headers; writes are gated by the `themes` RBAC module with granular actions (`read`, `create`, `update`, `delete`, `activate`, `publish`, `manage`).

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/api/v2/themes` | List themes for namespace |
| `GET`  | `/api/v2/themes/presets` | Platform starter themes |
| `GET`  | `/api/v2/themes/marketplace` | Public published themes |
| `GET`  | `/api/v2/themes/schema` | Token schema (drives editor UI) |
| `GET`  | `/api/v2/themes/active` | Current active theme JSON |
| `GET`  | `/api/v2/themes/active/styles.css` | **Public** rendered CSS |
| `POST` | `/api/v2/themes` | Create from scratch or preset |
| `POST` | `/api/v2/themes/install/:source_uuid` | Install a marketplace theme |
| `GET`  | `/api/v2/themes/:uuid` | Get single theme |
| `PUT`  | `/api/v2/themes/:uuid` | Update tokens / custom CSS |
| `DELETE` | `/api/v2/themes/:uuid` | Soft delete |
| `POST` | `/api/v2/themes/:uuid/activate` | Set as active |
| `POST` | `/api/v2/themes/:uuid/duplicate` | Clone into new theme |
| `POST` | `/api/v2/themes/:uuid/revert` | Revert to a revision |
| `GET`  | `/api/v2/themes/:uuid/revisions` | List revisions |
| `GET`  | `/api/v2/themes/:uuid/preview.css` | Preview CSS for editor |
| `POST` | `/api/v2/themes/:uuid/publish` | Set visibility=public |
| `POST` | `/api/v2/themes/:uuid/unpublish` | Set visibility=private |

The `/active/styles.css` endpoint is the **only** public one — safe because it returns design tokens only, no user data. It accepts `X-Namespace-Slug` or `?namespace_slug=` so unauthenticated marketing/login pages can adopt the active theme.

### Token schema

The canonical source of truth is `lapis/helper/theme-token-schema.lua`. Every field declared there is automatically:

- Exposed via `/api/v2/themes/schema` to the frontend editor (UI controls are auto-generated — no frontend change needed when you add a token)
- Validated on write by `theme-validator.lua` (unknown keys rejected; types/ranges enforced)
- Rendered to CSS variables by `theme-renderer.lua`

**Adding a new token:** edit `theme-token-schema.lua` only. The editor picks it up on next deploy.

### Seeding new presets

Presets live in `lapis/helper/theme-presets.lua` as a plain Lua list. The seeding migration is idempotent and re-runs on every deploy (via the `zzz` auto-delete pattern), so adding a new preset is a one-file change.

### Rendering pipeline

```
tokens (JSONB) → theme-renderer.lua → CSS custom properties
                                    → <link> injected by ThemeStyles.tsx
                                    → cached by namespace_id + project_code + version
```

Activation bumps the version number, which busts both the server-side Redis cache (`theme-cache.lua`) and browsers' HTTP cache (the URL has `?v=...`). When `REDIS_ENABLED=false`, the CSS is regenerated from the database on every request — acceptable for dev, not for production.

### Feature flags & migrations

The theme system is gated by the `themes` feature flag in `ProjectConfig` (see `helper/project-config.lua`). Migrations live in `lapis/migrations/theme-system.lua` and only run when the feature is enabled. If the tables are missing, confirm `FEATURES.THEMES` is enabled for the active `PROJECT_CODE`.

### Tables

- `themes` — the theme rows themselves, scoped by `namespace_id` (NULL for system presets)
- `theme_revisions` — immutable history of token snapshots
- `theme_assets` — uploaded logos and favicons (MinIO-backed)
- `theme_installations` — tracks which tenants installed which marketplace themes
- `theme_tokens` — denormalized token cache (future use)
- `namespace_active_themes` — the one-per-namespace active pointer

All respect namespace isolation via `namespace_id` FK filtering.

### CLI rescue — reverting a broken theme

If a broken theme locks admins out of the UI, revert via direct DB or cURL:

```bash
# Activate the Light preset for namespace "acme" as a last resort
curl -X POST https://api.yourdomain.com/api/v2/themes/<light-preset-uuid>/activate \
  -H "Authorization: Bearer <admin-jwt>" \
  -H "X-Namespace-Slug: acme"
```

Or update the `namespace_active_themes` row directly in PostgreSQL and bump the `version` column to bust caches.

### Known limitations

- Custom CSS is **not sandboxed** — it's the theme author's responsibility to keep it clean
- Theme changes do not yet propagate to transactional email templates' full stylesheet (only brand name + logo)
- Marketplace has no rating / popularity signals yet
- No multi-theme A/B testing (one active per namespace)

---

*Last updated: 2026-04-24 · Questions? File an issue or contact your OpsAPI admin.*
