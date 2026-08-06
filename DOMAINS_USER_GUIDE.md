# Domains — Simple User Guide

A plain-English guide to adding your website addresses (domains), keeping an eye
on when they expire, and putting them live. No technical knowledge needed.

---

## What this does, in one sentence

It's an address book for your websites. You add a domain (like
`api.diytaxreturn.co.uk`), the system watches when it and its security
certificate expire, and — with one click — it sets everything up so the domain
works.

---

## The three things you'll do

1. **Set it up once** (connect it to GitHub) — takes 2 minutes, once.
2. **Add domains** — whenever you have a new one.
3. **Publish** — one button to make them live.

That's it.

---

## Step 1 — Set it up once (⚙️ Sync Settings)

You only do this the **first time**.

1. Open the **Domains** page in the dashboard.
2. Click **Sync Settings** (the gear icon, top right).
3. Fill in where your domains should be saved:
   - **owner** and **repo** — your project's GitHub location (e.g. `bwalia` /
     `diy-tax-return-uk`). *If you're not sure, ask whoever set up your project —
     they'll give you these two words.*
   - **branch** — leave it as `main`.
   - **environment** — choose `prod` for your live site.
4. Under **GitHub authentication**, either:
   - **pick an existing** connection from the list, **or**
   - choose **Add token**, paste the access key your tech team gives you, and
     give it a name like "Domain Sync".
5. Click **Save settings**.

Done. The system now remembers all of this — you won't be asked again.

> 💡 The access key is stored **encrypted** (scrambled) and is never shown again.
> Think of it like saving a password in your browser.

---

## Step 2 — Add a domain

1. On the **Domains** page, click **Add Domain**.
2. Type the **domain name** (for example `api.diytaxreturn.co.uk`).
3. Pick the **environment** (usually `prod`).
4. The other boxes (rule, SSL email, target) are usually pre-set or provided by
   your tech team — you can leave them if you're not sure.
5. Click **Add domain**.

The domain now appears in your list. **Adding it does not put it live yet** — it
just saves it. You go live in Step 3.

---

## Step 3 — Put your domains live (▶️ Run Pipeline)

When you're ready to make your domains work:

1. Click **Run Pipeline** (top right).
2. Click **Start**.
3. Watch the steps turn green:
   - **sync** — saves your domains to GitHub
   - **cloudflare-dns-reconcile** — points the domain at the right place on the internet
   - **wslproxy-register-domains** — sets up the web server so the site loads

Each step shows a **"view run ↗"** link if you want to see the details. When all
three are green, you're live. If one turns red, it stops there and shows you what
went wrong (nothing half-finished).

> 💡 **Tip:** the first time, ask your tech team to do a "dry run" (a safe
> test that changes nothing) before the real one.

---

## Reading the domain list

Each domain shows two expiry dates with a coloured label:

| Colour | Meaning |
|---|---|
| 🟢 **Green** | Fine — plenty of time left |
| 🟠 **Amber** | Expiring soon — renew it |
| 🔴 **Red** | Expired — needs attention now |

- **Registration** = when you'd need to renew the domain name itself.
- **SSL** = when the little padlock/security certificate expires.

Click **Check All** any time to refresh these dates. You'll also get a
notification when something is close to expiring.

---

## Common questions

**Do I need to understand DNS, SSL, or servers?**
No. You add the domain name and click Run Pipeline. The system handles the
technical parts.

**I added a domain but the website isn't working — why?**
Adding a domain only saves it. You still need to click **Run Pipeline** to make
it live.

**Something went red. What do I do?**
Nothing breaks — the pipeline stops safely. Click the **"view run ↗"** link to
see the message, or send a screenshot to your tech team.

**Will this change other people's domains?**
No. It only touches the domains you add here. Everyone else's stay exactly as
they are.

**Who can use this?**
Only people with permission on your workspace (owners and admins). Regular
members won't see it unless they're given access.

---

## Words explained (in plain English)

- **Domain** — a website address, like `api.diytaxreturn.co.uk`.
- **DNS** — the internet's phone book; it points a domain to the right place.
- **SSL / certificate** — the padlock that makes a site secure (`https`).
- **Environment** — which version of your site: `prod` (live), plus test ones
  like `acc`, `test`, `int`, `dev`.
- **Pipeline** — the "make it live" button that runs the steps in order.
- **Sync / GitHub** — where your domain list is safely saved and versioned.

---

### Quick recap

1. **Sync Settings** once → connect GitHub.
2. **Add Domain** → type the name, pick the environment, save.
3. **Run Pipeline** → watch it go green → you're live.

That's the whole system. 🎉
