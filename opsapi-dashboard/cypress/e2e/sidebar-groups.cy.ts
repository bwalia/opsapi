/**
 * Sidebar groups: the menu arrives with `groups` and every item's `group`; the sidebar shows the
 * ungrouped items at the top and each group as a collapsible section (the current page's group opens
 * by itself, the open ones are remembered, the filter searches item and group names, and in the icon
 * rail a group is one icon that opens the sidebar on it).
 *
 * Needs the Property Deals sandbox API (projects/property-deals/spec/run.sh with KEEP=1) and the
 * dashboard pointed at it — same env as property-deals.cy.ts:
 *   CYPRESS_API_URL=http://127.0.0.1:<api port> CYPRESS_PD_MOCK=http://127.0.0.1:<mock port> CYPRESS_PD_JWT_SECRET=… \
 *   CYPRESS_PD_PSQL="docker exec -i pd-pg-<id> psql -U postgres -d e2e -tA -c" \
 *   npx cypress run --spec cypress/e2e/sidebar-groups.cy.ts
 */

type Session = { token: string; user: Record<string, unknown>; namespace: { uuid: string; name: string; slug: string } };
type MenuGroup = { key: string; name: string; icon: string };
type MenuItem = { key: string; name: string; path: string; group?: string | null };

let owner: Session;

function visitAs(s: Session, path: string, keepStorage = false) {
  cy.visit(path, {
    onBeforeLoad(win) {
      if (!keepStorage) win.localStorage.clear();
      win.localStorage.setItem('auth_token', s.token);
      win.localStorage.setItem('auth_user', JSON.stringify(s.user));
      win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token: s.token, user: s.user, isAuthenticated: true }, version: 0 }));
      win.localStorage.setItem('current_namespace', JSON.stringify(s.namespace));
      win.localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: s.namespace, namespacePermissions: null, isNamespaceOwner: true, userSettings: null }, version: 0 }));
    },
  });
}

const nav = () => cy.get('nav[aria-label="Main navigation"]');
const groupButton = (name: string) => nav().find('button[aria-expanded]').contains('span', name).parents('button').first();

describe('Sidebar groups', () => {
  let groups: MenuGroup[] = [];
  let items: MenuItem[] = [];

  before(() => {
    cy.exec('python3 -I ../projects/property-deals/spec/web_seed.py', {
      timeout: 180000,
      env: {
        PD_API: Cypress.env('API_URL'), PD_MOCK: Cypress.env('PD_MOCK'),
        PD_JWT_SECRET: Cypress.env('PD_JWT_SECRET'), PD_PSQL: Cypress.env('PD_PSQL'),
      },
    }).then((res) => {
      // The other workspace's owner: every module of the deployment, Property Deals switched on.
      owner = JSON.parse(res.stdout).outsider;
    });
  });

  beforeEach(() => {
    cy.viewport(1280, 900);
    cy.intercept('GET', '**/api/v2/user/menu*').as('menu');
  });

  it('shows ungrouped items on top and every group from the API as a closed section', () => {
    visitAs(owner, '/dashboard');
    cy.wait('@menu').then(({ response }) => {
      const data = response?.body?.data ?? response?.body;
      groups = data.groups;
      items = data.main_menu;
      expect(groups.length, 'groups returned').to.be.greaterThan(2);
      expect(groups.map((g) => g.key)).to.include('admin');
      expect(groups.map((g) => g.key)).to.include('plugin:property_deals');
      expect(items.find((i) => i.key === 'dashboard')?.group ?? null, 'Dashboard is ungrouped').to.equal(null);
    });
    nav().contains('a', 'Dashboard').should('be.visible');
    cy.then(() => {
      for (const g of groups) {
        const members = items.filter((i) => i.group === g.key);
        if (members.length > 1) {
          groupButton(g.name).should('have.attr', 'aria-expanded', 'false');
        } else {
          nav().contains('a', members[0].name).should('be.visible'); // a one-item group is just the item
        }
      }
    });
    cy.screenshot('sidebar-groups-closed', { capture: 'viewport' });
  });

  it('opens a group on click and remembers it after a reload', () => {
    visitAs(owner, '/dashboard');
    cy.wait('@menu');
    nav().contains('a', 'Roles').should('not.exist');
    groupButton('Administration').click().should('have.attr', 'aria-expanded', 'true');
    nav().contains('a', 'Roles').should('be.visible');
    cy.screenshot('sidebar-groups-admin-open', { capture: 'viewport' });
    visitAs(owner, '/dashboard', true);
    groupButton('Administration').should('have.attr', 'aria-expanded', 'true');
    groupButton('Administration').click().should('have.attr', 'aria-expanded', 'false');
    nav().contains('a', 'Roles').should('not.exist');
  });

  it("opens the current page's group by itself and marks the page", () => {
    visitAs(owner, '/dashboard/property-deals/deals');
    cy.wait('@menu');
    groupButton('Property Deals').should('have.attr', 'aria-expanded', 'true');
    nav().contains('a', 'Deals today').should('be.visible');
    nav().find('a[href="/dashboard/property-deals/deals"]').should('have.class', 'text-primary-500');
    cy.screenshot('sidebar-groups-current-page', { capture: 'viewport' });
  });

  it('filters by item and by group name', () => {
    visitAs(owner, '/dashboard');
    cy.wait('@menu');
    nav().find('input[aria-label="Filter menu"]').type('roles');
    nav().contains('a', 'Roles').should('be.visible');
    nav().contains('a', 'Deals today').should('not.exist');
    nav().find('input[aria-label="Filter menu"]').clear().type('property deals');
    nav().contains('a', 'Deals today').should('be.visible');
    nav().contains('a', 'Roles').should('not.exist');
  });

  it('in the icon rail a group is one icon that opens the sidebar on that group', () => {
    visitAs(owner, '/dashboard');
    cy.wait('@menu');
    cy.get('button[aria-label="Collapse sidebar"]').click();
    nav().find('button[aria-label="Administration (open the menu)"]').should('be.visible');
    cy.screenshot('sidebar-groups-rail', { capture: 'viewport' });
    nav().find('button[aria-label="Administration (open the menu)"]').click();
    groupButton('Administration').should('have.attr', 'aria-expanded', 'true');
    nav().contains('a', 'Roles').should('be.visible');
  });
});
