# Demo: the AI PA for property professionals (5 minutes)

Ashley's brief: *not a property CRM — an AI PA that turns ordinary agents into super agents. It knows the
role, the company playbooks, the customers and properties; prioritises the day; prepares for conversations;
captures what happened; and tells the person what needs their human attention.*

What this demo shows, honestly:
- **"Trained" = taught, not re-weighted.** The model (self-hosted Qwen, the same one the chat uses) is taught
  the company's way of working through the **Playbook** plus the live data it reads each time. Change a
  playbook line and its behaviour changes on the next message. Fine-tuning comes later (see the end).
- **No public AI.** The model runs on our own servers (GDPR). A workspace opts in to it as its AI provider.
- **The CRM is the fallback.** If the AI is down, every task, lead, deal and alert is still in the normal
  pages; the rules engine (deadlines, urgency, alerts) doesn't need AI at all.

## Before the demo (once)
1. Leads Magnet → Deals settings → **AI & JobShout** → add provider **Platform model (self-hosted)**.
2. Seed the demo leads and news: `python3 projects/property-deals/scripts/pa_demo_seed.py <api-url> <owner-token> <namespace-id>`
   (creates Sarah Lane, Tom Rule, Mark Agent with news, a reply and tasks — all marked "(demo)").
3. Log in as the demo user, open **Deals today**. The PA is the chat panel on that page.

## The script
1. **Teach it** — Deals settings → **Playbook (AI)**. Show the sections (daily rhythm, seller call script,
   follow-up rules, compliance, when a human must take over). Edit *Seller call script*: add "Always ask
   about the deadline first." Save.
2. **"What needs my attention today?"** — the PA reads the briefing and answers in the playbook's daily
   rhythm: hot leads to call now → overdue blocking tasks → today → approvals → deals at risk → fresh news,
   each with the next action, and offers to draft follow-ups.
3. **"Prepare me for my call with Tom Rule"** — who he is, what's new, what he last said, what we want,
   3 questions from the seller call script (the deadline question first — the line you just added), and an
   opening line.
4. **"Draft follow-ups for my leads with fresh news"** — it drafts personal messages that open with each
   lead's news (a company formed, a post). Open **Approvals**: read, edit, approve. Nothing went out before
   a person approved (WhatsApp opens ready to send).
5. **Capture** — "I just spoke to Tom: he's executor, wants to sell by Christmas, his sister co-owns, call
   back Thursday 10am." The PA logs the call and creates the Thursday task. No forms.
6. **Hot lead** — "Sarah just WhatsApped: 'yes please call me this afternoon'". The PA logs her reply; it
   scores hot → a "Call Sarah now" task and an alert (app push / ntfy / Telegram / SMS) → it's at the top of
   Today and the home dashboard.
7. **Fallback** — open **Deals today**, **Deals**, **Leads**: everything the PA did is ordinary CRM data a
   person can work without AI.

## After the demo: from taught to trained
Every draft a person edits before approving is stored with the original (Approvals keeps both). That is the
training set for a fine-tune (LoRA on the self-hosted Qwen) once there are a few hundred approved examples:
the model then writes in the team's voice by default, and the playbook keeps steering it.
