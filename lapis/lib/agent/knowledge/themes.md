---
title: Themes
pages: /dashboard/themes
api: /api/v2/themes
modules: themes
tools:
suggestions: Which theme is active? | Make the primary colour darker | Create a theme from a preset and activate it
readonly: false
---
# Themes
The workspace's look and feel. A theme = design tokens (colors, typography, radius, spacing, shadows, layout, branding, effects) + optional custom CSS. Exactly one theme is active per workspace. Platform presets (is_system) are read-only — duplicate or install one to customise it. Every save creates a revision you can revert to.

## Using the page
- Tabs: Installed, Platform Presets, Marketplace. New Theme → Name, Description (optional), Start from preset, "Activate immediately so this theme applies to the dashboard".
- Installed cards: Edit, Activate, Duplicate, Delete (not shown for the active theme or presets). Presets and Marketplace cards: Install (creates an editable copy).
- Editor (/dashboard/themes/{uuid}): Theme details (Name, Description), Design tokens by group (Brand, Surface, Semantic, Typography, Radius, Spacing, Shadows, Layout, Branding, Effects), Custom CSS, Change note (optional), live Preview. Header: Revisions (Revert to this), Activate, Save. A preset shows a read-only banner with a duplicate button.
- Also reachable from Settings → Appearance.

## Rules
- name required (422). Start from a preset with from_preset_slug (slug from GET presets) or copy a theme with parent_uuid; otherwise default tokens.
- On PUT, tokens REPLACES the whole token object: GET the theme, change only what was asked, send the full tokens back. Validation is strict: 422 "token validation failed" with validation_errors listing the bad paths.
- Token shape: colors.primary and colors.secondary are scales {"50","100",…,"900"} (all 10 keys required, color values); colors.accent, background, foreground, surface, surface_elevated, success, warning, danger, info = colors like "#0ea5e9"; typography.font_family_base, font_family_heading, font_family_mono, font_size_base (12px–20px), line_height_base (1.0–2.0), letter_spacing; radius.sm|md|lg|xl|full (e.g. "8px"); spacing.scale (2–8); shadows.sm|md|lg|xl; layout.sidebar_width, container_max_width, density compact|comfortable|spacious, nav_style fixed|floating|minimal; branding.logo_text (≤50 chars), brand_name (≤100); effects.enable_animations (bool), animation_speed fast|normal|slow, glass_morphism (bool).
- Unsafe custom_css is rejected (422 "custom_css rejected").
- The active theme can't be deleted (409 — activate another first). Presets can't be edited or deleted (403).
- Activating needs the themes "activate" (or manage) permission. Logo/favicon images are UI only.

## API
- `GET /api/v2/themes?page&per_page&q` — installed themes (each has is_active, is_system)
- `GET /api/v2/themes/presets` — platform presets (slug, name)
- `GET /api/v2/themes/marketplace?page&per_page` — public themes to install
- `GET /api/v2/themes/active` — the active theme
- `GET /api/v2/themes/schema` — token schema (labels, limits, defaults)
- `GET /api/v2/themes/{uuid}` — {theme, tokens, custom_css}
- `POST /api/v2/themes {name*, description, from_preset_slug, parent_uuid, tokens: object, custom_css, slug}` — create
- `PUT /api/v2/themes/{uuid} {name, description, tokens: object (full), custom_css, change_note}` — save (new revision)
- `POST /api/v2/themes/{uuid}/activate` — make it the active theme
- `POST /api/v2/themes/{uuid}/duplicate {name}` — copy (default name "<name> (copy)")
- `POST /api/v2/themes/install/{source_uuid}` — install a marketplace theme
- `GET /api/v2/themes/{uuid}/revisions` — revision list
- `POST /api/v2/themes/{uuid}/revert {revision_uuid*}` — restore a revision
- `DELETE /api/v2/themes/{uuid}`
