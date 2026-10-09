/// <reference types="cypress" />

/**
 * Forms end to end, in a browser: build a form that creates customers,
 * publish it, fill it in on its public link, and see the response with the
 * customer it created.
 *
 * Needs a signed-in workspace owner (the app's 2FA login is skipped by
 * putting their session in storage):
 *   CYPRESS_FORMS_TOKEN      a JWT for the owner
 *   CYPRESS_FORMS_USER       {"uuid","email","first_name","last_name"} (JSON)
 *   CYPRESS_FORMS_NAMESPACE  {"uuid","name","slug"} (JSON) of their workspace
 * and an API with PROJECT_CODE including forms and ecommerce/billing.
 */

const title = `Quote request ${Date.now()}`;

// Cypress parses JSON-looking env values itself.
const json = (v: unknown) => (typeof v === 'string' ? JSON.parse(v) : v);

function signIn(win: Window) {
  const token = Cypress.env('FORMS_TOKEN');
  const user = json(Cypress.env('FORMS_USER'));
  const ns = json(Cypress.env('FORMS_NAMESPACE'));
  win.localStorage.setItem('auth_token', token);
  win.localStorage.setItem('auth_user', JSON.stringify(user));
  win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token, user, isAuthenticated: true }, version: 0 }));
  win.localStorage.setItem('current_namespace', JSON.stringify(ns));
  win.localStorage.setItem('namespace-storage', JSON.stringify({
    state: { currentNamespace: ns, namespacePermissions: null, isNamespaceOwner: true, userSettings: null }, version: 0,
  }));
}

describe('Forms', () => {
  it('builds, publishes, fills in and shows a response with its customer', () => {
    cy.visit('/dashboard/forms', { onBeforeLoad: signIn });
    cy.contains('h1', 'Forms').should('be.visible');

    // New blank form
    cy.contains('button', 'New form').click();
    cy.get('input[placeholder="e.g. Get a quote"]').type(title);
    cy.contains('button', 'Blank form').click();
    cy.contains('button', 'Create and edit').click();
    cy.location('pathname').should('match', /^\/dashboard\/forms\/[0-9a-f-]{36}$/).as('editor');

    // Create a customer from each response: name + email are added and locked.
    cy.get('[role="switch"][aria-label="Create a customer"]').click();
    cy.contains('[role="status"]', 'Saved', { timeout: 15000 });
    cy.get('ul[aria-label="Questions"] li').should('have.length', 2);
    cy.get('ul[aria-label="Questions"]').within(() => {
      cy.contains('li', 'Name').should('contain', 'locked');
      cy.contains('li', 'Email').should('contain', 'locked');
      cy.get('button[aria-label="Locked: needed by \\"Create records\\""]').should('be.disabled');
    });

    // Add a question and rename it.
    cy.contains('button', 'Short text').click();
    cy.get('input#question').clear().type('Company');
    cy.contains('[role="status"]', 'Saved', { timeout: 15000 });
    cy.get('ul[aria-label="Questions"] li').should('have.length', 3);

    // Publish and read the link.
    cy.contains('button', /^Publish$/).click();
    cy.contains('Published — your form is live');
    cy.get('input[aria-label="Public link"]').invoke('val').then((link) => {
      const path = new URL(String(link)).pathname;
      expect(path).to.match(/^\/f\/[A-Za-z0-9]+$/);

      // A visitor fills it in (no login).
      cy.clearLocalStorage();
      cy.visit(path);
      cy.contains('h1', title);
      cy.get('input[aria-label="First name"]').type('Ada');
      cy.get('input[aria-label="Last name"]').type('Lovelace');
      cy.get('input[type="email"]').type(`ada.${Date.now()}@example.com`);
      cy.get('input[id$="-company"]').type('Analytical Engines');
      cy.wait(2500); // the server ignores forms submitted faster than a person could
      cy.contains('button', 'Submit').click();
      cy.contains('Thanks', { timeout: 15000 });
    });

    // Back in the dashboard: the response, with the customer it created.
    cy.get<string>('@editor').then((editor) => cy.visit(`${editor}?tab=responses`, { onBeforeLoad: signIn }));
    cy.contains('td', 'Analytical Engines', { timeout: 15000 }).click();
    cy.contains('[role="dialog"]', 'Ada Lovelace');
    cy.contains('[role="dialog"] a', 'Customer created').should('have.attr', 'href').and('match', /\/dashboard\/customers\//);
  });
});
