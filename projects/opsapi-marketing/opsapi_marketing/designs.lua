-- Ready-made templates ("Add ready-made templates" in the Studio, the design gallery in a
-- campaign). Built only from what the easy editor keeps — one styled <div> card, headings,
-- paragraphs, lists, links/buttons and inline styles — so every one stays fully editable.
-- Each has its own accent colour; texts in [brackets] are for the business to fill in.

local B = require("opsapi_marketing.blocks")
local card, brand, banner, title, heading = B.card, B.brand, B.banner, B.title, B.heading
local p, lead, note, list, button, code, small, sign, footer =
    B.p, B.lead, B.note, B.list, B.button, B.code, B.small, B.sign, B.footer

local TEXT_FOOT = "\n\nUnsubscribe: {{unsubscribe_url}}"

return {
    {
        name = "Welcome — new customer", channel = "email",
        subject = "Welcome, {{contact.first_name}} — we’re glad you’re here",
        preview_text = "Here’s what happens next, and a little thank-you from us.",
        body_html = card({
            brand("#059669"),
            banner("#059669", "Welcome aboard"),
            p("Hi {{contact.first_name}},"),
            p("Thank you for joining us. We’re a small team who care about doing things properly, and we’re "
                .. "really glad you’re here."),
            heading("What you can expect"),
            list({ "<strong>Helpful tips</strong> — no more than one email a month.",
                "<strong>First access</strong> to new products and offers.",
                "<strong>Real people</strong> — just reply to any email and we’ll answer." }),
            note("#059669", "<strong>A little thank-you:</strong> use code <strong>WELCOME10</strong> for 10% off your first order."),
            button("#059669", "Get started"),
            sign(),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nThank you for joining us — we’re really glad you’re here.\n\n"
            .. "As a thank-you, use code WELCOME10 for 10% off your first order: https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "Newsletter — monthly update", channel = "email",
        subject = "{{contact.first_name}}, here’s what’s new this month",
        preview_text = "Our latest news, a handy tip and a few things we think you’ll like.",
        body_html = card({
            brand("#1d4ed8"),
            title("This month at [Your business name]"),
            lead("Hi {{contact.first_name}}, here’s a quick round-up of what’s been happening — it takes two minutes to read."),
            heading("1. Our big news"),
            p("[Tell them about something new: a product, a project, a new team member or an award.]"),
            heading("2. Tip of the month"),
            p("[Share one useful tip your customers will thank you for.]"),
            heading("3. Worth a look"),
            p("[Link to a blog post, a case study or a customer story.]"),
            button("#1d4ed8", "Read more on our website"),
            sign(),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nHere’s what’s new this month:\n1. Our big news\n2. Tip of the month\n"
            .. "3. Worth a look\n\nRead more: https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "Special offer — discount code", channel = "email",
        subject = "{{contact.first_name}}, 20% off — this week only",
        preview_text = "Use code SAVE20 before Sunday at midnight.",
        body_html = card({
            brand("#e11d48"),
            banner("#111827", "20% off everything"),
            p("Hi {{contact.first_name}},"),
            p("For one week only, take 20% off anything on our website. Just use this code at checkout:"),
            code("#e11d48", "SAVE20"),
            small("Ends Sunday at midnight. Can’t be used with other offers."),
            button("#e11d48", "Shop the offer"),
            sign(),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nThis week only: 20% off everything with code SAVE20.\n"
            .. "Shop now: https://yourwebsite.co.uk (ends Sunday at midnight)" .. TEXT_FOOT,
    },
    {
        name = "New product or service", channel = "email",
        subject = "Introducing something new, {{contact.first_name}}",
        preview_text = "Built to save you time — here’s how it works.",
        body_html = card({
            brand("#7c3aed"),
            title("Meet [New product name]"),
            lead("Hi {{contact.first_name}}, we’ve been working on something we think you’ll love."),
            p("[Say in one or two sentences what it is and the problem it solves.]"),
            list({ "<strong>[Benefit one]</strong> — [what it means for them].",
                "<strong>[Benefit two]</strong> — [what it means for them].",
                "<strong>[Benefit three]</strong> — [what it means for them]." }),
            note("#7c3aed", "<strong>Early-bird price:</strong> [£X] until [Friday] — then it goes up to [£Y]."),
            button("#7c3aed", "See how it works"),
            sign(),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nMeet [New product name] — [what it does].\n\n"
            .. "Early-bird price until [Friday]: https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "Event invitation", channel = "email",
        subject = "You’re invited, {{contact.first_name}}",
        preview_text = "Join us on [date] — places are limited.",
        body_html = card({
            brand("#7c3aed"),
            banner("#4c1d95", "You’re invited"),
            p("Hi {{contact.first_name}},"),
            p("We’d love you to join us for [event name] — [one line about why it’s worth coming]."),
            note("#7c3aed", "<strong>When:</strong> [Thursday 14 November, 6–8pm]<br><strong>Where:</strong> "
                .. "[Venue, address or online link]<br><strong>Cost:</strong> Free — places are limited"),
            button("#7c3aed", "Save my place"),
            p("Can’t make it? Reply to this email and we’ll send you the highlights afterwards."),
            sign("See you there,"),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nYou’re invited to [event name] on [date] at [place].\n"
            .. "Save your place: https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "Thank you + review request", channel = "email",
        subject = "Thank you, {{contact.first_name}} — how did we do?",
        preview_text = "It takes 30 seconds and really helps a small business like ours.",
        body_html = card({
            brand("#d97706"),
            title("Thank you for choosing us"),
            p("Hi {{contact.first_name}},"),
            p("Thank you for your recent order with us. We hope everything was just right."),
            p("Would you mind leaving us a short review? It takes about 30 seconds and helps other people find us."),
            '<p style="margin:8px 0;text-align:center;font-size:34px;letter-spacing:6px;color:#f59e0b">★★★★★</p>',
            button("#d97706", "Leave a review", "https://yourwebsite.co.uk/review"),
            p("If anything wasn’t right, just reply to this email — we’ll put it right."),
            sign("Thank you again,"),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nThank you for your recent order. Would you leave us a short review? "
            .. "https://yourwebsite.co.uk/review\n\nIf anything wasn’t right, just reply." .. TEXT_FOOT,
    },
    {
        name = "Business introduction", channel = "email",
        subject = "Quick question, {{contact.first_name}}",
        preview_text = "A better website could bring you more customers — here’s how we help.",
        body_html = card({
            brand("#0f766e"),
            p("Hi {{contact.first_name}},"),
            p("I’m [Your name] from [Your business name]. We help local businesses win more customers with "
                .. "fast, modern websites."),
            heading("What we do"),
            list({ "A new website, designed and online in <strong>two weeks</strong>.",
                "Built to show up on <strong>Google</strong> and look great on phones.",
                "Easy for you to update — no technical knowledge needed." }),
            note("#0f766e", "Our clients usually see <strong>more enquiries within the first month</strong>."),
            p("Would you be open to a free 15-minute chat this week? Just reply to this email, or pick a time below."),
            button("#0f766e", "Book a free call"),
            sign("Kind regards,"),
            footer("You’re getting this because we think our services could help your business."),
        }),
        body_text = "Hi {{contact.first_name}},\n\nI’m [Your name] from [Your business name]. We help local businesses "
            .. "win more customers with fast, modern websites — online in two weeks.\n\nOpen to a free 15-minute chat "
            .. "this week? Just reply, or book: https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "We miss you — come back", channel = "email",
        subject = "We miss you, {{contact.first_name}}",
        preview_text = "Here’s 15% off to welcome you back.",
        body_html = card({
            brand("#db2777"),
            banner("#db2777", "It’s been a while"),
            p("Hi {{contact.first_name}},"),
            p("We haven’t seen you for a while and wanted to say hello. A lot has changed since your last visit — "
                .. "and to welcome you back, here’s 15% off:"),
            code("#db2777", "COMEBACK15"),
            small("Valid for 14 days on anything in our shop."),
            button("#db2777", "Come back and save"),
            sign(),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nWe miss you! Here’s 15% off to welcome you back: code COMEBACK15 "
            .. "(14 days). https://yourwebsite.co.uk" .. TEXT_FOOT,
    },
    {
        name = "Seasonal greetings", channel = "email",
        subject = "Season’s greetings from all of us",
        preview_text = "Thank you for a wonderful year — and our holiday opening hours.",
        body_html = card({
            brand("#b91c1c"),
            banner("#166534", "Season’s greetings"),
            p("Hi {{contact.first_name}},"),
            p("As the year comes to an end, we wanted to say a big thank you for your support. It means the world "
                .. "to our small team."),
            note("#b91c1c", "<strong>Holiday opening hours</strong><br>[24 December: 9am–1pm]<br>"
                .. "[25–26 December: closed]<br>[From 2 January: normal hours]"),
            p("Wishing you and your loved ones a happy, restful holiday."),
            button("#b91c1c", "Visit our website"),
            sign("Warm wishes,"),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nThank you for your support this year. Wishing you a happy, restful "
            .. "holiday.\n\nHoliday hours: [your hours]" .. TEXT_FOOT,
    },
    {
        name = "Feedback survey", channel = "email",
        subject = "{{contact.first_name}}, can we ask you 3 quick questions?",
        preview_text = "Your answers shape what we do next — it takes 2 minutes.",
        body_html = card({
            brand("#2563eb"),
            title("Help us get better"),
            p("Hi {{contact.first_name}},"),
            p("We’re always trying to improve, and the best ideas come from customers like you. Would you answer "
                .. "three quick questions?"),
            note("#2563eb", "It takes about <strong>2 minutes</strong>. Everyone who answers goes into a draw for a "
                .. "<strong>[£50 voucher]</strong>."),
            button("#2563eb", "Start the survey", "https://yourwebsite.co.uk/survey"),
            sign("Thank you,"),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nCould you answer 3 quick questions (2 minutes)? "
            .. "https://yourwebsite.co.uk/survey" .. TEXT_FOOT,
    },
    {
        name = "Appointment reminder", channel = "email",
        subject = "Reminder: your appointment on [date]",
        preview_text = "See you soon — here are the details.",
        body_html = card({
            brand("#0891b2"),
            title("See you soon, {{contact.first_name}}"),
            p("Just a friendly reminder about your upcoming appointment:"),
            note("#0891b2", "<strong>When:</strong> [Tuesday 12 November at 10:30am]<br><strong>Where:</strong> "
                .. "[Your address]<br><strong>With:</strong> [Name]"),
            p("Need to change it? Reply to this email or call us on [phone number] — we’re happy to help."),
            button("#0891b2", "Manage my booking"),
            sign("See you soon,"),
            footer(),
        }),
        body_text = "Hi {{contact.first_name}},\n\nReminder: your appointment is on [date] at [time], [address].\n"
            .. "Need to change it? Reply or call [phone number]." .. TEXT_FOOT,
    },
    {
        name = "Text message — special offer", channel = "sms",
        body_text = "Hi {{contact.first_name}}, 20% off this week with code SAVE20 at yourwebsite.co.uk. "
            .. "Reply STOP to opt out.",
    },
    {
        name = "Text message — appointment reminder", channel = "sms",
        body_text = "Hi {{contact.first_name}}, a reminder of your appointment on [date] at [time]. "
            .. "Reply to change it. Reply STOP to opt out.",
    },
    {
        name = "Text message — event", channel = "sms",
        body_text = "Hi {{contact.first_name}}, you’re invited to [event] on [date]. Save your place: "
            .. "yourwebsite.co.uk/event. Reply STOP to opt out.",
    },
}
