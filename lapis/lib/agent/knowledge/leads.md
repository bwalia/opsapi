---
title: Leads
pages: /dashboard/leads
api: /api/v2/crm/leads, /api/v2/crm/meetings, /api/v2/crm/partners, /api/v2/crm/referrals
modules: crm_leads
tools: create_lead, list_leads
suggestions: What should I do next? | Show my late leads | Which leads came from the website this month? | Why was this lead scored so high?
readonly: false
---
# Leads
The lead pipeline: every enquiry from arrival to deal. A lead moves through fixed stages **new → contacting → qualified → meeting → converted**; it can be parked in **nurture** (comes back on a date) or **lost** (with a reason) from any open stage, and reopened from either. `converted` only happens through Convert, and a converted lead never moves again (work continues on its deal).

What happens by itself when a lead arrives (any source): it gets an owner (assignment rules, then round-robin), a first call planned within the workspace's response time in working hours, an alert to the owner, a possible-duplicate flag, and an AI analysis (summary, 0–100 fit score with reasons, deal size — from a web price search when the workspace has Google Gemini, else an estimate — next best action, partner suggestions, questions for the call and a draft reply). The AI only suggests; people act.

Who sees what: lead managers (crm_leads "manage": owners, admins) see every lead; everyone else sees their own and unassigned ones, and can take an unassigned lead.

## Using the pages
- **/dashboard/leads**: stat strip (open leads, pipeline value, late next steps), **Your next steps** (late and today's steps, today's meetings, unassigned count), and three views: **Pipeline** (drag a card between stages; Lost asks why, Nurture asks when), **Insights** (funnel, speed to lead, sources, lost reasons for a period), **List** (search, stage, owner, due, sort). Header: Partners, Settings (managers), Alerts, Add lead.
- **/dashboard/leads/{uuid}**: stage track, owner, actions (Call, Log a call, Email, WhatsApp, Book meeting, Qualify, Pass to partner, Convert to deal, Nurture, Lost, Reopen), the AI card (with **Do it** for its suggestion), next step, meetings, referrals, timeline.
- **/dashboard/leads/settings** (managers): response time, working hours, call plan, escalation, who gets new leads, AI model/budget, qualification questions, lost reasons, stage names, meetings.
- **/dashboard/leads/partners**: partner companies and every referral with its commission.
- Websites post leads to POST /api/v2/public/leads/{workspace-slug} (not for you to call).

## Rules
- Create needs `first_name` or `email`. A new lead starts in an open stage (default new); the creator owns it unless `owner_user_uuid` is null (queue). Only managers can give a new lead to someone else.
- Giving an open lead an owner when nothing is planned for it (e.g. leads from before the pipeline) plans a first call by itself.
- Stage changes: use `POST /api/v2/crm/leads/{uuid}/stage`. `lost` needs `reason`; `nurture` needs `nurture_until` (a date after today). Never set converted — use convert.
- Calls: `outcome` is one of connected, no_answer, voicemail, wrong_number, callback, not_interested. `callback` needs `next_at` (future ISO time). no_answer/voicemail plan the next attempt by themselves; not_interested moves the lead to lost.
- Meetings: `type` video | phone | in_person | viewing; in_person/viewing need `location`; `starts_at` must be in the future; invites go by email with a calendar file.
- Passing to a partner: sharing the customer's name and contact details needs `share_contact: true` AND `consent_confirmed: true` (the customer agreed). Without it the partner sees only what is wanted and its size. Always ask the user before confirming consent — never assume it.
- Confirm with the user before converting, marking lost, deleting, booking a meeting or sending a referral: these email people or can't be undone.

## API
- `GET /api/v2/crm/leads?stage&owner&due&hot&source&search&sort&page&per_page` — owner: me | unassigned | user uuid; due: overdue | today; sort: next_action | newest | score | value | stage_changed
- `GET /api/v2/crm/leads/board` — stages with count, value, overdue and cards
- `GET /api/v2/crm/leads/funnel?from&to` — dates YYYY-MM-DD (default last 90 days)
- `GET /api/v2/crm/leads/stats`
- `GET /api/v2/crm/leads/my-steps`
- `GET /api/v2/crm/leads/team` — people who can own leads
- `GET /api/v2/crm/leads/{uuid}` — with analysis, meetings, referrals
- `GET /api/v2/crm/leads/{uuid}/timeline`
- `POST /api/v2/crm/leads {first_name*, email* (one of the two), last_name, phone, company_name, job_title, source, channel, campaign, priority, notes, estimated_value, currency, owner_user_uuid}`
- `PUT /api/v2/crm/leads/{uuid} {any of: first_name, last_name, email, phone, company_name, job_title, source, channel, campaign, priority, notes}`
- `POST /api/v2/crm/leads/{uuid}/stage {stage*, reason, nurture_until}`
- `POST /api/v2/crm/leads/{uuid}/assign {owner_user_uuid (null = queue)}`
- `POST /api/v2/crm/leads/{uuid}/calls {outcome*, notes, duration_minutes, next_at, lost_reason}`
- `POST /api/v2/crm/leads/{uuid}/steps {type*: call|email|follow_up|task, due_at*: ISO time, note, subject}`
- `POST /api/v2/crm/leads/{uuid}/qualify {answers: {question_key: text}, estimated_value, currency, expected_close_date, move: true to move to qualified}`
- `POST /api/v2/crm/leads/{uuid}/analyse` — run the AI again
- `POST /api/v2/crm/leads/{uuid}/convert {name, value, currency, expected_close_date}` — creates account, contact and deal
- `POST /api/v2/crm/leads/{uuid}/meetings {type*, starts_at*, duration_minutes, meeting_url, location, notes, guests: [{email}], send_invite}`
- `PUT /api/v2/crm/meetings/{uuid} {starts_at, duration_minutes, meeting_url, location, notes}`
- `POST /api/v2/crm/meetings/{uuid}/cancel {reason}`
- `POST /api/v2/crm/meetings/{uuid}/outcome {outcome*: held|no_show, notes}`
- `GET /api/v2/crm/partners`
- `POST /api/v2/crm/referrals {lead_uuid or deal_uuid*, partner_uuid*, deal_value, commission_type, commission_value, message, share_contact, consent_confirmed}`
- `POST /api/v2/crm/referrals/{uuid}/status {status*: accepted|declined|won|lost|cancelled, deal_value, partner_reference, notes}`
- `DELETE /api/v2/crm/leads/{uuid}`
