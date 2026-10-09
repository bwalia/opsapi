/// <reference types="cypress" />

/**
 * Forms phase 2 in a browser: conditional logic, steps and a file upload on
 * the public page; the file in the response; Insights with the AI summary; a
 * form drafted by AI. Same environment as forms.cy.ts, plus:
 *   CYPRESS_FORMS_API  the API base URL (to set the form up)
 * and an API with MinIO and an AI provider (the e2e stub works).
 */

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

function api(method: string, path: string, body?: unknown) {
  return cy.request({
    method, url: `${Cypress.env('FORMS_API')}${path}`, body,
    headers: { Authorization: `Bearer ${Cypress.env('FORMS_TOKEN')}`, 'X-Namespace-Id': json(Cypress.env('FORMS_NAMESPACE')).uuid },
  });
}

describe('Forms phase 2', () => {
  before(function () {
    if (!Cypress.env('FORMS_TOKEN') || !Cypress.env('FORMS_API')) this.skip();
  });

  it('runs logic, steps and an upload, then shows the file, insights and AI summary', () => {
    api('POST', '/api/v2/forms', {
      title: `Supplier sign-up ${Date.now()}`,
      fields: [
        { type: 'boolean', label: 'Are you a company?', required: true },
        { type: 'short_text', label: 'Company name', required: true,
          logic: { match: 'all', rules: [{ field: 'are_you_a_company', op: 'eq', value: true }] } },
        { type: 'page_break', label: 'Documents' },
        { type: 'file_upload', label: 'Logo', accept: 'images', max_files: 1, max_size_mb: 2 },
      ],
    }).then(({ body }) => {
      const form = body.data;
      api('POST', `/api/v2/forms/${form.uuid}/publish`);

      // The visitor: the company question appears only after "Yes"; step 2 has the upload.
      cy.visit(`/f/${form.public_id}`);
      cy.contains('h1', 'Supplier sign-up');
      cy.contains('Company name').should('not.exist');
      cy.contains('label', 'Yes').click();
      cy.contains('label', 'Company name').should('be.visible');
      cy.contains('button', 'Next').click();
      cy.contains('[role="alert"]', 'This field is required.');
      cy.get('input[id$="-company_name"]').type('Analytical Engines');
      cy.contains('button', 'Next').click();
      cy.contains('2 of 2');
      cy.get('input[type="file"]').selectFile({
        contents: Cypress.Buffer.from('\x89PNG\r\n\x1a\nfake'), fileName: 'logo.png', mimeType: 'image/png',
      }, { force: true });
      cy.contains('li', 'logo.png');
      cy.wait(2200);
      cy.contains('button', 'Submit').click();
      cy.contains('Thanks', { timeout: 15000 });

      // Staff: the response with its file.
      cy.visit(`/dashboard/forms/${form.uuid}?tab=responses`, { onBeforeLoad: signIn });
      cy.contains('td', 'Yes', { timeout: 15000 }).click();
      cy.contains('[role="dialog"]', 'Analytical Engines');
      cy.contains('[role="dialog"] li', 'logo.png').contains('button', 'Open');
      cy.get('body').type('{esc}');

      // Insights + the AI summary (the stub model answers "Most people chose VIP").
      cy.contains('button[role="tab"]', 'Insights').click();
      cy.contains('Views');
      cy.contains('button', 'Summarise with AI').click();
      cy.contains('Most people chose VIP', { timeout: 15000 });
    });
  });

  it('drafts a form with AI and creates it', () => {
    cy.visit('/dashboard/forms', { onBeforeLoad: signIn });
    cy.contains('button', 'New form').click();
    cy.contains('button', 'Describe it, AI drafts it').click();
    cy.get('textarea').type('An event sign-up form. Make each person a lead.');
    cy.contains('button', 'Draft the form').click();
    cy.contains('li', 'Ticket', { timeout: 15000 });
    cy.contains('left out because they weren');
    cy.contains('button', 'Create this form').click();
    cy.location('pathname').should('match', /^\/dashboard\/forms\/[0-9a-f-]{36}$/);
    cy.contains('li', 'Dietary needs');
  });
});
