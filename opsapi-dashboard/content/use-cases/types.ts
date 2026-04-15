export interface UseCaseStepDefinition {
  title: string;
  description: string;
  match: { method: string; path: string };
}

export interface UseCaseDefinition {
  slug: string;
  title: string;
  subtitle: string;
  intro: string;
  steps: UseCaseStepDefinition[];
}
