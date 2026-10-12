/// <reference types="cypress" />

/**
 * AI Runs with the REAL PromptPilot runner on this machine, driven only through the dashboard: save the workspace
 * settings, register a runner (its token goes to the kit's runner.token, where a waiting `promptpilot runner`
 * picks it up), Start with AI on a task with the fake agent → Succeeded with the branch pushed to origin and the
 * folder back on main, cancel a running run → the folder handed back clean, retry it → Succeeded, and (with
 * CYPRESS_AIR_CLAUDE=1) a real Claude Code run that edits README.md.
 *
 * Env as ai-runner.cy.ts (API_URL, AIR_TOKEN, AIR_USER, AIR_NAMESPACE), plus:
 *   CYPRESS_AIR_KIT     a folder with runner.json (profiles `fake` and `claude`), repos/demo-site (a git repo on main
 *                       whose origin is origin/demo-site.git), and a runner started as
 *                       `until [ -s runner.token ]; do sleep 1; done; promptpilot runner -config runner.json`
 *   CYPRESS_AIR_CLAUDE  1 = also run Claude Code for real (uses this machine's Claude login)
 *   npx cypress run --spec cypress/e2e/ai-runner-real.cy.ts --config retries=0
 */

type Ns = { uuid: string; name: string; slug: string };

const json = (v: unknown) => (typeof v === 'string' ? JSON.parse(v) : v);
const api = (path: string) => `${Cypress.env('API_URL')}${path}`;
const stamp = Date.now();
const kit = Cypress.env('AIR_KIT') as string;
const repo = `${kit}/repos/demo-site`;
const origin = `${kit}/origin/demo-site.git`;
const runnerName = `real-runner-${stamp}`;
const tasks: Record<'ok' | 'cancel' | 'claude', { uuid: string; title: string }> = {
  ok: { uuid: '', title: `Write release notes ${stamp}` },
  cancel: { uuid: '', title: `Slow refactor ${stamp}` },
  claude: { uuid: '', title: `Add a Getting started section ${stamp}` },
};

let ns: Ns;
let projectUuid = '';
let runnerUuid = '';
const runs: Record<string, string> = {};

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

function asUser(method: string, path: string, body?: Record<string, unknown>, form = false) {
  return cy.request({
    method, url: api(path), body, form,
    headers: { Authorization: `Bearer ${Cypress.env('AIR_TOKEN')}`, 'X-Namespace-Id': ns.uuid },
  });
}

const git = (args: string, dir = repo) => cy.exec(`git -C '${dir}' ${args}`).its('stdout').then((s) => String(s).trim());

/** Polls the API until the runner reports itself online (heartbeat every 15 s). */
function waitOnline(tries = 30): Cypress.Chainable {
  return asUser('GET', '/api/v2/ai-runner/runners').then((res) => {
    const r = (res.body.data as { uuid: string; name: string; status: string }[]).find((x) => x.name === runnerName);
    if (r?.status === 'online') { runnerUuid = r.uuid; return; }
    if (tries <= 0) throw new Error('the runner never came online — is `promptpilot runner` waiting on the kit?');
    cy.wait(2000);
    return waitOnline(tries - 1);
  });
}

/** Task page → Start with AI → preview → Start; lands on the run page and records its uuid. */
function startWithAI(key: keyof typeof tasks, profile: 'fake' | 'claude') {
  visit(`/dashboard/projects/${projectUuid}/tasks/${tasks[key].uuid}`);
  cy.contains('h1', tasks[key].title, { timeout: 30000 });
  cy.contains('button', 'Start with AI').click();
  cy.get('[role="dialog"]').within(() => {
    cy.get('#air-runner', { timeout: 20000 }).select(runnerUuid);
    cy.get('#air-profile').select(profile);
    cy.get('#air-repo').clear().type(repo);
    cy.contains('button', 'Preview').click();
    cy.contains('Output:', { timeout: 20000 }).parent().should('contain', 'Push a branch');
    cy.contains("This run can't start yet").should('not.exist');
    cy.contains('button', /^Start$/).should('not.be.disabled').click();
  });
  cy.location('pathname', { timeout: 20000 }).should('match', /^\/dashboard\/ai-runner\/runs\/[0-9a-f-]{36}$/)
    .then((p) => { runs[key] = p.split('/').pop() as string; });
}

/** The folder is back on main with nothing left uncommitted. */
function folderHandedBack() {
  git('rev-parse --abbrev-ref HEAD').should('eq', 'main');
  git('status --porcelain').should('eq', '');
}

/** A field on the run page (labels are upper-cased by CSS). */
const fact = (label: string) => cy.contains('dt', new RegExp(`^${label}$`, 'i')).next();

/** The run page's Branch value, without the "(from main)" suffix. */
function branchOnPage() {
  return cy.contains('dt', /^Branch$/i).next().invoke('text').then((t) => t.split(' ')[0].trim());
}

describe('AI Runs with the real PromptPilot runner', () => {
  before(function () {
    if (!Cypress.env('AIR_TOKEN') || !kit) this.skip();
    ns = json(Cypress.env('AIR_NAMESPACE')) as Ns;
    const user = json(Cypress.env('AIR_USER')) as { uuid: string };
    asUser('PUT', '/api/v2/namespace/plugins/ai_runner', { enabled: true });
    asUser('POST', '/api/v2/kanban/projects', { name: `AI real ${stamp}` }, true).then((res) => {
      projectUuid = res.body.data.uuid;
      return asUser('GET', `/api/v2/kanban/projects/${projectUuid}/boards`);
    }).then((res) => {
      const board = res.body.data[0].uuid;
      (Object.keys(tasks) as (keyof typeof tasks)[]).forEach((k) => {
        asUser('POST', `/api/v2/kanban/boards/${board}/tasks`, {
          title: tasks[k].title,
          description: k === 'claude'
            ? 'In README.md, add a short "## Getting started" section (two or three lines) after the intro. Change nothing else.'
            : 'Add a line to the notes.',
          assignee_uuids: JSON.stringify([user.uuid]),
        }, true).then((r) => { tasks[k].uuid = r.body.data.uuid; });
      });
    });
  });

  beforeEach(() => cy.viewport(1280, 900));

  it('saves the workspace settings: push a branch', () => {
    visit('/dashboard/ai-runner/settings');
    cy.get('#air-s-output', { timeout: 30000 }).select('branch');
    cy.contains('button', 'Save settings').click();
    cy.contains('Settings saved');
    asUser('GET', '/api/v2/ai-runner/settings').its('body.data.output_mode').should('eq', 'branch');
  });

  it('registers a runner; the real runner picks up the token and comes online', () => {
    visit('/dashboard/ai-runner/runners');
    cy.contains('button', 'Register runner', { timeout: 30000 }).click();
    cy.get('#air-runner-name').type(runnerName);
    cy.get('[role="dialog"]').contains('button', /^Register$/).click();
    cy.get('[data-testid="runner-token"]').invoke('text').then((t) => {
      expect(t.trim()).to.match(/^oprn_[0-9a-f]{48}$/);
      // What the user does by hand: paste the token into the file runner.json points at.
      cy.writeFile(`${kit}/runner.token`, `${t.trim()}\n`, { log: false });
      cy.exec(`chmod 600 '${kit}/runner.token'`);
    });
    cy.contains('button', 'I saved the token').click();
    waitOnline();
    cy.reload();
    cy.contains('tr', runnerName, { timeout: 20000 }).should('contain', 'Online').and('not.contain', 'never');
    cy.screenshot('real-runner-online', { capture: 'viewport' });
  });

  it('starts a task with the fake agent: succeeds, branch pushed, folder back on main', () => {
    startWithAI('ok', 'fake');
    cy.contains('Succeeded', { timeout: 120000 });
    cy.get('[role="log"]').invoke('text').should('not.be.empty');
    const user = json(Cypress.env('AIR_USER')) as { first_name: string; last_name: string };
    fact('Requested by').should('have.text', `${user.first_name} ${user.last_name}`);
    ['Queued', 'Started', 'Finished', 'Duration'].forEach((f) => fact(f).invoke('text').should('not.eq', '—'));
    cy.contains('dt', /^Commit$/i).next().invoke('text').should('match', /^[0-9a-f]{7,40}$/);
    branchOnPage().then((branch) => {
      expect(branch).to.match(/^ai\//);
      git(`ls-remote --heads '${origin}'`).should('contain', `refs/heads/${branch}`);
    });
    git('rev-parse main', origin).then((remoteMain) => git('rev-parse main').should('eq', remoteMain));
    folderHandedBack();
    cy.screenshot('real-run-succeeded', { capture: 'viewport' });
  });

  it('cancels a running run: the runner stops the agent and hands the folder back clean', () => {
    startWithAI('cancel', 'fake');
    cy.contains('Running', { timeout: 90000 });
    cy.contains('button', 'Cancel run').click();
    cy.get('[role="alertdialog"]').contains('button', 'Cancel run').click();
    cy.contains('Cancelled', { timeout: 90000 });
    folderHandedBack();
  });

  it('retries the cancelled run: a new attempt that succeeds', () => {
    visit(`/dashboard/ai-runner/runs/${runs.cancel}`);
    cy.contains('button', 'Retry', { timeout: 30000 }).click();
    cy.location('pathname', { timeout: 20000 }).should('not.contain', runs.cancel);
    cy.contains('dt', /^Attempt$/i).next().should('have.text', '2');
    cy.contains('Succeeded', { timeout: 120000 });
    branchOnPage().then((branch) => git(`ls-remote --heads '${origin}'`).should('contain', `refs/heads/${branch}`));
    folderHandedBack();
  });

  it('runs Claude Code for real: README.md edited on a pushed branch', function () {
    if (!Cypress.env('AIR_CLAUDE')) this.skip();
    startWithAI('claude', 'claude');
    cy.contains('Succeeded', { timeout: 600000 });
    cy.contains('dt', /^Commit$/i).next().invoke('text').then((sha) => {
      git(`show --name-only --format= ${sha.trim()}`).should('contain', 'README.md');
      git(`show ${sha.trim()}:README.md`).should('match', /getting started/i);
    });
    branchOnPage().then((branch) => git(`ls-remote --heads '${origin}'`).should('contain', `refs/heads/${branch}`));
    folderHandedBack();
    cy.screenshot('real-claude-run', { capture: 'viewport' });
  });

  it('lists every run on AI Runs and shows the machine sessions', () => {
    visit('/dashboard/ai-runner/runs');
    cy.contains('tr', tasks.ok.title, { timeout: 30000 }).should('contain', 'Succeeded');
    cy.contains('tr', tasks.cancel.title).should('exist');
    visit('/dashboard/ai-runner/runners');
    cy.contains('tr', runnerName, { timeout: 30000 }).within(() => cy.get(`[aria-label="Sessions on ${runnerName}"]`).click());
    cy.contains(`Sessions on ${runnerName}`);
  });
});

export {};
