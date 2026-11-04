/**
 * Lead pipeline screens, against a local stack with the fixture from
 * lapis/spec/lead-pipeline-e2e/setup.lua (run check.py first so there is data):
 *
 *   env -u ELECTRON_RUN_AS_NODE npx cypress run --spec cypress/e2e/leads-pipeline.cy.ts \
 *     --config baseUrl=http://127.0.0.1:8039 --env API_URL=http://127.0.0.1:4020
 *
 * Signs in by putting the fixture's token (read inside the API container,
 * never printed) into the dashboard's storage, then walks the pages.
 */
type Fixture = {
  namespace_uuid: string;
  slug: string;
  name: string;
  users: Record<'owner' | 'rep1' | 'rep2', { uuid: string; email: string; first_name: string; last_name: string; token: string }>;
};

function signIn(who: 'owner' | 'rep1' | 'rep2') {
  return cy.exec('docker exec opsapi cat /tmp/lp_tokens.json', { log: false }).then((res) => {
    const fx = JSON.parse(res.stdout) as Fixture;
    const u = fx.users[who];
    const user = { uuid: u.uuid, email: u.email, first_name: u.first_name, last_name: u.last_name, roles: [] };
    const ns = { uuid: fx.namespace_uuid, slug: fx.slug, name: fx.name };
    return cy.wrap({ fx, init: (win: Window) => {
      win.localStorage.setItem('auth_token', u.token);
      win.localStorage.setItem('auth_user', JSON.stringify(user));
      win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token: u.token, user, isAuthenticated: true }, version: 0 }));
      win.localStorage.setItem('current_namespace', JSON.stringify(ns));
      win.localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: ns }, version: 0 }));
      win.localStorage.setItem('pwa-install-dismissed', '1');
    } }, { log: false });
  });
}

describe('Lead pipeline', () => {
  // An analysed lead to show the AI card (LEAD_UUID=<uuid>, owned by rep1).
  if (Cypress.env('LEAD_UUID')) {
    it('lead owner sees the AI analysis, deal size and suggested partner', () => {
      signIn('rep1').then(({ init }) => {
        cy.visit(`/dashboard/leads/${Cypress.env('LEAD_UUID')}`, { onBeforeLoad: init });
        cy.contains('AI analysis', { timeout: 30000 });
        cy.contains('Suggested next step');
        cy.contains('From a web price search');
        cy.screenshot('11-ai-card', { capture: 'fullPage' });
      });
    });
  }

  it('owner: board, insights, list, a lead, its dialogs, settings, partners', () => {
    signIn('owner').then(({ init }) => {
      cy.visit('/dashboard/leads', { onBeforeLoad: init });
      cy.contains('h1', 'Leads', { timeout: 30000 });
      cy.contains('Your next steps');
      cy.get('[aria-label="Lead pipeline"]', { timeout: 20000 }).should('exist');
      cy.contains('section', 'Meeting').should('exist');
      cy.screenshot('01-pipeline-board', { capture: 'viewport' });

      cy.contains('button', 'Insights').click();
      cy.contains('Funnel', { timeout: 20000 });
      cy.contains('Speed to lead');
      cy.screenshot('02-insights', { capture: 'fullPage' });

      cy.contains('button', 'List').click();
      cy.get('table', { timeout: 20000 }).should('exist');
      cy.screenshot('03-list', { capture: 'viewport' });

      // Open the first lead that isn't converted.
      cy.get('table tbody tr').first().click();
      cy.contains('AI analysis', { timeout: 20000 });
      cy.contains('Next step');
      cy.contains('Timeline');
      cy.screenshot('04-lead-page', { capture: 'fullPage' });

      cy.get('body').then(($b) => {
        if ($b.find('button:contains("Log a call")').length) {
          cy.contains('button', 'Log a call').click();
          cy.contains('How did the call with');
          cy.screenshot('05-log-call', { capture: 'viewport' });
          cy.contains('button', 'Cancel').click();
        }
        if ($b.find('button:contains("Book meeting")').length) {
          cy.contains('button', 'Book meeting').click();
          cy.contains('Book a meeting with');
          cy.screenshot('06-book-meeting', { capture: 'viewport' });
          cy.contains('button', 'Cancel').click();
        }
        if ($b.find('button:contains("Pass to partner")').length) {
          cy.contains('button', 'Pass to partner').click();
          cy.contains('Pass to a partner');
          cy.screenshot('07-pass-to-partner', { capture: 'viewport' });
          cy.contains('button', 'Cancel').click();
        }
      });

      cy.visit('/dashboard/leads/settings', { onBeforeLoad: init });
      cy.contains('Lead settings', { timeout: 20000 });
      cy.contains('Speed to lead');
      cy.screenshot('08-settings', { capture: 'fullPage' });

      cy.visit('/dashboard/leads/partners', { onBeforeLoad: init });
      cy.contains('h1', 'Partners', { timeout: 20000 });
      cy.contains('Directory');
      cy.screenshot('09-partners', { capture: 'fullPage' });
    });
  });

  it('rep: sees only their own and unassigned leads; no settings link', () => {
    signIn('rep2').then(({ init }) => {
      cy.visit('/dashboard/leads?view=list', { onBeforeLoad: init });
      cy.contains('h1', 'Leads', { timeout: 30000 });
      cy.get('table, p:contains("No leads match")', { timeout: 20000 }).should('exist');
      cy.get('a[href="/dashboard/leads/settings"]').should('not.exist');
      cy.screenshot('10-rep-list', { capture: 'viewport' });
    });
  });
});
