/// <reference types="cypress" />

/**
 * The built-in runner (docs/AI_RUNNER.md §28) in the browser: Runners & sources shows it (always on, no token, no
 * revoke) with its GitHub section; Start with AI picks it when no machine is online, with the model and "No
 * repository", and the run goes all the way on the server's real AI model (the plan lands on the task as a comment);
 * the GitHub callback page explains each way GitHub can send someone back; the platform page shows the GitHub App
 * form and the built-in limits, and saving the other settings never sends the GitHub App back (that would clear it).
 *
 * Needs an API with the ai_runner plugin (projects/ai-runner), kanban and an AI model (OLLAMA_URL), and the dashboard
 * pointed at it, with the same env as ai-runner.cy.ts:
 *   CYPRESS_API_URL, CYPRESS_AIR_TOKEN (a workspace owner), CYPRESS_AIR_USER, CYPRESS_AIR_NAMESPACE
 *   npx cypress run --spec cypress/e2e/ai-runner-builtin.cy.ts
 * The workspace should have no machine runner online (the Start dialog would pick that one first). Each run creates
 * its own project and task.
 */

type Ns = { uuid: string; name: string; slug: string };
const json = (v: unknown) => (typeof v === 'string' ? JSON.parse(v) : v);
const api = (path: string) => `${Cypress.env('API_URL')}${path}`;
const stamp = Date.now();
const taskTitle = `Plan the release notes ${stamp}`;
let ns: Ns;
let projectUuid = '';
let taskUuid = '';

function signIn(win: Window) {
  const token = Cypress.env('AIR_TOKEN');
  const user = json(Cypress.env('AIR_USER'));
  win.localStorage.setItem('auth_token', token);
  win.localStorage.setItem('auth_user', JSON.stringify(user));
  win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token, user, isAuthenticated: true }, version: 0 }));
  win.localStorage.setItem('current_namespace', JSON.stringify(ns));
  win.localStorage.setItem('namespace-storage', JSON.stringify({
    state: { currentNamespace: ns, namespacePermissions: null, isNamespaceOwner: true, userSettings: null }, version: 0,
  }));
}
const visit = (path: string) => cy.visit(path, { onBeforeLoad: signIn });

function asUser(method: string, path: string, body?: Record<string, unknown>, form = false, failOnStatusCode = true) {
  return cy.request({
    method, url: api(path), body, form, failOnStatusCode,
    headers: { Authorization: `Bearer ${Cypress.env('AIR_TOKEN')}`, 'X-Namespace-Id': ns.uuid },
  });
}

describe('AI Runs: the built-in runner', () => {
  before(function () {
    if (!Cypress.env('AIR_TOKEN')) this.skip();
    ns = json(Cypress.env('AIR_NAMESPACE')) as Ns;
    const user = json(Cypress.env('AIR_USER')) as { uuid: string };
    asUser('PUT', '/api/v2/namespace/plugins/ai_runner', { enabled: true });
    asUser('POST', '/api/v2/kanban/projects', { name: `Built-in e2e ${stamp}` }, true).then((res) => {
      projectUuid = res.body.data.uuid;
      return asUser('GET', `/api/v2/kanban/projects/${projectUuid}/boards`);
    }).then((res) => asUser('POST', `/api/v2/kanban/boards/${res.body.data[0].uuid}/tasks`, {
      title: taskTitle, assignee_uuids: JSON.stringify([user.uuid]),
      description: 'Plan the release notes for version 2.0: list the sections they need, and post the plan as a short comment.',
    }, true)).then((res) => { taskUuid = res.body.data.uuid; });
  });

  beforeEach(() => cy.viewport(1280, 900));

  it('lists the built-in runner: always on, no token, no revoke, with its GitHub section', () => {
    visit('/dashboard/ai-runner/runners');
    cy.contains('h1', 'Runners & sources', { timeout: 20000 });
    cy.get('[data-testid="air-builtin"]', { timeout: 20000 }).within(() => {
      cy.contains('Built-in runner: no machine needed');
      cy.contains('Online');
      // GitHub: set up by a platform admin (a link to the platform page) or ready to connect.
      cy.contains(/AI Runs platform settings|Connect GitHub|Connect another account/);
    });
    cy.contains('tr', 'OpsAPI built-in').within(() => {
      cy.contains('Built-in');
      cy.contains('Always on');
      cy.contains('Inside OpsAPI');
      cy.contains('button', 'Access');
      cy.contains('button', 'Rotate token').should('not.exist');
      cy.contains('button', 'Revoke').should('not.exist');
    });
    cy.screenshot('ai-runner-builtin-runners', { capture: 'viewport' });
  });

  it('starts a task on the built-in runner when no machine is online, and the plan lands on the task', () => {
    visit(`/dashboard/projects/${projectUuid}/tasks/${taskUuid}`);
    cy.contains('h1', taskTitle, { timeout: 20000 });
    cy.contains('button', 'Start with AI').click();
    cy.get('[role="dialog"]').within(() => {
      // With a web terminal in the workspace, step 1 asks how first: choose "Let AI do it".
      cy.get('[data-testid="air-steps"]', { timeout: 30000 }).then(($s) => {
        if ($s.text().includes('How')) {
          cy.get('[data-testid="air-how-run"]').click();
          cy.contains('button', 'Next').click();
        }
      });
      cy.get('#air-runner', { timeout: 30000 }).find('option:selected').should('contain', 'OpsAPI built-in (no machine needed)');
      cy.contains('Inside OpsAPI on an AI model');
      cy.get('#air-profile').find('option:selected').should('contain', 'Platform model');
      cy.get('#air-model').should('not.exist');
      cy.get('#air-repo').should('have.value', 'none').find('option:selected').should('contain', 'No repository');
      cy.contains('button', 'Next').click();
      cy.get('[data-testid="air-check"]', { timeout: 20000 }).should('contain', 'answer, plan and subtasks on the task');
      cy.contains('summary', 'The instructions the AI gets').click();
      cy.get('#air-prompt, pre[aria-label="The instructions the AI gets"]').should(($el) => {
        expect(($el.val() as string) || $el.text()).to.contain('no repository');
      });
      cy.screenshot('ai-runner-builtin-start', { capture: 'viewport' });
      cy.contains('button', 'Start the AI').should('not.be.disabled').click();
    });
    cy.location('pathname', { timeout: 20000 }).should('match', /^\/dashboard\/ai-runner\/runs\/[0-9a-f-]{36}$/);
    cy.contains('No repository', { timeout: 20000 });
    // The real model: give it a few minutes on shared hardware.
    cy.contains('Succeeded', { timeout: 300000 });
    cy.contains('get_task');
    cy.screenshot('ai-runner-builtin-run', { capture: 'viewport' });
    asUser('GET', `/api/v2/kanban/tasks/${taskUuid}/comments`).then((res) => {
      const texts = JSON.stringify(res.body.data);
      expect(texts).to.contain('[AI run]');
    });
  });

  it('explains every way GitHub sends people back', () => {
    visit('/dashboard/ai-runner/github');
    cy.get('[data-testid="air-github-outcome"]', { timeout: 20000 }).should('contain', 'Nothing to connect here');
    cy.contains('a', 'Back to Runners & sources');
    visit('/dashboard/ai-runner/github?setup_action=request');
    cy.get('[data-testid="air-github-outcome"]', { timeout: 20000 }).should('contain', 'organisation owner for approval');
    visit('/dashboard/ai-runner/github?error=access_denied&error_description=The+user+has+denied+your+application+access');
    cy.get('[data-testid="air-github-outcome"]', { timeout: 20000 }).should('contain', 'denied your application access');
    // A code with a state this server never signed: refused (or GitHub isn't set up here at all).
    visit('/dashboard/ai-runner/github?code=x&state=not-a-state');
    cy.get('[data-testid="air-github-outcome"]', { timeout: 20000 }).should('have.attr', 'role', 'alert')
      .invoke('text').should('match', /expired or was started elsewhere|isn.t set up/);
  });

  it('shows the GitHub App and the built-in limits on the platform page; saving the rest never sends the App', function () {
    asUser('GET', '/api/v2/ai-runner/platform/settings', undefined, false, false).then((res) => {
      if (res.status === 403) {
        cy.log('Not a platform admin: the platform settings page is not covered here');
        this.skip();
      }
      const before = res.body.data.builtin_max_steps as number;
      cy.intercept('PUT', '**/api/v2/ai-runner/platform/settings').as('save');
      visit('/dashboard/ai-runner/platform');
      cy.contains('h1', 'AI Runs platform settings', { timeout: 20000 });
      cy.get('#air-p-builtin_max_runs').should('have.value', String(res.body.data.builtin_max_runs));
      cy.get('#air-p-builtin_max_steps').clear().type(String(before === 200 ? 199 : before + 1));
      cy.contains('GitHub App');
      cy.get('[data-testid="air-gh-callback"]').should('contain', '/dashboard/ai-runner/github');
      cy.get('#air-gh-client_secret').should('have.attr', 'type', 'password');
      cy.screenshot('ai-runner-builtin-platform', { capture: 'fullPage' });
      cy.contains('button', 'Save platform settings').click();
      cy.wait('@save').its('request.body').should((body) => {
        expect(body).to.not.have.property('github');
        expect(body).to.have.property('builtin_max_steps');
      });
      cy.contains('Platform settings saved');
      asUser('PUT', '/api/v2/ai-runner/platform/settings', { builtin_max_steps: before }).its('status').should('eq', 200);
    });
  });
});

export {};
