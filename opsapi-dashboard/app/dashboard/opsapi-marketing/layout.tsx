import MarketingJourney from '@/components/opsapi-marketing/MarketingJourney';

/** Every Marketing page starts with the step bar: where you are and what to do next. */
export default function MarketingLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <MarketingJourney />
      {children}
    </>
  );
}
