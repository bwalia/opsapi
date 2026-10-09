--[[
    Starter forms (GET /api/v2/forms/templates; the agent's create_form can
    start from one). Each is a title, description, fields and targets; it is
    normalized like any other form when used, so targets the deployment lacks
    are dropped by the caller (FormQueries.create).
]]

local Templates = {
    {
        key = "contact",
        title = "Contact us",
        description = "A simple contact form: name, email and a message.",
        targets = {},
        fields = {
            { type = "name", label = "Your name", required = true },
            { type = "email", label = "Email", required = true },
            { type = "phone", label = "Phone", maps_to = "phone" },
            { type = "long_text", label = "How can we help?", required = true, maps_to = "notes" },
        },
    },
    {
        key = "lead_capture",
        title = "Get a quote",
        description = "Capture enquiries as leads, with company, budget and timeline.",
        targets = { "lead" },
        fields = {
            { type = "short_text", label = "Company", maps_to = "company" },
            { type = "short_text", label = "Job title", maps_to = "job_title" },
            { type = "phone", label = "Phone", maps_to = "phone" },
            { type = "single_select", label = "Budget",
              options = { "Under £5,000", "£5,000 – £20,000", "Over £20,000" } },
            { type = "radio", label = "When do you want to start?", options = { "Now", "Within 3 months", "Later" } },
            { type = "long_text", label = "Tell us about your project", maps_to = "notes" },
            { type = "hidden", label = "Campaign", param = "utm_campaign" },
        },
    },
    {
        key = "customer_signup",
        title = "Customer sign-up",
        description = "New customers register their details.",
        targets = { "customer" },
        fields = {
            { type = "phone", label = "Phone", maps_to = "phone" },
            { type = "address", label = "Address" },
            { type = "consent", label = "Marketing",
              text = "Send me news and offers by email. I can unsubscribe at any time.",
              maps_to = "marketing_consent" },
        },
    },
    {
        key = "event_registration",
        title = "Event registration",
        description = "Register attendees with ticket type and dietary needs.",
        targets = {},
        fields = {
            { type = "name", label = "Name", required = true },
            { type = "email", label = "Email", required = true },
            { type = "radio", label = "Ticket", required = true, options = { "Standard", "VIP" } },
            { type = "multi_select", label = "Dietary requirements",
              options = { "Vegetarian", "Vegan", "Gluten free", "Halal" } },
            { type = "long_text", label = "Anything else we should know?" },
        },
    },
    {
        key = "feedback",
        title = "Customer feedback",
        description = "Rate the experience and leave comments.",
        targets = {},
        fields = {
            { type = "rating", label = "How would you rate us?", required = true, scale = 5 },
            { type = "radio", label = "Would you recommend us to a friend?", options = { "Yes", "Maybe", "No" } },
            { type = "long_text", label = "What could we do better?" },
            { type = "email", label = "Email (if you'd like a reply)" },
        },
    },
    {
        key = "job_application",
        title = "Job application",
        description = "Applicants send their details, CV link and experience.",
        targets = {},
        fields = {
            { type = "name", label = "Full name", required = true },
            { type = "email", label = "Email", required = true },
            { type = "phone", label = "Phone", required = true },
            { type = "url", label = "Link to your CV or LinkedIn", required = true },
            { type = "number", label = "Years of experience", validation = { min = 0, max = 60, integer = true } },
            { type = "long_text", label = "Why do you want this role?" },
        },
    },
    {
        key = "appointment_request",
        title = "Appointment request",
        description = "Visitors ask for an appointment on a preferred date and time.",
        targets = {},
        fields = {
            { type = "name", label = "Name", required = true },
            { type = "email", label = "Email", required = true },
            { type = "phone", label = "Phone", maps_to = "phone" },
            { type = "date", label = "Preferred date", required = true },
            { type = "time", label = "Preferred time" },
            { type = "long_text", label = "Reason for the appointment", maps_to = "notes" },
        },
    },
}

local by_key = {}
for _, t in ipairs(Templates) do by_key[t.key] = t end

return {
    list = Templates,
    get = function(key) return by_key[key] end,
}
