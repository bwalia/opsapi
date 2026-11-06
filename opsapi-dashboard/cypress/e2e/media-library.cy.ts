/**
 * Media library screens, against a local stack with the fixture from
 * lapis/spec/media-library-e2e/setup.lua:
 *
 *   env -u ELECTRON_RUN_AS_NODE npx cypress run --spec cypress/e2e/media-library.cy.ts \
 *     --config baseUrl=http://127.0.0.1:8039 --env API_URL=http://127.0.0.1:4020
 *
 * Signs in as workspace A's owner by putting the fixture's token (read inside the
 * API container, never printed) into the dashboard's storage.
 */
type Person = {
  uuid: string;
  email: string;
  first_name: string;
  last_name: string;
  namespace_uuid: string;
  slug: string;
  name: string;
  token: string;
};

function signIn() {
  return cy.exec('docker exec opsapi cat /tmp/ml_tokens.json', { log: false }).then((res) => {
    const u = (JSON.parse(res.stdout) as { a: { owner: Person } }).a.owner;
    const user = { uuid: u.uuid, email: u.email, first_name: u.first_name, last_name: u.last_name, roles: [] };
    const ns = { uuid: u.namespace_uuid, slug: u.slug, name: u.name };
    return (win: Window) => {
      win.localStorage.setItem('auth_token', u.token);
      win.localStorage.setItem('auth_user', JSON.stringify(user));
      win.localStorage.setItem('auth-storage', JSON.stringify({ state: { token: u.token, user, isAuthenticated: true }, version: 0 }));
      win.localStorage.setItem('current_namespace', JSON.stringify(ns));
      win.localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: ns }, version: 0 }));
      win.localStorage.setItem('pwa-install-dismissed', '1');
    };
  });
}

const RUN = Date.now();

describe('Media library', () => {
  it('upload, describe, crop a copy, then use it in a post', () => {
    signIn().then((init) => {
      // The list request only goes out once the page is live, so a file picked
      // after it lands isn't dropped.
      cy.intercept('GET', '**/api/v2/cms/media?*').as('list');
      cy.visit('/dashboard/cms?tab=media', { onBeforeLoad: init });
      cy.contains('button', 'Media library', { timeout: 30000 }).should('have.attr', 'aria-current', 'page');
      cy.wait('@list', { timeout: 30000 });

      cy.get('input[type="file"]').selectFile(
        { contents: 'cypress/fixtures/media-sample.png', fileName: `sample-${RUN}.png`, mimeType: 'image/png' },
        { force: true },
      );
      cy.contains('Image uploaded.', { timeout: 20000 });
      cy.get('[aria-label="Image details"]').within(() => {
        cy.contains(`sample-${RUN}.png`);
        cy.contains('120 × 80 px');
        cy.contains('Not used in any post or page yet.');
        cy.get('textarea').type('Blue and green stripes');
        cy.contains('button', 'Save details').click();
      });
      cy.contains('Saved.');
      cy.screenshot('01-library-details', { capture: 'viewport' });

      cy.contains('button', 'Crop / resize').click();
      cy.contains('button', 'Square').click();
      cy.get('input[type="number"]').clear().type('40');
      cy.contains('Height follows: 40 px');
      cy.screenshot('02-crop', { capture: 'viewport' });
      cy.contains('button', 'Save as a new image').click();
      cy.contains('Saved as a new image', { timeout: 20000 });
      cy.get('[aria-label="Image details"]').within(() => {
        cy.contains(`sample-${RUN}-edited.png`, { timeout: 20000 });
        cy.contains('40 × 40 px');
        cy.contains('An edited copy.');
      });

      // Use it in a new post: the editor's image button and the featured image.
      cy.visit('/dashboard/cms/posts/new', { onBeforeLoad: init });
      cy.get('button[title="Insert image (from the media library or your computer)"]', { timeout: 30000 }).click();
      cy.contains('Choose an image');
      cy.get('[role="dialog"]').within(() => {
        cy.get('input[type="search"]').type(`sample-${RUN}-edited`);
        cy.get(`button[aria-label="Blue and green stripes"]`, { timeout: 20000 }).first().click();
        cy.contains('button', 'Use this image').click();
      });
      cy.get('.ProseMirror img[alt="Blue and green stripes"]')
        .should('have.attr', 'src')
        .and('contain', '/api/v2/public/media/');

      cy.contains('button', 'Choose image').click();
      cy.contains('Choose a featured image');
      cy.get('[role="dialog"]').within(() => {
        cy.get('input[type="search"]').type(`sample-${RUN}.png`);
        cy.get(`button[aria-label="Blue and green stripes"]`, { timeout: 20000 }).first().dblclick();
      });
      cy.get('img[alt="Featured image preview"]').should('have.attr', 'src').and('contain', '/api/v2/public/media/');
      cy.contains('button', 'Change image');
      cy.screenshot('03-post-editor', { capture: 'fullPage' });
    });
  });
});
