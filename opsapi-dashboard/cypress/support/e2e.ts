/// <reference types="cypress" />

// Import commands
import './commands';

// Import cypress-real-events for realistic keyboard/mouse interactions
import 'cypress-real-events';

// Prevent TypeScript errors when accessing Cypress namespace
declare global {
  namespace Cypress {
    interface Chainable {
      /**
       * Custom command to login via UI
       * @example cy.login('testuser', 'testpassword')
       */
      login(username: string, password: string): Chainable<void>;

      /**
       * Custom command to login via API (faster for tests that need authenticated state)
       * @example cy.loginByApi('testuser', 'testpassword')
       */
      loginByApi(username: string, password: string): Chainable<void>;

      /**
       * Custom command to logout
       * @example cy.logout()
       */
      logout(): Chainable<void>;

      /**
       * Custom command to get element by data-testid
       * @example cy.getByTestId('login-form')
       */
      getByTestId(testId: string): Chainable<JQuery<HTMLElement>>;

      /**
       * Custom command to clear all auth storage
       * @example cy.clearAuthStorage()
       */
      clearAuthStorage(): Chainable<void>;
    }
  }
}

// Handle uncaught exceptions to prevent test failures from app errors
Cypress.on('uncaught:exception', (err) => {
  // Log the error for debugging
  console.error('Uncaught exception:', err.message);

  // Return false to prevent the error from failing the test
  // Only for known non-critical errors
  if (
    err.message.includes('ResizeObserver loop') ||
    err.message.includes('hydration') ||
    err.message.includes('NEXT_REDIRECT')
  ) {
    return false;
  }

  // Let other errors fail the test
  return true;
});

// Clear storage before each test to ensure clean state
beforeEach(() => {
  cy.clearAuthStorage();
});
