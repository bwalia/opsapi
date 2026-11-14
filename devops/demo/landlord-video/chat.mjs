// Shared helpers that drive the File with AI chat like a person would.
// The assistant's wording varies, so each turn reads the latest reply and answers it.
export const ANSWERS = [
  // [pattern in the assistant's question, what we type]
  [/tax year/i, null], // handled by the year quick reply
  [/how many (properties|houses|units)|number of (properties|lets)|portfolio/i,
    '100 properties in England: 80 houses let as residential homes through three letting agents, and 20 commercial units on quarterly leases.'],
  [/mortgage|finance cost|interest|loan/i,
    'Yes. Four buy-to-let and commercial mortgages. The interest for the year was £512,400; the rest of the monthly payments is capital.'],
  [/employ|salary|wages|paye|job/i, 'No employment income. Property is my only income.'],
  [/self.?employ|sole trader|business/i, 'No, I am not self-employed. All my income is rent.'],
  [/savings|interest from|bank interest|dividend/i, 'No savings interest or dividends worth declaring this year.'],
  [/gift aid|pension|charit/i, 'No Gift Aid or pension contributions to declare.'],
  [/jointly|joint|own(ed)? with|share/i, 'I own all of them in my sole name, 100%.'],
  [/furnished|holiday let|fhl/i, 'They are long-term lets, not furnished holiday lets.'],
  [/rent.?a.?room/i, 'No, I do not let rooms in my own home.'],
  [/name|call you/i, 'Jordan Ashby.'],
];

export async function lastAssistant(p) {
  const bubbles = p.locator('div.flex.justify-start > div.rounded-2xl');
  const n = await bubbles.count();
  return n ? (await bubbles.nth(n - 1).innerText()).trim() : '';
}

export async function waitIdle(p, timeout = 600000) {
  // Idle = no "…thinking" bubble for ~2s in a row (the bubble can flicker between turns).
  const start = Date.now();
  await p.waitForTimeout(1200);
  let quiet = 0;
  while (Date.now() - start < timeout) {
    const thinking = await p.getByText(/^(…|\.\.\.)thinking$/).count();
    quiet = thinking ? 0 : quiet + 1;
    if (quiet >= 3) return;
    await p.waitForTimeout(700);
  }
  throw new Error('assistant still thinking after ' + timeout / 1000 + 's');
}

export async function quickReplies(p) {
  return p.locator('form').locator('xpath=preceding-sibling::div[1]').getByRole('button').allInnerTexts().catch(() => []);
}
