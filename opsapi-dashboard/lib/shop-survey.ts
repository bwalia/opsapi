/**
 * Plain-words labels for the shop's "What do I need?" survey (workstation-website shop/survey/what-do-i-need.html).
 * The survey sends short keys (question "job", answer "team"); unknown keys are shown as sent.
 */

export const SURVEY_QUESTIONS: Record<string, { label: string; options: Record<string, string> }> = {
  job: {
    label: 'What will your AI do?',
    options: { team: 'Private AI for my team', tune: 'Fine-tune models', train: 'Train models', sell: 'Sell GPU capacity', unsure: 'Not sure yet' },
  },
  who: {
    label: 'Who will use it?',
    options: { pilot: 'A pilot (1–10 people)', team: 'A team (10–100)', company: 'The whole company (100–1,000)', platform: 'A platform (1,000+)' },
  },
  size: {
    label: 'How big are the models?',
    options: { small: 'Small (up to 30B)', medium: 'Medium (around 70B)', large: 'Large (120B–400B)', frontier: 'Frontier (400B+)', unsure: 'Not sure' },
  },
  where: {
    label: 'Where will it live?',
    options: { office: 'Our office or server room', colo: 'A colocation rack', site: 'We need a site and power', open: 'Not decided' },
  },
  cond: {
    label: 'New or refurbished?',
    options: { new: 'New only', mix: 'Best value mix', refurb: 'Refurbished first' },
  },
  budget: {
    label: 'Budget',
    options: { b25: 'Up to £25k', b100: '£25k–£100k', b500: '£100k–£500k', b2m: '£500k–£2m', bmax: '£2m+', help: 'Help me set one' },
  },
  when: {
    label: 'When do they need it?',
    options: { d6: 'Within 6 weeks', d3: 'Within 3 months', d12: 'Within 12 months', d13: '12 months or more' },
  },
};

export const SURVEY_QUESTION_ORDER = ['job', 'who', 'size', 'where', 'cond', 'budget', 'when'];

export const SURVEY_PRODUCTS: Record<string, string> = {
  p32: 'RTX PRO 4500',
  p48: 'RTX PRO 5000',
  p80: 'H100 PCIe',
  p96: 'RTX PRO 6000',
  p128: 'DGX Spark',
  p768: '4U server, 8× RTX PRO 6000',
  p784: 'DGX Station GB300',
  p1434: 'HGX B200 8-GPU server',
};

export const SURVEY_STAGES: Record<string, string> = {
  view: 'Opened the survey',
  start: 'Started answering',
  result: 'Saw a recommendation',
  lead: 'Sent their build',
  apply: 'Started joining Trade',
};

export const questionLabel = (q?: string | null) => (q ? SURVEY_QUESTIONS[q]?.label ?? q : 'Unknown question');
export const answerLabel = (q: string | null | undefined, a: string) => (q && SURVEY_QUESTIONS[q]?.options[a]) || a;
export const productLabel = (p?: string | null) => (p ? SURVEY_PRODUCTS[p] ?? p : 'Unknown');
