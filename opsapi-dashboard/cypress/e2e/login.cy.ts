/// <reference types="cypress" />

// Storage keys used by the application
const AUTH_TOKEN_KEY = 'auth_token';
const AUTH_USER_KEY = 'auth_user';
const ZUSTAND_AUTH_KEY = 'auth-storage';

describe('Login Page - UI Tests', () => {
  beforeEach(() => {
    // Clear any existing auth state and visit login page
    cy.clearAuthStorage();
    cy.visit('/login');
  });

  describe('Page Load and UI Elements', () => {
    it('should display the login page with all required elements', () => {
      // Check page title/heading
      cy.contains('h1', 'Welcome back').should('be.visible');
      cy.contains('Sign in to your account to continue').should('be.visible');

      // Check form elements
      cy.getByTestId('login-form').should('be.visible');
      cy.getByTestId('login-username-input').should('be.visible');
      cy.getByTestId('login-password-input').should('be.visible');
      cy.getByTestId('login-submit-button').should('be.visible');
      cy.getByTestId('login-toggle-password').should('be.visible');
      cy.getByTestId('login-forgot-password-link').should('be.visible');
    });

    it('should have correct input placeholders', () => {
      cy.getByTestId('login-username-input')
        .should('have.attr', 'placeholder', 'Enter your username');
      cy.getByTestId('login-password-input')
        .should('have.attr', 'placeholder', 'Enter your password');
    });

    it('should have password field hidden by default', () => {
      cy.getByTestId('login-password-input')
        .should('have.attr', 'type', 'password');
    });

    it('should have the submit button enabled', () => {
      cy.getByTestId('login-submit-button')
        .should('not.be.disabled')
        .and('contain', 'Sign in');
    });

    it('should have forgot password link pointing to correct URL', () => {
      cy.getByTestId('login-forgot-password-link')
        .should('have.attr', 'href', '/forgot-password')
        .and('contain', 'Forgot your password?');
    });
  });

  describe('Password Visibility Toggle', () => {
    it('should toggle password visibility when clicking the eye icon', () => {
      const testPassword = 'testpassword123';

      // Type password
      cy.getByTestId('login-password-input').type(testPassword);

      // Verify password is hidden
      cy.getByTestId('login-password-input')
        .should('have.attr', 'type', 'password');

      // Click toggle button to show password
      cy.getByTestId('login-toggle-password').click();

      // Verify password is visible
      cy.getByTestId('login-password-input')
        .should('have.attr', 'type', 'text')
        .and('have.value', testPassword);

      // Click toggle button again to hide password
      cy.getByTestId('login-toggle-password').click();

      // Verify password is hidden again
      cy.getByTestId('login-password-input')
        .should('have.attr', 'type', 'password');
    });
  });

  describe('Form Input Validation', () => {
    it('should show error toast when submitting with empty username', () => {
      // Only fill password
      cy.getByTestId('login-password-input').type('somepassword');
      cy.getByTestId('login-submit-button').click();

      // Check for error toast (react-hot-toast uses role="status")
      cy.get('div[role="status"]', { timeout: 10000 })
        .should('exist')
        .and('contain', 'Please fill in all fields');
    });

    it('should show error toast when submitting with empty password', () => {
      // Only fill username
      cy.getByTestId('login-username-input').type('someuser');
      cy.getByTestId('login-submit-button').click();

      // Check for error toast
      cy.get('div[role="status"]', { timeout: 10000 })
        .should('exist')
        .and('contain', 'Please fill in all fields');
    });

    it('should show error toast when submitting with empty form', () => {
      cy.getByTestId('login-submit-button').click();

      // Check for error toast
      cy.get('div[role="status"]', { timeout: 10000 })
        .should('exist')
        .and('contain', 'Please fill in all fields');
    });

    it('should allow typing in username field', () => {
      const testUsername = 'testuser@example.com';
      cy.getByTestId('login-username-input')
        .type(testUsername)
        .should('have.value', testUsername);
    });

    it('should allow typing in password field', () => {
      const testPassword = 'TestP@ssw0rd!';
      cy.getByTestId('login-password-input')
        .type(testPassword)
        .should('have.value', testPassword);
    });
  });

  describe('Keyboard Navigation', () => {
    it('should allow tabbing through form elements', () => {
      // Focus on username input and use Tab key to navigate
      cy.getByTestId('login-username-input').focus().realPress('Tab');
      cy.getByTestId('login-password-input').should('be.focused');
    });
  });

  describe('Accessibility', () => {
    it('should have proper labels for form inputs', () => {
      // Check username input has associated label
      cy.contains('label', 'Username or Email').should('be.visible');

      // Check password input has associated label
      cy.contains('label', 'Password').should('be.visible');
    });

    it('should have proper autocomplete attributes', () => {
      cy.getByTestId('login-username-input')
        .should('have.attr', 'autocomplete', 'username');

      cy.getByTestId('login-password-input')
        .should('have.attr', 'autocomplete', 'current-password');
    });
  });

  describe('Responsive Design', () => {
    const viewports: Cypress.ViewportPreset[] = ['iphone-6', 'ipad-2', 'macbook-13'];

    viewports.forEach((viewport) => {
      it(`should display correctly on ${viewport}`, () => {
        cy.viewport(viewport);
        cy.visit('/login');

        // Check main elements are visible
        cy.getByTestId('login-form').should('be.visible');
        cy.getByTestId('login-username-input').should('be.visible');
        cy.getByTestId('login-password-input').should('be.visible');
        cy.getByTestId('login-submit-button').should('be.visible');
      });
    });
  });
});

// ============================================
// REAL API INTEGRATION TESTS
// These tests use actual credentials to test real login functionality
// Set CYPRESS_TEST_USERNAME and CYPRESS_TEST_PASSWORD environment variables
// ============================================
describe('Login Page - Real API Integration Tests', () => {
  // Get credentials from environment variables
  const username = Cypress.env('TEST_USERNAME');
  const password = Cypress.env('TEST_PASSWORD');

  // Check if real credentials are provided (not default values)
  const hasRealCredentials =
    username &&
    password &&
    username !== 'testuser' &&
    password !== 'testpassword';

  beforeEach(() => {
    cy.clearAuthStorage();
    cy.visit('/login');
  });

  describe('Login with Valid Credentials', () => {
    beforeEach(function () {
      if (!hasRealCredentials) {
        cy.log('⚠️ Skipping: Set CYPRESS_TEST_USERNAME and CYPRESS_TEST_PASSWORD environment variables with real credentials');
        this.skip();
      }
    });

    it('should successfully login with valid credentials and redirect to dashboard', () => {
      cy.log(`Testing login with username: ${username}`);

      // Type credentials
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type(password);

      // Click login button
      cy.getByTestId('login-submit-button').click();

      // Should show success toast and redirect to dashboard
      cy.get('div[role="status"]', { timeout: 15000 })
        .should('exist')
        .and('contain', 'Login successful');

      // Should redirect to dashboard
      cy.url({ timeout: 15000 }).should('include', '/dashboard');

      // Verify token is stored in localStorage
      cy.window().then((win) => {
        const token = win.localStorage.getItem(AUTH_TOKEN_KEY);
        expect(token).to.not.be.null;
        expect(token).to.not.be.empty;
        cy.log(`Token stored: ${token?.substring(0, 20)}...`);
      });

      // Verify user is stored in localStorage
      cy.window().then((win) => {
        const storedUser = win.localStorage.getItem(AUTH_USER_KEY);
        expect(storedUser).to.not.be.null;
        const user = JSON.parse(storedUser!);
        cy.log(`User stored: ${JSON.stringify(user)}`);
      });
    });

    it('should login with Enter key press', () => {
      cy.log(`Testing Enter key login with username: ${username}`);

      // Type credentials and press Enter
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type(`${password}{enter}`);

      // Should redirect to dashboard
      cy.url({ timeout: 15000 }).should('include', '/dashboard');
    });

    it('should persist session after successful login', () => {
      // Login first
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type(password);
      cy.getByTestId('login-submit-button').click();

      // Wait for redirect to dashboard
      cy.url({ timeout: 15000 }).should('include', '/dashboard');

      // Reload the page
      cy.reload();

      // Should still be on dashboard (not redirected to login)
      cy.url().should('include', '/dashboard');
    });
  });

  describe('Login with Invalid Credentials', () => {
    it('should fail login with wrong password', () => {
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type('wrong-password-12345');
      cy.getByTestId('login-submit-button').click();

      // Should stay on login page
      cy.url({ timeout: 10000 }).should('include', '/login');

      // Button should be re-enabled after error
      cy.getByTestId('login-submit-button', { timeout: 10000 }).should('not.be.disabled');
    });

    it('should fail login with wrong username', () => {
      cy.getByTestId('login-username-input').type('nonexistent-user-12345');
      cy.getByTestId('login-password-input').type(password);
      cy.getByTestId('login-submit-button').click();

      // Should stay on login page
      cy.url({ timeout: 10000 }).should('include', '/login');

      // Button should be re-enabled after error
      cy.getByTestId('login-submit-button', { timeout: 10000 }).should('not.be.disabled');
    });

    it('should fail login with both wrong credentials', () => {
      cy.getByTestId('login-username-input').type('wrong-user-12345');
      cy.getByTestId('login-password-input').type('wrong-password-12345');
      cy.getByTestId('login-submit-button').click();

      // Should stay on login page
      cy.url({ timeout: 10000 }).should('include', '/login');

      // Button should be re-enabled after error
      cy.getByTestId('login-submit-button', { timeout: 10000 }).should('not.be.disabled');
    });
  });

  describe('Authenticated User Redirect', () => {
    beforeEach(function () {
      if (!hasRealCredentials) {
        cy.log('⚠️ Skipping: Set CYPRESS_TEST_USERNAME and CYPRESS_TEST_PASSWORD environment variables with real credentials');
        this.skip();
      }
    });

    it('should redirect already authenticated user from login to dashboard', () => {
      // First login normally
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type(password);
      cy.getByTestId('login-submit-button').click();

      // Wait for redirect to dashboard
      cy.url({ timeout: 15000 }).should('include', '/dashboard');

      // Now try to visit login page
      cy.visit('/login');

      // Should be redirected back to dashboard
      cy.url({ timeout: 10000 }).should('include', '/dashboard');
    });
  });

  describe('Logout Flow', () => {
    beforeEach(function () {
      if (!hasRealCredentials) {
        cy.log('⚠️ Skipping: Set CYPRESS_TEST_USERNAME and CYPRESS_TEST_PASSWORD environment variables with real credentials');
        this.skip();
      }
    });

    it('should clear session after logout', () => {
      // Login first
      cy.getByTestId('login-username-input').type(username);
      cy.getByTestId('login-password-input').type(password);
      cy.getByTestId('login-submit-button').click();

      // Wait for redirect to dashboard
      cy.url({ timeout: 15000 }).should('include', '/dashboard');

      // Clear auth storage (simulating logout)
      cy.clearAuthStorage();

      // Reload should redirect to login
      cy.reload();
      cy.url({ timeout: 10000 }).should('include', '/login');
    });
  });
});
