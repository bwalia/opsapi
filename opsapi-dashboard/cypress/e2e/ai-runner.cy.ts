/// <reference types="cypress" />

/**
 * AI Runs (docs/AI_RUNNER.md §22) in the browser: register a runner and see its token once, start a task
 * with AI from the task page (with the preview), see the run on AI Runs, its prompt and live log on the
 * detail page, and cancel it. The spec plays the PromptPilot runner itself through the runner API
 * (heartbeat / claim / status / events with the token the page showed), so no machine is needed.
 *
 * Needs an API with the ai_runner plugin (projects/ai-runner) and kanban, and the dashboard pointed at it:
 *   CYPRESS_API_URL         the API, e.g. http://127.0.0.1:4010
 *   CYPRESS_AIR_TOKEN       a JWT for a workspace owner (holds ai_runs / ai_runners / ai_runs_settings manage
 *                           and namespace.update, to switch the plugin on)
 *   CYPRESS_AIR_USER        {"uuid","email","first_name","last_name"} (JSON) of that user
 *   CYPRESS_AIR_NAMESPACE   {"uuid","name","slug"} (JSON) of their workspace
 *   CYPRESS_AIR_REPO        optional: the repo folder the fake runner reports (default /tmp/air-e2e-repo)
 *   npx cypress run --spec cypress/e2e/ai-runner.cy.ts
 * Each run registers a new runner and creates its own project and task, so it can be repeated.
 */

type Ns = { uuid: string; name: string; slug: string };

// Cypress parses JSON-looking env values itself.
const json = (v: unknown) => (typeof v === 'string' ? JSON.parse(v) : v);
const api = (path: string) => `${Cypress.env('API_URL')}${path}`;
const stamp = Date.now();
// Per attempt: a retried test registers a new runner, and a runner name is unique in a workspace.
let runnerName = `e2e-runner-${stamp}`;
const taskTitle = `AI e2e task ${stamp}`;
const repo = (Cypress.env('AIR_REPO') as string) || '/tmp/air-e2e-repo';

let ns: Ns;
let projectUuid = '';
let taskUuid = '';
let runnerToken = '';
let runnerUuid = '';
let runUuid = '';

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

/** A request as the signed-in user. */
function asUser(method: string, path: string, body?: Record<string, unknown>, form = false) {
  return cy.request({
    method, url: api(path), body, form,
    headers: { Authorization: `Bearer ${Cypress.env('AIR_TOKEN')}`, 'X-Namespace-Id': ns.uuid },
  });
}

/**
 * A request as the runner (the token the Runners page showed once). Built when it runs, not when Cypress
 * queues it: the token (and a run uuid in the path) are only known once the earlier commands have run.
 */
function asRunner(path: string | (() => string), body: Record<string, unknown>) {
  return cy.then(() => cy.request({
    method: 'POST', url: api(`/api/v2/ai-runner/public/runner${typeof path === 'function' ? path() : path}`), body,
    headers: { Authorization: `Bearer ${runnerToken}` }, failOnStatusCode: false,
  }));
}

function heartbeat() {
  return asRunner('/heartbeat', {
    version: 'e2e', host: 'e2e-host', os: 'linux',
    capabilities: { max_concurrency: 1, profiles: [{ key: 'fake', label: 'Fake agent', approval: 'none', models: [] }] },
    load: { running: 0 },
    inventory: [],
    repos: [{ path: repo, remote: 'git@example.com:e2e/repo.git', branch: 'main', dirty: false }],
  }).then((res) => {
    expect(res.status, 'heartbeat').to.eq(200);
    return res.body.data as { runner_uuid: string; cancel: string[] };
  });
}

describe('AI Runs', () => {
  before(function () {
    // Needs a seeded owner session (see the header); skip where there is none.
    if (!Cypress.env('AIR_TOKEN')) this.skip();
    ns = json(Cypress.env('AIR_NAMESPACE')) as Ns;
    const user = json(Cypress.env('AIR_USER')) as { uuid: string };
    asUser('PUT', '/api/v2/namespace/plugins/ai_runner', { enabled: true });
    asUser('POST', '/api/v2/kanban/projects', { name: `AI e2e ${stamp}` }, true).then((res) => {
      projectUuid = res.body.data.uuid;
      return asUser('GET', `/api/v2/kanban/projects/${projectUuid}/boards`);
    }).then((res) => {
      const board = res.body.data[0].uuid;
      return asUser('POST', `/api/v2/kanban/boards/${board}/tasks`, {
        title: taskTitle, description: 'Add a line to README.md.', assignee_uuids: JSON.stringify([user.uuid]),
      }, true);
    }).then((res) => {
      taskUuid = res.body.data.uuid;
    });
  });

  beforeEach(() => cy.viewport(1280, 900));

  it('registers a runner and shows its token once', () => {
    runnerName = `e2e-runner-${stamp}-${Cypress.currentRetry}`;
    visit('/dashboard/ai-runner/runners');
    cy.contains('h1', 'Runners', { timeout: 20000 });
    cy.contains('button', 'Register runner').click();
    cy.get('#air-runner-name').type(runnerName);
    cy.get('[role="dialog"]').contains('button', /^Register$/).click();

    cy.contains("You won't see it again");
    cy.get('[data-testid="runner-token"]').invoke('text').then((t) => {
      runnerToken = t.trim();
      expect(runnerToken).to.match(/^oprn_[0-9a-f]{48}$/);
    });
    cy.contains('runner.json');
    cy.contains('promptpilot runner -config runner.json');
    cy.screenshot('ai-runner-token-once', { capture: 'viewport' });
    cy.contains('button', 'I saved the token').click();
    cy.get('[data-testid="runner-token"]').should('not.exist');
    cy.contains('tr', runnerName).should('contain', 'Offline');

    heartbeat().then((d) => { runnerUuid = d.runner_uuid; });
    cy.reload();
    cy.contains('tr', runnerName, { timeout: 20000 }).should('contain', 'Online').and('not.contain', 'never');
  });

  it('starts the task with AI from the task page, after a preview', () => {
    heartbeat(); // stay online (< 45 s)
    visit(`/dashboard/projects/${projectUuid}/tasks/${taskUuid}`);
    cy.contains('h1', taskTitle, { timeout: 20000 });
    cy.contains('button', 'Start with AI').click();

    cy.get('[role="dialog"]').within(() => {
      cy.contains('Start with AI');
      cy.get('#air-runner', { timeout: 20000 }).select(runnerUuid);
      cy.get('#air-profile').should('have.value', 'fake');
      cy.get('#air-repo').clear().type(repo);
      cy.contains('Press Preview');
      cy.contains('button', 'Preview').click();
      cy.contains('Output:', { timeout: 20000 }).parent().should('contain', 'Pull request');
      cy.get('#air-prompt, pre[aria-labelledby="air-prompt-label"]').should(($el) => {
        const text = ($el.val() as string) || $el.text();
        expect(text).to.contain(taskTitle).and.to.contain(repo);
      });
      cy.contains("This run can't start yet").should('not.exist');
      cy.screenshot('ai-runner-start-dialog', { capture: 'viewport' });
      cy.contains('button', /^Start$/).should('not.be.disabled').click();
    });

    cy.location('pathname', { timeout: 20000 }).should('match', /^\/dashboard\/ai-runner\/runs\/[0-9a-f-]{36}$/).then((p) => {
      runUuid = p.split('/').pop() as string;
    });
    cy.contains('Queued');
  });

  it('shows the run on AI Runs', () => {
    visit('/dashboard/ai-runner/runs');
    cy.contains('h1', 'AI Runs', { timeout: 20000 });
    cy.contains('tr', taskTitle, { timeout: 20000 }).within(() => {
      cy.contains('Queued');
      cy.contains(runnerName);
      cy.contains(repo);
      cy.contains('a', 'Open').should('have.attr', 'href', `/dashboard/ai-runner/runs/${runUuid}`);
    });
  });

  it('shows the prompt and the live log on the run page', () => {
    // The runner claims the run, starts it and streams two log lines.
    asRunner('/claim', { wait_s: 0 }).then((res) => {
      expect(res.status, 'claim').to.eq(200);
      expect(res.body.data.run.uuid).to.eq(runUuid);
    });
    asRunner(() => `/runs/${runUuid}/status`, { seq: 1, status: 'running', work_branch: 'ai/e2e' }).its('status').should('eq', 200);
    asRunner(() => `/runs/${runUuid}/events`, {
      events: [
        { seq: 1, type: 'log', text: 'e2e: reading the task' },
        { seq: 2, type: 'log', text: 'e2e: editing README.md' },
      ],
    }).its('status').should('eq', 200);

    visit(`/dashboard/ai-runner/runs/${runUuid}`);
    cy.contains('h1', taskTitle, { timeout: 20000 });
    cy.contains('Running');
    cy.contains('dt', /^Started$/i).next().invoke('text').should('not.eq', '—');
    cy.contains('dt', /^Requested by$/i).next().invoke('text').should('not.eq', '—');
    cy.get('[role="log"]').should('contain', 'e2e: reading the task').and('contain', 'e2e: editing README.md');
    cy.contains('summary', 'Prompt').click();
    cy.contains('pre', taskTitle);
    cy.contains('button', 'Copy prompt');
    cy.screenshot('ai-runner-run-detail', { capture: 'viewport' });
  });

  it('cancels the run', () => {
    visit(`/dashboard/ai-runner/runs/${runUuid}`);
    cy.contains('button', 'Cancel run', { timeout: 20000 }).click();
    cy.get('[role="alertdialog"]').contains('button', 'Cancel run').click();
    cy.contains('Cancelling', { timeout: 20000 });

    // The next heartbeat tells the runner to stop; it reports the run cancelled.
    heartbeat().then((d) => {
      expect(d.cancel).to.include(runUuid);
    });
    asRunner(() => `/runs/${runUuid}/status`, { seq: 2, status: 'cancelled' }).its('status').should('eq', 200);
    cy.contains('Cancelled', { timeout: 20000 });
    cy.contains('button', 'Cancel run').should('not.exist');
    cy.contains('button', 'Retry');
  });
});

export {}; // a module: its helpers stay out of the other specs' global scope
