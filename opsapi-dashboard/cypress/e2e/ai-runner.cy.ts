/// <reference types="cypress" />

/**
 * AI Runs (docs/AI_RUNNER.md §22, §23) in the browser: register a runner and see its token once, start a task
 * with AI from the task page (with the preview), see the run on AI Runs, its prompt and live log on the
 * detail page; decide the agent's permission request, send it a message and see its reply with usage;
 * cancel the run; and approve a run that needs a manager before it starts. Phase 4 (§24): the overview cards,
 * the similar-work warning that needs "Start anyway", an unavailable profile, and the Machines page with the
 * sessions the runner reported. The spec plays the PromptPilot
 * runner itself through the runner API (heartbeat / claim / status / events / permissions / turns with the
 * token the page showed), so no machine is needed.
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
// A second folder for the similar task: the first run holds the folder lock on `repo`.
const repo2 = `${repo}-similar`;

let ns: Ns;
let userUuid = '';
let boardUuid = '';
let projectUuid = '';
let taskUuid = '';
let runnerToken = '';
let runnerUuid = '';
let runUuid = '';
let reqUuid = '';
let approvalRunUuid = '';
// The runner's status reports carry an increasing seq (a report with a seq not above the last is ignored).
let statusSeq = 0;
const nextStatus = (status: string, extra: Record<string, unknown> = {}) => () => ({ seq: ++statusSeq, status, ...extra });

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
 * queues it: the token (and a run uuid in the path, a seq in the body) are only known once the earlier
 * commands have run.
 */
type Body = Record<string, unknown>;
function asRunner(path: string | (() => string), body: Body | (() => Body)) {
  return cy.then(() => cy.request({
    method: 'POST', url: api(`/api/v2/ai-runner/public/runner${typeof path === 'function' ? path() : path}`),
    body: typeof body === 'function' ? body() : body,
    headers: { Authorization: `Bearer ${runnerToken}` }, failOnStatusCode: false,
  }));
}

/** A heartbeat; `inventory` (the sessions on the machine) is built when it runs and replaces the last one. */
function heartbeat(inventory: () => Body[] = () => []) {
  return asRunner('/heartbeat', () => ({
    version: 'e2e', host: 'e2e-host', os: 'linux',
    capabilities: {
      max_concurrency: 1,
      profiles: [
        { key: 'fake', label: 'Fake agent', approval: 'bridge', models: [] },
        // Can't ask for permissions (like Cursor): every run needs a manager's approval to start.
        { key: 'noask', label: 'No-ask agent', approval: 'unsupported', models: [] },
        // Its health check failed on the machine: it takes no work.
        { key: 'locked', label: 'Logged-out agent', approval: 'bridge', models: [], available: false, unavailable_reason: 'not logged in' },
      ],
    },
    load: { running: 0 },
    inventory: inventory(),
    repos: [
      { path: repo, remote: 'git@example.com:e2e/repo.git', branch: 'main', dirty: false },
      { path: repo2, remote: 'git@example.com:e2e/repo.git', branch: 'main', dirty: false },
    ],
  })).then((res) => {
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
    userUuid = user.uuid;
    asUser('PUT', '/api/v2/namespace/plugins/ai_runner', { enabled: true });
    asUser('POST', '/api/v2/kanban/projects', { name: `AI e2e ${stamp}` }, true).then((res) => {
      projectUuid = res.body.data.uuid;
      return asUser('GET', `/api/v2/kanban/projects/${projectUuid}/boards`);
    }).then((res) => {
      boardUuid = res.body.data[0].uuid;
      return asUser('POST', `/api/v2/kanban/boards/${boardUuid}/tasks`, {
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

  it('shows the overview cards to a manager', () => {
    heartbeat(); // online for the runner count
    visit('/dashboard/ai-runner/runs');
    cy.contains('h1', 'AI Runs', { timeout: 20000 });
    cy.get('section[aria-label="Overview"]', { timeout: 20000 }).within(() => {
      // The queued run is open; the fake runner is online.
      cy.contains('p', 'Open runs').next().invoke('text').then((t) => expect(Number(t)).to.be.gte(1));
      cy.contains('p', 'Runners online').next().invoke('text').then((t) => expect(Number(t)).to.be.gte(1));
      cy.contains('p', 'Tokens today');
      cy.contains('p', 'Last 7 days').next().should('contain', 'succeeded');
      cy.contains('p', 'Avg permission wait');
    });
    cy.screenshot('ai-runner-overview', { capture: 'viewport' });
  });

  it('warns about similar open work and needs "Start anyway"', () => {
    const title = `${taskTitle} (copy)`;
    let similarTaskUuid = '';
    let similarRunUuid = '';
    heartbeat(); // stay online (< 45 s)
    // A second task with a near-identical title, while the first task's run is open.
    asUser('POST', `/api/v2/kanban/boards/${boardUuid}/tasks`, {
      title, description: 'The same work again.', assignee_uuids: JSON.stringify([userUuid]),
    }, true).then((res) => { similarTaskUuid = res.body.data.uuid; });
    cy.then(() => visit(`/dashboard/projects/${projectUuid}/tasks/${similarTaskUuid}`));
    cy.contains('h1', title, { timeout: 20000 });
    cy.contains('button', 'Start with AI').click();

    cy.get('[role="dialog"]').within(() => {
      cy.get('#air-runner', { timeout: 20000 }).select(runnerUuid);
      cy.get('#air-profile option[value="locked"]').should('be.disabled').and('contain', 'not logged in');
      cy.get('#air-repo').clear().type(repo2);
      cy.contains('button', 'Preview').click();
      cy.get('[data-testid="air-similar"]', { timeout: 20000 }).within(() => {
        cy.contains('Similar work is already open');
        cy.get(`a[href="/dashboard/ai-runner/runs/${runUuid}"]`).should('contain', taskTitle);
      });
      cy.get('[data-testid="air-limits"]').should('contain', 'open runs');
      cy.contains("This run can't start yet").should('not.exist');
      cy.contains('button', /^Start$/).should('be.disabled');
      cy.screenshot('ai-runner-similar-work', { capture: 'viewport' });
      cy.contains('label', 'Start anyway').find('input').check();
      cy.contains('button', /^Start$/).should('not.be.disabled').click();
    });

    // Started with confirm_similar: its own run page.
    cy.location('pathname', { timeout: 20000 }).should('match', /^\/dashboard\/ai-runner\/runs\/[0-9a-f-]{36}$/).then((p) => {
      similarRunUuid = p.split('/').pop() as string;
      expect(similarRunUuid).not.to.eq(runUuid);
    });
    // Clean up, so the runner claims the first run next.
    cy.then(() => asUser('POST', `/api/v2/ai-runner/runs/${similarRunUuid}/cancel`)).its('status').should('eq', 200);
  });

  it('shows the prompt and the live log on the run page', () => {
    // The runner claims the run, starts it and streams two log lines.
    asRunner('/claim', { wait_s: 0 }).then((res) => {
      expect(res.status, 'claim').to.eq(200);
      expect(res.body.data.run.uuid).to.eq(runUuid);
    });
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('running', { work_branch: 'ai/e2e' })).its('status').should('eq', 200);
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

  it('lists the machine and its sessions on Machines', () => {
    const now = () => new Date().toISOString();
    const byHand = `${repo}-by-hand`;
    // The machine reports the run's own session (its session id is the run uuid), one started by hand and an idle one.
    heartbeat(() => [
      { key: `run-${runUuid}`, tool: 'claude', status: 'running', cwd: repo, branch: 'ai/e2e', session_id: runUuid,
        started_at: now(), updated_at: now(), prompt_preview: `Task ${taskTitle}` },
      { key: 'e2e-by-hand', tool: 'claude', status: 'working', cwd: byHand, branch: 'feature/by-hand',
        session_id: 'e2e-by-hand-session', started_at: now(), updated_at: now(), prompt_preview: 'e2e: tidy the README by hand' },
      { key: 'e2e-idle', tool: 'cursor', status: 'idle', cwd: `${repo}-idle`, branch: 'main', session_id: 'e2e-idle-session',
        started_at: now(), updated_at: now(), prompt_preview: 'e2e: an idle session' },
    ]);
    visit('/dashboard/ai-runner/machines');
    cy.contains('h1', 'Machines', { timeout: 20000 });
    cy.get('#air-m-runner', { timeout: 20000 }).select(runnerUuid);
    cy.contains('h2', runnerName, { timeout: 20000 }).closest('section').within(() => {
      cy.contains('Online');
      cy.contains('Unavailable — not logged in');
      cy.contains('tr', 'ai/e2e').find(`a[href="/dashboard/ai-runner/runs/${runUuid}"]`).should('contain', taskTitle);
      cy.contains('tr', 'e2e: tidy the README by hand').should('contain', 'Started by hand').and('contain', byHand).and('contain', 'working');
      cy.contains('tr', 'e2e: an idle session').should('contain', 'idle');
    });
    cy.screenshot('ai-runner-machines', { capture: 'viewport' });

    cy.contains('label', 'Busy only').find('input').check();
    cy.contains('h2', runnerName).closest('section').within(() => {
      cy.contains('tr', 'e2e: an idle session').should('not.exist');
      cy.contains('tr', 'e2e: tidy the README by hand');
    });
  });

  it("asks for a permission and hands the user's decision to the runner", () => {
    // The agent wants to run a command: the runner asks OpsAPI, then reports that it waits.
    asRunner(() => `/runs/${runUuid}/permissions`, {
      request_id: `e2e-req-${stamp}`, tool: 'Bash', input: { command: 'npm test' }, rule_key: 'npm test',
      description: 'Run the test suite',
    }).then((res) => {
      expect(res.status, 'permission request').to.be.oneOf([200, 201]);
      expect(res.body.data.request.status).to.eq('pending');
      reqUuid = res.body.data.request.uuid;
    });
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('waiting_permission')).its('status').should('eq', 200);

    // It waits on the user: listed under Waiting on you on AI Runs…
    visit('/dashboard/ai-runner/runs');
    cy.contains('h2', 'Waiting on you', { timeout: 20000 }).closest('section').within(() => {
      cy.contains('li', 'npm test').should('contain', taskTitle).and('contain', 'Bash');
    });
    cy.contains('tr', taskTitle).should('contain', 'Waiting for permission');

    // …and decided on the run page.
    visit(`/dashboard/ai-runner/runs/${runUuid}`);
    cy.contains('h2', 'Needs your decision', { timeout: 20000 }).closest('section').within(() => {
      cy.contains('npm test');
      cy.contains('Run the test suite');
      cy.contains('button', 'Allow for this run');
      cy.contains('button', /^Deny$/);
      cy.screenshot('ai-runner-permission-request', { capture: 'viewport' });
      cy.contains('button', /^Allow$/).click();
    });
    cy.contains('Allowed: the agent carries on');
    cy.contains('h2', 'Needs your decision').should('not.exist');

    // The runner's wait returns the decision; the agent carries on.
    asRunner(() => `/runs/${runUuid}/permissions/${reqUuid}/wait`, { wait_s: 0 }).then((res) => {
      expect(res.status, 'wait').to.eq(200);
      expect(res.body.data.status).to.eq('allowed');
      expect(res.body.data.cancel).to.eq(false);
    });
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('running')).its('status').should('eq', 200);
    cy.contains('h2', 'Permission requests', { timeout: 20000 }).closest('section').within(() => {
      cy.contains('tr', 'npm test').should('contain', 'Allowed');
    });
  });

  it("sends the agent a message and shows its reply with the run's usage", () => {
    const message = `e2e follow-up ${stamp}`;
    const reply = 'e2e: tests pass, README.md updated';
    visit(`/dashboard/ai-runner/runs/${runUuid}`);
    cy.contains('h1', taskTitle, { timeout: 20000 });
    cy.get('#air-message', { timeout: 20000 }).type(message);
    cy.contains('button', /^Send$/).click();
    cy.contains('the agent gets it after its current turn');
    cy.contains('li', message).should('contain', 'Not yet sent to the agent');

    // The runner picks the message up after the agent's turn…
    asRunner(() => `/runs/${runUuid}/turns/next`, { wait_s: 0 }).then((res) => {
      expect(res.status, 'turns/next').to.eq(200);
      expect(res.body.data.turns.map((t: { text: string }) => t.text)).to.include(message);
    });
    // …and reports the agent's reply with its usage.
    asRunner(() => `/runs/${runUuid}/turns`, {
      turn: 1, text: reply, model: 'fake',
      usage: { input_tokens: 1200, output_tokens: 345, cache_read_tokens: 5000, cache_write_tokens: 100 },
      cost_estimate: 0.0123, num_turns: 3, duration_ms: 4200,
    }).its('status').should('be.oneOf', [200, 201]);

    cy.contains('li', reply, { timeout: 20000 }).should('contain', '1.2K in').and('contain', '345 out');
    cy.contains('li', message, { timeout: 20000 }).should('not.contain', 'Not yet sent to the agent');
    cy.contains('dt', /^Tokens in$/).next().should('have.text', '1.2K');
    cy.contains('dt', /^Tokens out$/).next().should('have.text', '345');
    cy.contains('dt', /^Turns$/).next().should('have.text', '1');
    cy.screenshot('ai-runner-conversation', { capture: 'viewport' });

    visit('/dashboard/ai-runner/runs');
    cy.contains('tr', taskTitle, { timeout: 20000 }).should('contain', '1.5K tokens').and('contain', '1 turn');
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
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('cancelled')).its('status').should('eq', 200);
    cy.contains('Cancelled', { timeout: 20000 });
    cy.contains('button', 'Cancel run').should('not.exist');
    cy.contains('button', 'Retry');
  });

  it("waits for a manager's approval before a run of a profile that can't ask starts", () => {
    heartbeat(); // stay online (< 45 s)
    visit(`/dashboard/projects/${projectUuid}/tasks/${taskUuid}`);
    cy.contains('h1', taskTitle, { timeout: 20000 });
    cy.contains('button', 'Start with AI').click();
    cy.get('[role="dialog"]').within(() => {
      cy.get('#air-runner', { timeout: 20000 }).select(runnerUuid);
      cy.get('#air-profile').select('noask');
      cy.get('#air-repo').clear().type(repo);
      cy.contains('button', 'Preview').click();
      cy.contains('A manager must approve this run before it starts.', { timeout: 20000 });
      cy.contains('button', /^Start$/).should('not.be.disabled').click();
    });

    // It lands on its run page, waiting for approval; no runner can claim it yet.
    cy.location('pathname', { timeout: 20000 }).should('match', /^\/dashboard\/ai-runner\/runs\/[0-9a-f-]{36}$/).then((p) => {
      approvalRunUuid = p.split('/').pop() as string;
      expect(approvalRunUuid).not.to.eq(runUuid);
    });
    cy.contains("This run needs a manager's approval before it starts", { timeout: 20000 });
    cy.contains('Needs approval');
    asRunner('/claim', { wait_s: 0 }).its('status').should('eq', 204);

    // The owner is a manager: approve it from Waiting on you.
    visit('/dashboard/ai-runner/runs');
    cy.contains('h2', 'Waiting on you', { timeout: 20000 }).closest('section').within(() => {
      cy.contains('li', taskTitle).should('contain', 'Start approval').within(() => {
        cy.contains('button', 'Approve').click();
      });
    });
    cy.contains('Approved: the run is queued');
    cy.then(() => cy.get(`a[href="/dashboard/ai-runner/runs/${approvalRunUuid}"]`, { timeout: 20000 }))
      .closest('tr').should('contain', 'Queued');

    // Clean up: nothing will claim it.
    cy.then(() => asUser('POST', `/api/v2/ai-runner/runs/${approvalRunUuid}/cancel`)).its('status').should('eq', 200);
  });
});

export {}; // a module: its helpers stay out of the other specs' global scope
