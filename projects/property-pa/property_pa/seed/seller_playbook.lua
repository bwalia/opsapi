-- The first seller playbook (build prompt Week 1): company rules the Seller PA follows, seeded as approved
-- version 1 the first time a workspace sets the PA up. After that they are the workspace's own: edits make a new
-- version that a manager approves. Short rules with a trigger and a reason — the PA quotes the key when it uses one.
return {
    { key = "seller_first_call_discovery", domain = "seller", title = "First call: discover before you value",
      rule = "On a first seller call, find out why they are selling, their timescale, who else must agree, and what "
          .. "they think it is worth, before talking about our price.",
      rationale = "Motivation, timing and decision makers decide whether a deal is possible; price comes last.",
      triggers = { "first_call", "new_seller" } },
    { key = "seller_decision_makers", domain = "seller", title = "Every decision maker by name",
      rule = "Record every person who must agree to the sale by name and role. Never treat an offer as agreed "
          .. "until each of them has said yes.",
      rationale = "Deals fall through when a partner, co-owner or executor was never asked.",
      triggers = { "decision_makers", "offer" } },
    { key = "seller_expectation_vs_position", domain = "seller", title = "Their number, our number, kept apart",
      rule = "Keep the seller's stated expectation and our assessed position as separate facts. Our position is a "
          .. "judgement: label it unconfirmed until the agent confirms it.",
      rationale = "Mixing what a seller said with what we think leads to wrong offers and lost trust.",
      triggers = { "price", "valuation", "offer" } },
    { key = "seller_no_higher_offer", domain = "seller", title = "Ask questions, don't raise the offer",
      rule = "When a seller pushes back on price, suggest questions that uncover the real constraint (timing, "
          .. "chain, debts, condition). The PA never suggests a higher offer; only a person with authority can.",
      rationale = "Offers are a human decision with financial authority (authority level 5 is off).",
      triggers = { "objection", "price", "offer" } },
    { key = "seller_follow_up_promise", domain = "seller", title = "Keep every promise with a date",
      rule = "When we promise to call back, send something or check something, create a next action with an owner, "
          .. "a due time and the reason, before the call is closed.",
      rationale = "Missed call-backs are the most common reason sellers go cold.",
      triggers = { "promise", "call_back", "next_action" } },
    { key = "seller_competing_valuation", domain = "seller", title = "Competing valuations are facts with a source",
      rule = "Record another agent's valuation as an event with who gave it and when. Do not argue with it on the "
          .. "call; explain our figure in writing afterwards.",
      rationale = "Sellers anchor on the highest number; a calm written comparison works better than a debate.",
      triggers = { "valuation", "competitor" } },
    { key = "seller_speed_matters", domain = "seller", title = "Speed is part of the offer",
      rule = "If the seller values speed, record their deadline. A quick, certain completion can justify a lower "
          .. "price; say so with our real completion timescale, never a promise we cannot keep.",
      rationale = "Certainty and speed are what a cash buyer offers instead of the top price.",
      triggers = { "deadline", "speed", "offer" } },
    { key = "seller_cold_after_14_days", domain = "seller", title = "Re-engage after 14 quiet days",
      rule = "If there has been no meaningful contact with an open seller for 14 days, propose a short, personal "
          .. "follow-up that refers to the last conversation.",
      rationale = "Warm sellers go cold within two weeks without contact.",
      triggers = { "follow_up", "cold" } },
    { key = "escalate_to_manager", domain = "general", title = "Escalate with a question, not a problem",
      rule = "Hand off to a manager with the context, the exact question and the PA's recommendation. Offers above "
          .. "the agent's authority, legal questions and complaints always go to a manager.",
      rationale = "Managers answer fastest when the question is specific and the facts are attached.",
      triggers = { "handoff", "authority", "complaint" } },
    { key = "grounded_or_silent", domain = "general", title = "Grounded or silent",
      rule = "Only state facts that are in the record, with where they came from. If a fact is not recorded, say it "
          .. "is not known and suggest how to find out. Inferences are labelled as such.",
      rationale = "One invented fact destroys trust in everything else the PA says.",
      triggers = { "always" } },
}
