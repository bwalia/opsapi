/**
 * Property PA in the browser: every page opens for the manager (Ashley), the operator (Sophie) only
 * sees what her role allows (no Manager today, Teach now only for her own rules), and a workspace
 * with the plugin off gets the "switched off" card instead of a raw 404.
 *
 * Needs the Property Deals sandbox API (projects/property-deals/spec/run.sh with KEEP=1, which loads
 * property-pa too) and the dashboard pointed at it:
 *   CYPRESS_API_URL=http://127.0.0.1:<api port> CYPRESS_PD_MOCK=http://127.0.0.1:<mock port> \
 *   CYPRESS_PD_JWT_SECRET=… CYPRESS_PD_PSQL="docker exec -i pd-pg-<id> psql -U postgres -d e2e -tA -c" \
 *   npx cypress run --spec cypress/e2e/property-pa.cy.ts
 * The seed (inline below, on projects/property-pa/spec/pa_common.py) builds fresh workspaces each run.
 */

export {}; // a module: its helpers don't collide with property-deals.cy.ts

type Session = { token: string; user: Record<string, unknown>; namespace: { uuid: string; name: string; slug: string } };
type Seed = { manager: Session; operator: Session; outsider: Session };

// pa_common.setup: both plugins on, roles, PA setup and the How It Works fixtures (Sophie = operator,
// Ashley = manager). The outsider's workspace has Property PA off. Prints one JSON line.
const SEED = `
import datetime, json, os, sys
sys.path.insert(0, os.path.abspath('../projects/property-pa/spec'))
import pa_common
import pdtest
from pdtest import USERS, jwt, workspace
pdtest.check = lambda *a, **k: None
sfx = datetime.datetime.now().strftime('%H%M%S')
S, _ = pa_common.setup('PA Web Ltd', 'pa-web-' + sfx)
B = workspace('owner_b', 'PA Off Co', 'pa-off-' + sfx)
def session(user, ns, name, slug):
    uuid, email = USERS[user]
    return {'token': jwt(user), 'user': {'uuid': uuid, 'email': email, 'username': email.split('@')[0],
            'first_name': 'PA', 'last_name': user}, 'namespace': {'uuid': ns, 'name': name, 'slug': slug}}
print(json.dumps({'manager': session('manager_s', S, 'PA Web Ltd', 'pa-web-' + sfx),
                  'operator': session('operator_s', S, 'PA Web Ltd', 'pa-web-' + sfx),
                  'outsider': session('owner_b', B, 'PA Off Co', 'pa-off-' + sfx)}))
`;

let seed: Seed;

function visitAs(s: Session, path: string) {
  cy.visit(path, {
    onBeforeLoad(win) {
      win.localStorage.clear();
      win.localStorage.setItem('auth_token', s.token);
      win.localStorage.setItem('auth_user', JSON.stringify(s.user));
      win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token: s.token, user: s.user, isAuthenticated: true }, version: 0 }));
      win.localStorage.setItem('current_namespace', JSON.stringify(s.namespace));
      // Permissions come from the workspace list (its roles) once the dashboard loads it.
      win.localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: s.namespace, namespacePermissions: null, isNamespaceOwner: false, userSettings: null }, version: 0 }));
    },
  });
}

describe('Property PA — pages, roles and the plugin switch', () => {
  before(() => {
    cy.exec(`python3 -I -c "${SEED.replace(/"/g, '\\"')}"`, {
      timeout: 180000,
      env: {
        PD_API: Cypress.env('API_URL'),
        PD_JWT_SECRET: Cypress.env('PD_JWT_SECRET'),
        PD_PSQL: Cypress.env('PD_PSQL'),
        PD_MOCK: Cypress.env('PD_MOCK'),
      },
    }).then((r) => {
      seed = JSON.parse(r.stdout.trim().split('\n').pop() as string) as Seed;
    });
  });

  it('Every page opens for a manager (smoke + screenshots)', () => {
    const pages: [string, string][] = [
      ['today', 'Today'], ['capture', 'Capture'], ['opportunities', 'My opportunities'],
      ['manager', 'Manager today'], ['insights', 'PA insights'], ['knowledge', 'PA knowledge'],
    ];
    for (const [path, title] of pages) {
      visitAs(seed.manager, `/dashboard/property-pa/${path}`);
      cy.contains('h1', title, { timeout: 20000 });
      cy.get('[role="alert"]').should('not.exist');
      cy.screenshot(`pa-page-${path}`, { capture: 'viewport' });
    }
  });

  it('An operator gets no manager pages', () => {
    for (const path of ['manager', 'insights']) {
      visitAs(seed.operator, `/dashboard/property-pa/${path}`);
      cy.contains('Ask a workspace admin for a Property PA role', { timeout: 20000 });
      cy.contains('h1', /Manager today|PA insights/).should('not.exist');
    }
  });

  it('An operator can only teach-and-approve her own rules', () => {
    visitAs(seed.operator, '/dashboard/property-pa/knowledge');
    cy.contains('h1', 'PA knowledge', { timeout: 20000 });
    cy.get('select#who-it-applies-to').as('scope');
    cy.get('@scope').should('have.value', 'personal');
    cy.contains('button', 'Teach now').should('exist');
    cy.get('@scope').select('company');
    cy.contains('button', 'Teach now').should('not.exist');
    cy.contains('button', 'Propose').should('exist');
  });

  it('Plugin off: the switched-off card, not a raw 404', () => {
    visitAs(seed.outsider, '/dashboard/property-pa/today');
    cy.contains('Property PA is switched off for this workspace', { timeout: 20000 });
    cy.contains('a', 'Plugins').should('have.attr', 'href', '/dashboard/namespace/plugins');
  });
});
