/**
 * Search content checks for shop products and categories (Products → Search & content).
 * The same defaults as the shop (workstation-website shop/src/lib/product-seo.ts) so the counts staff see
 * match the page. Pure: no React, no API.
 */
import type { ShopSeoBlock, ShopSeoLocale } from '@/types/shop';

export const SEO_TITLE_MAX = 60;
export const SEO_TITLE_MIN = 30;
export const SEO_DESC_MIN = 120;
export const SEO_DESC_MAX = 160;
export const SEO_BRAND = 'Workstation';

/** "<Keyword> | Workstation" — main words first (what OpsAPI uses when the title is left empty). */
export function defaultSeoTitle(keyword: string | undefined, brand = SEO_BRAND): string {
  const k = (keyword ?? '').trim();
  if (!k) return '';
  const cap = k[0].toUpperCase() + k.slice(1);
  return cap.toLowerCase().endsWith(`| ${brand.toLowerCase()}`) ? cap : `${cap} | ${brand}`;
}

const TAIL: Record<ShopSeoLocale, (price: string | null) => string> = {
  en: (p) => (p ? `From ${p} ex VAT. Built, tested and supported in the UK.` : 'Priced on quote. Built, tested and supported in the UK.'),
  fr: (p) => (p ? `À partir de ${p} HTVA. Assemblé, testé et suivi au Royaume-Uni.` : 'Prix sur devis. Assemblé, testé et suivi au Royaume-Uni.'),
  nl: (p) => (p ? `Vanaf ${p} excl. btw. Gebouwd, getest en ondersteund in het VK.` : 'Prijs op offerte. Gebouwd, getest en ondersteund in het VK.'),
};

/** The shop's default meta description: the intro (or short description) cut to fit, then the price line. */
export function defaultSeoDescription(lead: string | undefined, price: string | null, locale: ShopSeoLocale = 'en'): string {
  const tail = TAIL[locale](price);
  const room = SEO_DESC_MAX - tail.length - 1;
  let text = (lead ?? '').replace(/[#*_`>[\]]/g, '').replace(/\s+/g, ' ').trim();
  if (text.length > room) {
    const cut = text.slice(0, room);
    const sentence = cut.lastIndexOf('. ');
    text = sentence > 40 ? cut.slice(0, sentence + 1) : `${cut.slice(0, cut.lastIndexOf(' ')).replace(/[,;:\s]+$/, '')}.`;
  }
  if (text && !/[.!?]$/.test(text)) text += '.';
  return text ? `${text} ${tail}` : tail;
}

/** "{price}" in a staff description becomes the live from-price on the shop. */
export function fillPrice(text: string, price: string | null): string {
  return text.replace(/\{price\}/g, price ?? '');
}

const STOP = new Set(
  'a an the and or for of in on to with by from at uk gb your our de la le les des du et pour en un une het een van voor met en in op te'.split(' '),
);

/** The words of a keyword that matter (stop words and "UK" dropped). */
export function mainWords(keyword: string | undefined): string[] {
  return (keyword ?? '')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w.length > 1 && !STOP.has(w));
}

/** Does text contain the keyword, or at least every main word of it? */
export function containsKeyword(text: string | undefined, keyword: string | undefined): boolean {
  const t = (text ?? '').toLowerCase();
  const k = (keyword ?? '').trim().toLowerCase();
  if (!k) return true;
  if (t.includes(k)) return true;
  const words = mainWords(k);
  return words.length > 0 && words.every((w) => t.includes(w));
}

export interface SeoCheckInput {
  block: ShopSeoBlock;
  /** The H1 on the page (the product or category name). */
  h1: string;
  /** Effective title and description as the shop will show them. */
  title: string;
  description: string;
}

/** Plain-words warnings for one language. Empty = all good. */
export function seoWarnings({ block, h1, title, description }: SeoCheckInput): string[] {
  const out: string[] = [];
  if (title.length > SEO_TITLE_MAX) out.push(`Title is ${title.length} characters: Google cuts it after about ${SEO_TITLE_MAX}.`);
  else if (title.length < SEO_TITLE_MIN) out.push(`Title is short (${title.length} characters): aim for ${SEO_TITLE_MIN}–${SEO_TITLE_MAX}.`);
  if (description.length > SEO_DESC_MAX) out.push(`Description is ${description.length} characters: aim for ${SEO_DESC_MIN}–${SEO_DESC_MAX}.`);
  else if (description.length < SEO_DESC_MIN) out.push(`Description is short (${description.length} characters): aim for ${SEO_DESC_MIN}–${SEO_DESC_MAX}.`);
  const k = block.target_keyword?.trim();
  if (!k) {
    out.push('No target keyword yet: add the phrase customers search for.');
    return out;
  }
  const missing = [
    !containsKeyword(title, k) && 'title',
    !containsKeyword(h1, k) && 'page heading (H1)',
    !containsKeyword(description, k) && 'description',
    !!block.intro?.trim() && !containsKeyword(block.intro, k) && 'intro',
  ].filter(Boolean) as string[];
  if (!block.intro?.trim()) out.push('No intro yet: write 2–4 short sentences on what this lets people do.');
  if (missing.length) out.push(`The keyword (or its main words: ${mainWords(k).join(', ')}) is missing from the ${missing.join(', ')}.`);
  return out;
}
