'use client';

import React from 'react';
import Link from 'next/link';
import { BookOpen, Download } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { GettingStarted, downloadExampleCsv } from '@/components/opsapi-marketing/GettingStarted';

const LISTS = '/dashboard/opsapi-marketing/lists';
const CAMPAIGNS = '/dashboard/opsapi-marketing/campaigns';
const STUDIO = '/dashboard/opsapi-marketing/studio';
const SETTINGS = '/dashboard/namespace/plugins#plugin-opsapi_marketing';
const EMAIL = '/dashboard/namespace/email';
const SUPPRESSIONS = '/dashboard/plugins/opsapi_marketing/suppressions';

const TOPICS: [string, string][] = [
  ['connect-email', 'Connect your email account'],
  ['business-address', 'Add your business name and address'],
  ['test-mode', 'Test mode, and how many emails go out'],
  ['make-list', 'Make a list'],
  ['add-people', 'Add people to a list'],
  ['import-file', 'Upload a spreadsheet (Excel, CSV) or PDF'],
  ['templates', 'Make an email template'],
  ['write-email', 'Write an email'],
  ['send', 'Send a test, then send to your list'],
  ['results', 'See how it went'],
  ['unsubscribe', 'Unsubscribes'],
  ['problems', 'Something isn’t working'],
];

const PROVIDERS: { name: string; server?: string; login: React.ReactNode }[] = [
  {
    name: 'Gmail or Google Workspace',
    server: 'smtp.gmail.com',
    login: (
      <>
        Your full email address and an <strong>app password</strong> (not your normal password): Google Account →
        Security → 2-Step Verification → App passwords.
      </>
    ),
  },
  {
    name: 'Microsoft 365 or Outlook',
    server: 'smtp.office365.com',
    login: 'Your full email address and its password.',
  },
  { name: 'Zoho Mail', server: 'smtp.zoho.eu (or smtp.zoho.com)', login: 'Your full email address and its password.' },
  { name: 'Anything else', login: 'Search for “<your email company> SMTP settings”, or ask them for it.' },
];

/** Something to click, written the way it appears on screen. */
const B = ({ children }: { children: React.ReactNode }) => (
  <strong className="rounded bg-secondary-100 px-1.5 py-0.5 font-semibold dark:bg-secondary-800">{children}</strong>
);

const Go = ({ href, children }: { href: string; children: React.ReactNode }) => (
  <Link href={href} className="font-medium text-primary-700 underline underline-offset-2 dark:text-primary-300">
    {children}
  </Link>
);

function Topic({ id, title, children }: { id: string; title: string; children: React.ReactNode }) {
  return (
    <section
      id={id}
      className="mb-6 break-inside-avoid scroll-mt-24 space-y-3 rounded-2xl border border-secondary-200 bg-surface p-5 shadow-sm sm:p-6"
    >
      <h2 className="text-xl font-semibold">{title}</h2>
      <div className="space-y-3 text-base leading-relaxed [&_ol]:list-decimal [&_ol]:space-y-2 [&_ol]:pl-6 [&_ul]:list-disc [&_ul]:space-y-1 [&_ul]:pl-6">
        {children}
      </div>
      <p className="pt-1 text-sm">
        <a href="#top" className="text-secondary-500 underline underline-offset-2">
          Back to the top
        </a>
      </p>
    </section>
  );
}

const Tip = ({ children }: { children: React.ReactNode }) => (
  <p className="rounded-lg bg-primary-50 p-3 text-base dark:bg-primary-900/30">
    <strong>Tip: </strong>
    {children}
  </p>
);

export default function MarketingGuidePage() {
  return (
    <div id="top" className="space-y-6 p-4 sm:p-6 lg:p-8">
      <PageHeader
        title="Getting started"
        description="Everything you need to send your first email, step by step. No technical knowledge needed."
        icon={<BookOpen className="h-6 w-6" />}
      />

      <div className="grid items-start gap-6 2xl:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <div className="rounded-2xl border border-secondary-200 bg-linear-to-br from-primary-50 to-transparent p-5 text-base leading-relaxed shadow-sm sm:p-6 dark:from-primary-900/20">
          <p className="text-lg font-semibold">How it works, in one minute</p>
          <ol className="mt-2 list-decimal space-y-1 pl-6">
            <li>You connect your email account once, so emails come from you.</li>
            <li>
              You make a <strong>list</strong> — a group of people, like “Customers”.
            </li>
            <li>You add people to the list (type them, upload a spreadsheet, or tick them in your contacts).</li>
            <li>
              You write an <strong>email</strong> and send it to the list.
            </li>
          </ol>
          <p className="mt-3">
            Every email gets an unsubscribe link automatically. Anyone who clicks it is never emailed again — you don’t
            need to do anything.
          </p>
        </div>

        <GettingStarted />
      </div>

      <div className="grid items-start gap-6 lg:grid-cols-[260px_minmax(0,1fr)]">
        {/* Phones and tablets: a collapsible menu so the topics don't push the help down. */}
        <details className="group rounded-2xl border border-secondary-200 bg-surface shadow-sm lg:hidden">
          <summary className="flex cursor-pointer select-none items-center justify-between px-4 py-3 text-base font-semibold text-secondary-900">
            Help topics
            <span className="text-sm font-normal text-secondary-500 group-open:hidden">Show</span>
            <span className="hidden text-sm font-normal text-secondary-500 group-open:inline">Hide</span>
          </summary>
          <ul className="grid gap-0.5 px-2 pb-3 sm:grid-cols-2">
            {TOPICS.map(([id, title]) => (
              <li key={id}>
                <a
                  href={`#${id}`}
                  className="block rounded-lg px-2 py-2 text-base text-secondary-700 hover:bg-primary-50 hover:text-primary-700 dark:text-secondary-300 dark:hover:bg-primary-900/30"
                >
                  {title}
                </a>
              </li>
            ))}
          </ul>
        </details>
        <nav
          aria-label="Help topics"
          className="hidden rounded-2xl border border-secondary-200 bg-surface p-4 shadow-sm lg:sticky lg:top-6 lg:block"
        >
          <h2 className="px-2 text-xs font-semibold uppercase tracking-wider text-secondary-500">Help topics</h2>
          <ul className="mt-2 grid gap-0.5">
            {TOPICS.map(([id, title]) => (
              <li key={id}>
                <a
                  href={`#${id}`}
                  className="block rounded-lg px-2 py-1.5 text-base text-secondary-700 hover:bg-primary-50 hover:text-primary-700 dark:text-secondary-300 dark:hover:bg-primary-900/30"
                >
                  {title}
                </a>
              </li>
            ))}
          </ul>
        </nav>

        <div className="min-w-0 columns-1 gap-6 2xl:columns-2">
          <Topic id="connect-email" title="Connect your email account">
            <p>
              Do this once. Until you do, emails go out from the platform’s shared address instead of yours, and people
              are less likely to trust them.
            </p>
            <ol>
              <li>
                Open <Go href={EMAIL}>Workspace → Email</Go>.
              </li>
              <li>
                Under <B>Email server (SMTP)</B>, fill in the boxes using the table below for your email provider.
              </li>
              <li>
                Type the address people should see in <B>From address</B>, and your business name in <B>From name</B>.
              </li>
              <li>
                Make sure <B>Use this server</B> is switched on, then press <B>Save</B>.
              </li>
              <li>
                Type your own email in <B>Send a test email to</B> and press <B>Send test</B>. Check your inbox (and the
                spam folder). If it arrived, you’re connected.
              </li>
            </ol>
            <div className="grid gap-3 sm:grid-cols-2">
              {PROVIDERS.map((p) => (
                <div key={p.name} className="rounded-xl border border-secondary-200 p-3 text-sm">
                  <p className="text-base font-semibold text-secondary-900">{p.name}</p>
                  {p.server ? (
                    <dl className="mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
                      <dt className="text-secondary-500">Server</dt>
                      <dd className="font-mono [overflow-wrap:anywhere]">{p.server}</dd>
                      <dt className="text-secondary-500">Port</dt>
                      <dd>587</dd>
                      <dt className="text-secondary-500">Security</dt>
                      <dd>STARTTLS</dd>
                      <dt className="text-secondary-500">Log in with</dt>
                      <dd>{p.login}</dd>
                    </dl>
                  ) : (
                    <p className="mt-1 text-secondary-600">{p.login}</p>
                  )}
                </div>
              ))}
            </div>
            <Tip>
              Gmail sends about 500 emails a day, Google Workspace about 2,000. Tell the system your limit under{' '}
              <B>Emails per day</B> (see “Test mode, and how many emails go out”) and the rest wait for the next day.
            </Tip>
          </Topic>

          <Topic id="business-address" title="Add your business name and address">
            <ol>
              <li>
                Open <Go href={SETTINGS}>Workspace → Plugins → Marketing Cloud</Go>.
              </li>
              <li>
                In <B>Business name and postal address (email footer)</B>, type your business name and full postal
                address.
              </li>
              <li>
                Press <B>Save settings</B>.
              </li>
            </ol>
            <p>It appears at the bottom of every email, next to the unsubscribe link. UK and US law require it.</p>
          </Topic>

          <Topic id="test-mode" title="Test mode, and how many emails go out">
            <p>
              <strong>Test mode</strong> lets you practise: everything works, but no email really leaves. It’s the{' '}
              <B>Test mode: don’t really send</B> switch in{' '}
              <Go href={SETTINGS}>Workspace → Plugins → Marketing Cloud</Go>.
            </p>
            <ul>
              <li>Leave it on while you are learning.</li>
              <li>
                Switch it <strong>off</strong> (and press <B>Save settings</B>) when you want emails — including test
                emails to yourself — to really arrive.
              </li>
            </ul>
            <p>In the same place you can set:</p>
            <ul>
              <li>
                <B>Emails per day</B> — your email provider’s daily limit (500 for Gmail). 0 means no limit.
              </li>
              <li>
                <B>Email sends per minute</B> — how fast emails go out. The normal setting is fine.
              </li>
              <li>
                <B>Emails sent at once</B> — leave it at 1 unless your provider allows more.
              </li>
            </ul>
            <p>
              You can always check what is set on{' '}
              <Go href="/dashboard/opsapi-marketing/settings">Marketing → Settings</Go> under “How your emails are
              sent”.
            </p>
          </Topic>

          <Topic id="make-list" title="Make a list">
            <ol>
              <li>
                Open <Go href={LISTS}>Marketing → Lists</Go>.
              </li>
              <li>
                Press <B>Make a new list</B> (the first time, the box is already on the page).
              </li>
              <li>
                Type a name you’ll recognise, like “Customers” or “Local businesses”, and press <B>Create list</B>.
              </li>
            </ol>
            <p>Your new list opens straight away, ready for you to add people.</p>
            <Tip>
              Make a separate list for each group you write to differently — for example one for customers and one for
              businesses you’d like to win.
            </Tip>
          </Topic>

          <Topic id="add-people" title="Add people to a list">
            <p>
              Open <Go href={LISTS}>Marketing → Lists</Go> and click your list. Under <B>Add people to this list</B>,
              pick one of the three ways:
            </p>
            <ul>
              <li>
                <B>Type email addresses</B> — type or paste them, one per line, then press <B>Next</B>.
              </li>
              <li>
                <B>Upload a file</B> — choose an Excel, CSV or PDF file. See “Upload a spreadsheet” below.
              </li>
              <li>
                <B>Choose from my contacts</B> — search, tick the people you want (or <B>Tick everyone shown</B>), then
                press <B>Next</B>.
              </li>
            </ul>
            <p>Then, on the check screen:</p>
            <ol>
              <li>Read how many people will be added, and who is left out and why.</li>
              <li>
                Answer <B>Who are these people?</B> — <em>Businesses I want to tell about my products</em>, or{' '}
                <em>People who asked to get my emails</em>.
              </li>
              <li>Tick the box to confirm you’re allowed to email them.</li>
              <li>
                Press <B>Add … people</B>. Done — they appear under <B>People in this list</B>.
              </li>
            </ol>
            <Tip>
              Someone added twice is only added once, and anyone who ever unsubscribed is left out automatically. To
              take someone off a list, press <B>Remove</B> next to them (they stay in your contacts).
            </Tip>
          </Topic>

          <Topic id="import-file" title="Upload a spreadsheet (Excel, CSV) or PDF">
            <p>
              The file only needs email addresses. If it also has names and company names, they are used to personalise
              your emails (“Hi Jane”).
            </p>
            <ol>
              <li>
                Get the file ready. It works best like this — one person per row, with a heading on the first row:
                <div className="mt-2 overflow-x-auto">
                  <table className="text-sm">
                    <thead>
                      <tr className="text-left">
                        <th className="border border-secondary-300 px-2 py-1">Email</th>
                        <th className="border border-secondary-300 px-2 py-1">First name</th>
                        <th className="border border-secondary-300 px-2 py-1">Last name</th>
                        <th className="border border-secondary-300 px-2 py-1">Company</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <td className="border border-secondary-300 px-2 py-1">jane@example-plumbing.co.uk</td>
                        <td className="border border-secondary-300 px-2 py-1">Jane</td>
                        <td className="border border-secondary-300 px-2 py-1">Smith</td>
                        <td className="border border-secondary-300 px-2 py-1">Example Plumbing Ltd</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </li>
              <li>
                Save it. From Excel, a normal <strong>.xlsx</strong> file is fine. From Google Sheets use{' '}
                <em>File → Download → Microsoft Excel</em> or <em>Comma-separated values (.csv)</em>. Old <em>.xls</em>{' '}
                files: open them and save again as .xlsx.
              </li>
              <li>
                In your list, choose <B>Upload a file</B> and pick the file. Files up to 7 MB work (tens of thousands of
                people).
              </li>
              <li>Check what will be added, answer the question, tick the box and press Add.</li>
            </ol>
            <p>
              <Button variant="outline" leftIcon={<Download className="h-4 w-4" />} onClick={downloadExampleCsv}>
                Download an example file
              </Button>
            </p>
            <p>What gets left out, and why:</p>
            <ul>
              <li>The same address twice — it’s added once.</li>
              <li>People who unsubscribed before — never emailed again.</li>
              <li>
                For <em>Businesses I want to tell about my products</em>: personal addresses like Gmail or Hotmail. The
                law only lets you send those people marketing if they asked for it. If they did, choose{' '}
                <em>People who asked to get my emails</em>.
              </li>
            </ul>
            <Tip>
              Bought a list of companies? Write where it came from in the note box — it’s kept as a record in case
              anyone asks.
            </Tip>
          </Topic>

          <Topic id="templates" title="Make an email template">
            <p>A template is a saved email design you can reuse. You don’t need one, but it saves time.</p>
            <ol>
              <li>
                Open <Go href={STUDIO}>Marketing → Studio</Go>.
              </li>
              <li>
                New here? Press <B>Add ready-made templates</B> to get some designs to start from, then click one in the{' '}
                <B>Templates</B> list.
              </li>
              <li>
                Change the words in the editor like a normal document. Use the toolbar for <strong>bold</strong>,
                headings, links and the picture button to upload a photo or logo.
              </li>
              <li>
                To greet each person by name, click <B>First name</B> under <B>Merge fields</B>. It appears as{' '}
                <code>{'{{contact.first_name}}'}</code> and becomes “Jane” in Jane’s email (or “there” if there’s no
                name).
              </li>
              <li>
                Press <B>Save draft</B>, and <B>Publish</B> when it’s ready to use.
              </li>
            </ol>
          </Topic>

          <Topic id="write-email" title="Write an email">
            <ol>
              <li>
                The easiest way: in your list, press <B>Write an email to them</B>. Or open{' '}
                <Go href={CAMPAIGNS}>Marketing → Campaigns</Go>, type a name and press <B>Create draft</B>.
              </li>
              <li>
                You’re on the <B>Content</B> tab. To use a design you saved, pick it in <B>Start from a template</B>.
              </li>
              <li>
                Type the <B>Subject</B> — the line people see in their inbox.
              </li>
              <li>
                Change the words of the email in <B>HTML body</B>. Only change the words between the{' '}
                <code>&lt; &gt;</code> marks; leave the marks themselves alone. (Prefer a normal editor? Design it in
                the Studio and use <B>Start from a template</B>.)
              </li>
              <li>
                Pictures: put the cursor where it should go and press <B>Upload image</B>.
              </li>
              <li>
                The preview on the right shows exactly what people will see. Press <B>Save</B>.
              </li>
            </ol>
            <Tip>
              You don’t need to add an unsubscribe link or your address — they are added to every email for you.
            </Tip>
          </Topic>

          <Topic id="send" title="Send a test, then send to your list">
            <ol>
              <li>
                Open your email in <Go href={CAMPAIGNS}>Marketing → Campaigns</Go> and go to the <B>Audience</B> tab.
              </li>
              <li>
                Under <B>List</B>, choose who should get it (if you came from your list, it’s already chosen).
              </li>
              <li>
                Send yourself a test: type your email under <B>Test recipient</B> and press <B>Send test</B>. (Test mode
                must be off for it to really arrive.)
              </li>
              <li>
                Big list? Fill in <B>Per batch</B> and <B>Minutes between batches</B> — for example 400 and 60 sends 400
                emails every hour. Leave them empty to send to everyone at once.
              </li>
              <li>
                Press <B>Validate</B>. It checks everything and tells you how many people will get the email, and why
                anyone is left out.
              </li>
              <li>
                Press <B>Send now</B> — or <B>Schedule…</B> to pick a date and time.
              </li>
            </ol>
            <Tip>
              Emails are not sent at night (quiet hours, 9pm to 8am) — they wait and go out in the morning. You can
              change the hours in the Marketing Cloud settings.
            </Tip>
          </Topic>

          <Topic id="results" title="See how it went">
            <p>
              Open the email in <Go href={CAMPAIGNS}>Campaigns</Go> and go to the <B>Performance</B> tab to see how many
              were sent, opened and clicked, and who unsubscribed. The{' '}
              <Go href="/dashboard/opsapi-marketing/overview">Overview</Go> shows all your emails together.
            </p>
            <p>
              “Opened” is an estimate: some email apps hide opens and some count them twice. Clicks are more reliable.
            </p>
          </Topic>

          <Topic id="unsubscribe" title="Unsubscribes">
            <ul>
              <li>Every email has an unsubscribe link at the bottom. You never need to add it.</li>
              <li>
                Anyone who clicks it is never emailed by this workspace again — even if you upload them again later.
              </li>
              <li>
                You can see everyone who unsubscribed under <Go href={SUPPRESSIONS}>Marketing → Suppressions</Go>.
              </li>
            </ul>
          </Topic>

          <Topic id="problems" title="Something isn’t working">
            <ul>
              <li>
                <strong>Nobody got my email.</strong> Is test mode off? Is your email account connected (Workspace →
                Email → <B>Send test</B>)? Did you reach your daily limit? Check{' '}
                <Go href="/dashboard/opsapi-marketing/settings">Marketing → Settings</Go>. Look in spam folders too.
              </li>
              <li>
                <strong>It’s still sending hours later.</strong> That’s normal with batches, quiet hours or a daily
                limit — the rest go out on their own.
              </li>
              <li>
                <strong>Some people were left out.</strong> Press <B>Validate</B> on the Audience tab: it lists the
                reasons (unsubscribed, no permission, already emailed recently).
              </li>
              <li>
                <strong>My list says “Empty”.</strong> Click it and use <B>Add people to this list</B>.
              </li>
              <li>
                <strong>My list has no “Add people” box.</strong> It’s a smart list (it has a sparkle icon): it fills
                itself from your contacts using rules. Press <B>Make it a regular list</B> to add people yourself.
              </li>
              <li>
                <strong>My emails land in spam.</strong> Send from your own connected email, avoid ALL CAPITALS and lots
                of exclamation marks, and send to people who expect to hear from you.
              </li>
              <li>
                <strong>Still stuck?</strong> Press <B>Ask AI</B> (bottom corner) and describe what you’re trying to do.
              </li>
            </ul>
          </Topic>
        </div>
      </div>
    </div>
  );
}
