---
title: Templates
pages: /dashboard/templates
api: /api/v2/templates, /api/v2/render-templates
modules: templates
tools:
suggestions: List my invoice templates | Make a copy of the default invoice template | Create a landing page layout
readonly: false
---
# Templates
Two tabs. **Document Templates**: invoice and timesheet HTML rendered to PDF, with {{ variable }} placeholders (e.g. {{ invoice.number }}); one default per type. Needs Invoicing enabled. **Layouts & Formats**: reusable {{slot}} templates — Page layout (cms_page, used by Content pages), Domain server and Domain rule (WSL Proxy JSON, used by Domains).

## Using the page
- Document Templates: type tabs All / Invoice / Timesheet, search, table. Create Template: Template Name*, Type* (Invoice/Timesheet), Description, Page Size, Orientation. Row actions: Edit, Clone (asks for a new name), Set as Default (star), Delete.
- Template builder (/dashboard/templates/{uuid}): Edit HTML / Preview tabs (Refresh Preview), CSS box, variables list (click to insert). Side panel: Name, Type, Description; page setup Size, Orientation, Margins (Top/Bottom/Left/Right); Theme / Branding (Primary Color, Secondary Color, Font Family, Footer Text); Advanced Config (JSON). Header: Save (shows Unsaved changes / Saved), Set as default, Clone, Version history (restore an older version), PDF preview.
- Layouts & Formats: type filter (All types, Page layouts, Domain server (JSON), Domain rule (JSON)); New Template → Name, Type, Template content ({{slot}} placeholders), Sample data (JSON), Description (optional), "Default template for this type"; Preview renders with the sample data; Create / Save. Cards have Edit and Delete.

## Rules
- Document template: name and type required; type invoice|timesheet (API also accepts receipt|report) and cannot be changed later. Blank HTML gets a starter. Every save bumps the version and keeps the old one in history.
- page_size A4|Letter|Legal; page_orientation portrait|landscape; margins like "20mm" (defaults 20mm top/bottom, 15mm left/right).
- config holds branding {primary_color, secondary_color, font_family, footer_text}; sending config REPLACES the whole object — GET first and merge.
- Set default = the template used for that type's PDFs; other defaults of the type are cleared.
- Layout template: name required; template_type cms_page|domain_wslproxy|domain_rule (default cms_page, cannot change later); slug from name, unique per type; sample_data is a JSON STRING; is_default true clears the previous default of that type. Pages/domains using a deleted layout fall back to the default or raw content.
- PDF generation/download is UI only.

## API
Document templates:
- `GET /api/v2/templates?page&perPage&type=invoice|timesheet&search&is_active=true|false`
- `GET /api/v2/templates/{uuid}`
- `POST /api/v2/templates {name*, type*, description, page_size, page_orientation, template_html, template_css, header_html, footer_html, margin_top, margin_bottom, margin_left, margin_right, config: object}`
- `PUT /api/v2/templates/{uuid} {name, description, template_html, template_css, header_html, footer_html, page_size, page_orientation, margin_top, margin_bottom, margin_left, margin_right, config: object, is_active: bool}`
- `DELETE /api/v2/templates/{uuid}`
- `POST /api/v2/templates/{uuid}/clone {name*}`
- `POST /api/v2/templates/{uuid}/set-default`
- `GET /api/v2/templates/{uuid}/versions` — history
- `POST /api/v2/templates/{uuid}/restore/{version}` — restore a version number
- `GET /api/v2/templates/variables/{type}` — placeholder names; {type} = invoice or timesheet
- `POST /api/v2/templates/preview-raw {template_html*, template_css, data: object}` — render without saving
Layouts & Formats:
- `GET /api/v2/render-templates?type=cms_page|domain_wslproxy|domain_rule&search`
- `GET /api/v2/render-templates/defaults` — starter content + sample data per type
- `GET /api/v2/render-templates/{uuid}`
- `POST /api/v2/render-templates {name*, template_type, content, sample_data: JSON string, description, is_default: bool, slug}`
- `PUT /api/v2/render-templates/{uuid} {name, slug, content, sample_data, description, is_default}`
- `DELETE /api/v2/render-templates/{uuid}`
- `POST /api/v2/render-templates/preview {content, data: object}` — render ad-hoc content
- `POST /api/v2/render-templates/{uuid}/preview {data: object}` — render a saved template (omit data to use its sample)
