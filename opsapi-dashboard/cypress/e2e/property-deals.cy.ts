/**
 * Property Deals — the SPEC §5 scenario in the browser (Prompt 2 "Done when"):
 * the deal shows red, the EPC task is overdue, an AI chase draft appears in Approvals,
 * approving it records the chase, the Exchange move is blocked with the AML reason shown,
 * and a user of another workspace sees none of it.
 *
 * Needs the Property Deals sandbox API (projects/property-deals/spec/run.sh with KEEP=1) and the
 * dashboard pointed at it:
 *   CYPRESS_API_URL=http://127.0.0.1:<api port> CYPRESS_PD_MOCK=http://127.0.0.1:<mock port> \
 *   CYPRESS_PD_JWT_SECRET=… CYPRESS_PD_PSQL="docker exec -i pd-pg-<id> psql -U postgres -d e2e -tA -c" \
 *   npx cypress run --spec cypress/e2e/property-deals.cy.ts
 * The seed (spec/web_seed.py) builds a fresh workspace each run.
 */

type Session = { token: string; user: Record<string, unknown>; namespace: { uuid: string; name: string; slug: string } };
type Seed = { workspace: string; deal: string; epc_task: string; chase_task: string; operator: Session; manager: Session; outsider: Session };

let seed: Seed;

function visitAs(s: Session, path: string) {
  cy.visit(path, {
    onBeforeLoad(win) {
      win.localStorage.clear();
      win.localStorage.setItem('auth_token', s.token);
      win.localStorage.setItem('auth_user', JSON.stringify(s.user));
      win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token: s.token, user: s.user, isAuthenticated: true }, version: 0 }));
      win.localStorage.setItem('current_namespace', JSON.stringify(s.namespace));
      win.localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: s.namespace, namespacePermissions: null, isNamespaceOwner: false, userSettings: null }, version: 0 }));
      win.localStorage.setItem('pd-tour-seen', '1');
    },
  });
}

describe('Property Deals — SPEC §5 scenario in the browser', () => {
  before(() => {
    cy.exec('python3 -I ../projects/property-deals/spec/web_seed.py', {
      timeout: 180000,
      env: {
        PD_API: Cypress.env('API_URL'),
        PD_JWT_SECRET: Cypress.env('PD_JWT_SECRET'),
        PD_PSQL: Cypress.env('PD_PSQL'),
        PD_MOCK: Cypress.env('PD_MOCK'),
      },
    }).then((r) => {
      seed = JSON.parse(r.stdout) as Seed;
    });
  });

  it('Today: the overdue EPC task and the red deal', () => {
    visitAs(seed.operator, '/dashboard/property-deals/today');
    cy.contains('h1', 'Today', { timeout: 20000 });
    cy.contains('Book an EPC assessor').parents('li').within(() => {
      cy.contains(/overdue/);
    });
    cy.contains('Deals at risk').parent().contains('7 Mill Lane');
  });

  it('Deal page: red health, the reasons, money at risk', () => {
    visitAs(seed.operator, `/dashboard/property-deals/deals/${seed.deal}`);
    cy.contains('h1', '7 Mill Lane', { timeout: 20000 });
    cy.get('[data-tour="deal-header"]').within(() => {
      cy.contains('Red');
      cy.contains('Money at risk');
    });
  });

  it('Let AI do it → a chase draft waits in Approvals; approving it sends and logs the chase', () => {
    visitAs(seed.operator, `/dashboard/property-deals/deals/${seed.deal}`);
    cy.contains("Chase seller's solicitor on enquiries", { timeout: 20000 }).parents('li').within(() => {
      cy.contains('button', 'Let AI do it').click();
    });
    cy.contains('Draft ready', { timeout: 60000 });

    visitAs(seed.manager, '/dashboard/property-deals/approvals');
    cy.contains('Chase seller solicitor', { timeout: 20000 }).click();
    cy.get('[data-tour="approval-editor"]').within(() => {
      cy.get('textarea').first().should('contain.value', 'FENSA certificate').and('contain.value', 'Boundary dispute with No. 9');
      cy.contains('Agent:').contains('Legal chaser');
      cy.contains('button', /^Approve$/).click();
    });
    cy.contains('Approved and done', { timeout: 20000 });

    visitAs(seed.operator, `/dashboard/property-deals/deals/${seed.deal}`);
    cy.contains('[role="tab"]', 'Chase log', { timeout: 20000 }).click();
    cy.contains('Open enquiries').parents('li').within(() => {
      cy.contains('approved draft');
      cy.contains(/Sent|Replied/i);
    });
  });

  it('Moving to Exchange is blocked with the AML reason', () => {
    visitAs(seed.operator, `/dashboard/property-deals/deals/${seed.deal}`);
    cy.get('[data-testid="stage-picker"]', { timeout: 20000 }).select('Exchange');
    cy.contains('button', /^Move$/).click();
    cy.contains('Not ready for Exchange yet');
    cy.contains('AML customer due diligence — buyer');
  });

  it('Another workspace sees none of it', () => {
    visitAs(seed.outsider, `/dashboard/property-deals/deals/${seed.deal}`);
    cy.contains(/not found|Deal not found/i, { timeout: 20000 });
    visitAs(seed.outsider, '/dashboard/property-deals/today');
    cy.contains('h1', 'Today', { timeout: 20000 });
    cy.contains('7 Mill Lane').should('not.exist');
  });

  it('Every page opens for a manager (smoke + screenshots)', () => {
    const pages: [string, string][] = [
      ['today', 'Today'], ['deals', 'Deals'], ['approvals', 'Approvals'], ['map', 'Deal finder'], ['buyers', 'Buyers'],
      ['suppliers', 'Suppliers'], ['compliance', 'Compliance'], ['reports', 'Deal reports'], ['settings', 'Deals settings'],
    ];
    for (const [path, title] of pages) {
      visitAs(seed.manager, `/dashboard/property-deals/${path}`);
      cy.contains('h1', title, { timeout: 20000 });
      cy.get('[role="alert"]').should('not.exist');
      cy.screenshot(`page-${path}`, { capture: 'viewport' });
    }
  });

  it('The guided tour walks every page', () => {
    visitAs(seed.manager, '/dashboard/property-deals/today');
    cy.contains('button', 'Take the tour', { timeout: 20000 }).click();
    cy.get('[role="dialog"]#pd-tour-title, [aria-labelledby="pd-tour-title"]').should('be.visible');
    const steps = 24;
    for (let i = 1; i <= steps; i++) {
      cy.get('[aria-labelledby="pd-tour-title"]', { timeout: 20000 }).should('contain.text', `${i} / ${steps}`);
      if (i === 1 || i % 4 === 0 || i === steps) cy.screenshot(`tour-${i}`, { capture: 'viewport' });
      cy.get('[aria-labelledby="pd-tour-title"]').contains('button', i === steps ? 'Finish' : 'Next').click();
    }
    cy.get('[aria-labelledby="pd-tour-title"]').should('not.exist');
  });
});

