/// <reference types="cypress" />

/**
 * AI Runs (docs/AI_RUNNER.md §22, §23) in the browser: register a runner and see its token once, start a task
 * with AI from the task page (with the preview), see the run on AI Runs, its prompt and live log on the
 * detail page; decide the agent's permission request, send it a message and see its reply with usage;
 * cancel the run; and approve a run that needs a manager before it starts. Phase 4 (§24): the overview cards,
 * the similar-work warning that needs "Start anyway", an unavailable profile, and the Machines page with the
 * sessions the runner reported. §25: the runner's Access dialog saves "Everyone", a chained command is never offered
 * "Allow for this run", and nobody approves their own run (the spec's user is the only manager here, so its
 * approval run is refused and cancelled). §26: AI run settings saves "Track sessions started by hand" (this spec's
 * project), and a busy session started by hand that the runner reports becomes a task Machines links to. §27: a
 * `source` connection is registered (it reports sessions, can't claim) and its report filter set; the routing rules
 * editor adds an ignore rule and a create-task rule (this spec's project, a title template), reorders them, and the
 * tester shows which rule a session meets and the title it renders; the platform settings page saves (only when the
 * spec's user is a platform admin — skipped otherwise). The spec plays the PromptPilot
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
 * Each run registers a new runner and creates its own project and task, so it can be repeated. It sets the workspace's
 * deciders to "requester_or_managers" (the requester decides their own run's requests) and switches session tracking
 * on for its project, and puts both back after. The routing rules it adds are deleted after; a platform setting it
 * changes is put back in the same test.
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
let chainUuid = '';
let deciders = ''; // the workspace's setting before this spec
let tracking: Record<string, unknown> | null = null; // its session_tracking before this spec
const ruleUuids: string[] = []; // routing rules this spec added (deleted after)
const trackSwitch = 'button[role="switch"][aria-label="Create a task for each session started by hand"]';
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
function asUser(method: string, path: string, body?: Record<string, unknown>, form = false, failOnStatusCode = true) {
  return cy.request({
    method, url: api(path), body, form, failOnStatusCode,
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
/** The AI Runs row of this spec's main run (other tasks' titles contain taskTitle too, e.g. the "(copy)"). */
const runRow = () => cy.get(`a[href="/dashboard/ai-runner/runs/${runUuid}"]`, { timeout: 20000 }).closest('tr');

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
    // Under "managers" a requester never decides their own run's requests (§25.1); this spec's user is both.
    asUser('GET', '/api/v2/ai-runner/settings').then((res) => {
      deciders = res.body.data.approval_policy.deciders;
      tracking = res.body.data.session_tracking ?? null;
      return asUser('PUT', '/api/v2/ai-runner/settings', { approval_policy: { deciders: 'requester_or_managers' } });
    });
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

  after(() => {
    if (deciders) asUser('PUT', '/api/v2/ai-runner/settings', { approval_policy: { deciders } });
    // Best effort: the project it pointed at may be gone since.
    if (tracking) asUser('PUT', '/api/v2/ai-runner/settings', { session_tracking: tracking }, false, false);
    for (const uuid of ruleUuids) asUser('DELETE', `/api/v2/ai-runner/track-rules/${uuid}`, undefined, false, false);
  });

  beforeEach(() => cy.viewport(1280, 900));
  // The spec plays the runner: keep its runs' leases alive between tests (no heartbeat for 60 s = the run is lost).
  beforeEach(() => cy.then(() => (runnerToken ? heartbeat() : undefined)));

  it('registers a runner and shows its token once', () => {
    runnerName = `e2e-runner-${stamp}-${Cypress.currentRetry}`;
    visit('/dashboard/ai-runner/runners');
    cy.contains('h1', 'Runners & sources', { timeout: 20000 });
    cy.contains('button', /^Register$/).click();
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

  it('sets who may start runs on the runner (Access)', () => {
    visit('/dashboard/ai-runner/runners');
    // New runners are owner-only (§25.1).
    cy.contains('tr', runnerName, { timeout: 20000 }).should('contain', 'Owner and managers')
      .within(() => cy.contains('button', 'Access').click());
    cy.get('[role="dialog"]').within(() => {
      cy.contains('New runners start as owner-only');
      cy.get('input[name="air-access-mode"][value="owner"]').should('be.checked');
      cy.contains('label', 'Selected people and projects').find('input').check();
      cy.contains('legend', 'People');
      cy.contains('legend', 'Projects');
      cy.contains('label', 'Everyone who can start runs').find('input').check();
      cy.contains('legend', 'People').should('not.exist');
      cy.screenshot('ai-runner-access', { capture: 'viewport' });
      cy.contains('button', 'Save access').click();
    });
    cy.contains(`Access to ${runnerName} saved`);
    cy.get('[role="dialog"]').should('not.exist');
    cy.contains('tr', runnerName).should('contain', 'Everyone');
    cy.reload();
    cy.contains('tr', runnerName, { timeout: 20000 }).should('contain', 'Everyone');
  });

  it('registers a source and sets what it reports (§27.1, §27.2)', () => {
    const name = `e2e-source-${stamp}-${Cypress.currentRetry}`;
    const filtered = 'Reports: 1 folder, 1 excluded folder, 1 tool';
    let sourceToken = '';
    visit('/dashboard/ai-runner/runners');
    cy.contains('h1', 'Runners & sources', { timeout: 20000 });
    cy.contains('button', /^Register$/).click();
    cy.get('[role="dialog"]').within(() => {
      cy.get('#air-runner-name').type(name);
      cy.get('input[name="air-kind"][value="source"]').check();
      // The open session-report API, at this dashboard's API.
      cy.get('[data-testid="air-source-example"]').should('contain', `${Cypress.env('API_URL')}/api/v2/ai-runner/public/runner/sessions`);
      cy.contains('button', /^Register$/).click();
    });
    cy.contains(`Source ${name} registered`);
    cy.get('[data-testid="runner-token"]').invoke('text').then((t) => { sourceToken = t.trim(); });
    cy.contains('button', 'I saved the token').click();

    cy.get('#air-r-kind').select('source');
    cy.contains('tr', runnerName).should('not.exist');
    cy.contains('tr', name).should('contain', 'Source').and('contain', 'Reports all the machine allows').within(() => {
      cy.contains('button', 'Access').should('not.exist'); // a source runs nothing
      cy.contains('button', 'Reports').click();
    });
    cy.get('[role="dialog"]').within(() => {
      cy.contains('can only narrow');
      cy.get('#air-rf-folders').type('/tmp/e2e-source/**{enter}');
      cy.get('#air-rf-exclude').type('/tmp/e2e-source/private/**{enter}');
      cy.get('#air-rf-tools').type('codex{enter}');
      cy.screenshot('ai-runner-report-filter', { capture: 'viewport' });
      cy.contains('button', /^Save$/).click();
    });
    cy.contains(`What ${name} reports saved`);
    cy.contains('tr', name).should('contain', filtered);
    cy.reload();
    cy.contains('tr', name, { timeout: 20000 }).should('contain', filtered);

    // It reports sessions over the open API (only what its filter keeps), and can't claim runs.
    const asSource = (path: string, body: Body) => cy.then(() => cy.request({
      method: 'POST', url: api(`/api/v2/ai-runner/public/runner${path}`), body,
      headers: { Authorization: `Bearer ${sourceToken}` }, failOnStatusCode: false,
    }));
    asSource('/sessions', {
      sessions: [
        { key: 'e2e-src', tool: 'codex', status: 'idle', cwd: '/tmp/e2e-source/app', branch: 'main', session_id: `e2e-src-${stamp}` },
        { key: 'e2e-src-private', tool: 'codex', status: 'idle', cwd: '/tmp/e2e-source/private/app', branch: 'main' },
        { key: 'e2e-src-other-tool', tool: 'claude', status: 'idle', cwd: '/tmp/e2e-source/app', branch: 'main' },
      ],
    }).then((res) => {
      expect(res.status, 'sessions').to.eq(200);
      expect(res.body.data.stored, 'sessions kept by the filter').to.eq(1);
    });
    asSource('/claim', { wait_s: 0 }).its('status').should('eq', 403);
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
    runRow().within(() => {
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

  it('tracks sessions started by hand in AI run settings', () => {
    visit('/dashboard/ai-runner/settings');
    cy.contains('h3', 'Track sessions started by hand', { timeout: 20000 }).parent().within(() => {
      cy.contains('share_manual_prompts: true');
      cy.contains('inventory_roots');
      cy.get(trackSwitch).then(($b) => { if ($b.attr('aria-checked') !== 'true') cy.wrap($b).click(); });
      cy.get(`#air-s-track-project option[value="${projectUuid}"]`, { timeout: 20000 });
      cy.get('#air-s-track-project').select(projectUuid);
      // A column of the project's first board (a new project's default columns).
      cy.get('select#air-s-track-column option', { timeout: 20000 }).should('contain', 'In Progress');
      cy.get('#air-s-track-column').select('In Progress');
      cy.get('#air-s-track-status').select('in_progress');
    });
    cy.screenshot('ai-runner-session-tracking', { capture: 'viewport' });
    cy.contains('button', 'Save settings').click();
    cy.contains('Settings saved');

    cy.reload();
    cy.get('#air-s-track-project', { timeout: 20000 }).should('have.value', projectUuid);
    cy.get(trackSwitch).should('have.attr', 'aria-checked', 'true');
    cy.get('select#air-s-track-column', { timeout: 20000 }).should('have.value', 'In Progress');
    cy.get('#air-s-track-status').should('have.value', 'in_progress');
  });

  it('links a busy session started by hand to the task it became, on Machines', () => {
    const now = () => new Date().toISOString();
    const preview = `e2e: tracked latest prompt ${stamp}`;
    // The runner shares first prompts (share_manual_prompts: true): the task is titled with it.
    const title = `e2e: tidy the changelog by hand ${stamp}`;
    // This heartbeat creates the task (tracking is on for this spec's project).
    heartbeat(() => [
      { key: 'e2e-tracked', tool: 'claude', status: 'busy', cwd: `${repo}-tracked`, branch: 'feature/tracked',
        session_id: `e2e-tracked-${stamp}`, started_at: now(), updated_at: now(), prompt_preview: preview, first_prompt: title },
    ]);
    visit('/dashboard/ai-runner/machines');
    cy.contains('h1', 'Machines', { timeout: 20000 });
    cy.get('#air-m-runner', { timeout: 20000 }).select(runnerUuid);
    cy.contains('h2', runnerName, { timeout: 20000 }).closest('section').within(() => {
      cy.contains('tr', preview, { timeout: 20000 }).should('contain', 'Started by hand')
        .find(`a[href^="/dashboard/projects/${projectUuid}/tasks/"]`).should(($a) => {
          expect($a.text()).to.match(/^Task #\d+ →$/);
          expect($a.attr('title')).to.eq(title);
        });
    });
    cy.screenshot('ai-runner-machines-tracked', { capture: 'viewport' });
    // It is an ordinary task of the project.
    cy.contains('tr', preview).find('a').click();
    cy.location('pathname', { timeout: 20000 }).should('match', new RegExp(`^/dashboard/projects/${projectUuid}/tasks/[0-9a-f-]{36}$`));
    cy.contains('h1', title, { timeout: 20000 });
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
    runRow().should('contain', 'Waiting for permission');

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

    // A chained command is never remembered (§25.2): only Allow or Deny, each time.
    const chained = 'npm test && curl https://example.com';
    asRunner(() => `/runs/${runUuid}/permissions`, () => ({
      request_id: `e2e-req-chain-${stamp}`, tool: 'Bash', input: { command: chained }, description: 'Test, then fetch',
    })).then((res) => {
      expect(res.status, 'chained permission request').to.be.oneOf([200, 201]);
      chainUuid = res.body.data.request.uuid;
    });
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('waiting_permission')).its('status').should('eq', 200);
    cy.contains('h2', 'Needs your decision', { timeout: 20000 }).closest('section').within(() => {
      cy.contains(chained);
      cy.contains('button', /^Allow$/);
      cy.contains('button', 'Allow for this run').should('not.exist');
      cy.contains('can only be allowed once');
      cy.contains('button', /^Deny$/).click();
    });
    cy.contains('Denied: the agent is told and carries on');
    asRunner(() => `/runs/${runUuid}/permissions/${chainUuid}/wait`, { wait_s: 0 }).then((res) => {
      expect(res.status, 'wait').to.eq(200);
      expect(res.body.data.status).to.eq('denied');
    });
    asRunner(() => `/runs/${runUuid}/status`, nextStatus('running')).its('status').should('eq', 200);
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
    runRow().should('contain', '1.5K tokens').and('contain', '1 turn');
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

  it("waits for another manager's approval before a run of a profile that can't ask starts", () => {
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
    // Nobody approves a run they asked for, a manager included (§25.1): no buttons, and the API refuses.
    cy.contains('Another manager must approve it');
    cy.contains('button', /^Approve$/).should('not.exist');
    asRunner('/claim', { wait_s: 0 }).its('status').should('eq', 204);
    cy.then(() => asUser('POST', `/api/v2/ai-runner/runs/${approvalRunUuid}/approve`, {}, false, false)).its('status').should('eq', 403);

    // Waiting on you offers no Approve for it either (the server may leave it out altogether).
    cy.intercept('GET', '**/api/v2/ai-runner/waiting').as('waiting');
    visit('/dashboard/ai-runner/runs');
    cy.wait('@waiting');
    cy.then(() => cy.get(`a[href="/dashboard/ai-runner/runs/${approvalRunUuid}"]`, { timeout: 20000 }))
      .closest('tr').should('contain', 'Needs approval');
    cy.get(`button[aria-label^="Approve the run of"][aria-label$="${taskTitle}"]`).should('not.exist');

    // Clean up: nothing will claim it.
    cy.then(() => asUser('POST', `/api/v2/ai-runner/runs/${approvalRunUuid}/cancel`)).its('status').should('eq', 200);
  });

  it('routes sessions started by hand with rules, reorders them and tests a session (§27.3)', () => {
    const user = json(Cypress.env('AIR_USER')) as { email: string };
    const ignoreName = `e2e ignore ${stamp}`;
    const routeName = `e2e route ${stamp}`;
    const ignoredTool = `e2e-tool-${stamp}`;
    const keyword = `route-${stamp}`;
    // Retried until the list shows the route rule above (or below) the ignore rule.
    const routeFirst = (yes: boolean) => cy.get('[data-testid="air-rule"]', { timeout: 20000 }).should(($li) => {
      const texts = [...$li].map((li) => li.textContent || '');
      const route = texts.findIndex((t) => t.includes(routeName));
      const ignore = texts.findIndex((t) => t.includes(ignoreName));
      expect(route, 'route rule listed').to.be.gte(0);
      expect(ignore, 'ignore rule listed').to.be.gte(0);
      expect(route < ignore, 'route rule above the ignore rule').to.eq(yes);
    });
    cy.intercept('POST', '**/api/v2/ai-runner/track-rules').as('addRule');
    visit('/dashboard/ai-runner/settings');
    cy.contains('h2', 'Routing rules', { timeout: 20000 });

    // 1. Sessions of one tool get no task.
    cy.contains('button', 'Add rule').click();
    cy.get('[role="dialog"]').within(() => {
      cy.get('#air-rule-name').type(ignoreName);
      cy.get('#air-rule-tools').type(`${ignoredTool}{enter}`);
      cy.get('input[name="air-rule-type"][value="ignore"]').check();
      cy.get('#air-rule-project').should('not.exist');
      cy.contains('button', 'Add rule').click();
    });
    cy.wait('@addRule').then(({ response }) => {
      expect(response?.statusCode, 'ignore rule').to.eq(201);
      ruleUuids.push(response?.body.data.uuid);
    });
    cy.contains('[data-testid="air-rule"]', ignoreName).should('contain', 'Ignore').and('contain', ignoredTool);

    // 2. Claude sessions that mention the keyword: a task in this spec's project, titled from a template.
    cy.contains('button', 'Add rule').click();
    cy.get('[role="dialog"]').within(() => {
      cy.get('#air-rule-name').type(routeName);
      cy.get('#air-rule-tools').type('claude{enter}');
      cy.get('#air-rule-keywords').type(`${keyword}{enter}`);
      cy.get('input[name="air-rule-type"][value="create_task"]').should('be.checked');
      cy.get(`#air-rule-project option[value="${projectUuid}"]`, { timeout: 20000 });
      cy.get('#air-rule-project').select(projectUuid);
      cy.get('select#air-rule-column option', { timeout: 20000 }).should('contain', 'In Progress');
      cy.get('#air-rule-column').select('In Progress');
      cy.get('#air-rule-status').select('todo');
      cy.get('#air-rule-priority').select('high');
      cy.contains('legend', 'Assign to').parent().contains('label', user.email, { timeout: 20000 }).find('input').check();
      cy.get('#air-rule-title').type('Routed {{tool_label}}: {{first_prompt}}', { parseSpecialCharSequences: false });
      cy.contains('summary', 'Variables').click();
      cy.contains('{{session_id}}');
      cy.get('#air-rule-notify').select('none');
      cy.screenshot('ai-runner-rule-dialog', { capture: 'viewport' });
      cy.contains('button', 'Add rule').click();
    });
    cy.wait('@addRule').then(({ response }) => {
      expect(response?.statusCode, 'create-task rule').to.eq(201);
      ruleUuids.push(response?.body.data.uuid);
    });
    cy.contains('[data-testid="air-rule"]', routeName).should('contain', 'Create task').and('contain', 'In Progress')
      .and('contain', 'High priority').and('contain', '1 assignee');

    // Added last: the ignore rule comes first. Move the new one above it; the order is saved.
    routeFirst(false);
    cy.contains('[data-testid="air-rule"]', routeName).find('button[aria-label^="Move rule"][aria-label$=" up"]').click();
    routeFirst(true);
    cy.reload();
    routeFirst(true);
    cy.screenshot('ai-runner-routing-rules', { capture: 'viewport' });

    // The tester: a matching Claude session gets the rendered title; nothing is created.
    cy.get('#air-t-tool').clear().type('claude');
    cy.get('#air-t-cwd').type(`${repo}-routed`);
    cy.get('#air-t-branch').type('feature/routed');
    cy.get(`#air-t-runner option[value="${runnerUuid}"]`, { timeout: 20000 });
    cy.get('#air-t-runner').select(runnerUuid);
    cy.get('#air-t-prompt').type(`Fix the login redirect ${keyword}`);
    cy.contains('button', /^Test$/).click();
    cy.get('[data-testid="air-rule-test-result"]', { timeout: 20000 }).within(() => {
      cy.contains(`(${routeName}) matches`);
      cy.get('[data-testid="air-rule-test-title"]').should('have.text', `Routed Claude: Fix the login redirect ${keyword}`);
      cy.contains(`Started by hand on ${runnerName}`);
    });
    cy.screenshot('ai-runner-rule-tester', { capture: 'viewport' });
    // …and a session of the ignored tool gets none.
    cy.get('#air-t-tool').clear().type(ignoredTool);
    cy.contains('button', /^Test$/).click();
    cy.get('[data-testid="air-rule-test-result"]').should('contain', `(${ignoreName}) matches`).and('contain', 'Ignored: no task is created.');
  });

  it('saves the AI Runs platform settings (platform admins only, §27.5)', function () {
    // The spec's user is a workspace owner; only a platform admin may use this page. Ask the API which it is.
    asUser('GET', '/api/v2/ai-runner/platform/settings', undefined, false, false).then((res) => {
      if (res.status === 403) {
        cy.log('Not a platform admin: the platform settings page is not covered here');
        this.skip();
      }
      expect(res.status).to.eq(200);
      const before = res.body.data.max_queued_followups as number;
      const next = before >= 1000 ? before - 1 : before + 1;
      visit('/dashboard/ai-runner/platform');
      cy.contains('h1', 'AI Runs platform settings', { timeout: 20000 });
      cy.get('#air-p-heartbeat_s').should('have.value', String(res.body.data.heartbeat_s));
      cy.get('#air-p-guard_max-retention_days').should('have.value', String(res.body.data.guard_max.retention_days));
      cy.get('#air-p-max_queued_followups').clear().type(String(next));
      cy.screenshot('ai-runner-platform-settings', { capture: 'viewport' });
      cy.contains('button', 'Save platform settings').click();
      cy.contains('Platform settings saved');
      cy.reload();
      cy.get('#air-p-max_queued_followups', { timeout: 20000 }).should('have.value', String(next));
      // Put it back.
      asUser('PUT', '/api/v2/ai-runner/platform/settings', { max_queued_followups: before }).its('status').should('eq', 200);
    });
  });
});

export {}; // a module: its helpers stay out of the other specs' global scope
