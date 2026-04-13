/// <reference types="cypress" />

// Storage keys used by the application (must match lib/api-client.ts)
const AUTH_TOKEN_KEY = 'auth_token';
const AUTH_USER_KEY = 'auth_user';
const ZUSTAND_AUTH_KEY = 'auth-storage';

/**
 * Custom command to get element by data-testid attribute
 */
Cypress.Commands.add('getByTestId', (testId: string) => {
  return cy.get(`[data-testid="${testId}"]`);
});

/**
 * Custom command to login via UI
 */
Cypress.Commands.add('login', (username: string, password: string) => {
  cy.visit('/login');
  cy.getByTestId('login-username-input').clear().type(username);
  cy.getByTestId('login-password-input').clear().type(password);
  cy.getByTestId('login-submit-button').click();
});

/**
 * Custom command to login via API (faster for tests that need authenticated state)
 */
Cypress.Commands.add('loginByApi', (username: string, password: string) => {
  const apiUrl = Cypress.env('API_URL');

  cy.request({
    method: 'POST',
    url: `${apiUrl}/auth/login`,
    form: true,
    body: {
      username,
      password,
    },
    failOnStatusCode: false,
  }).then((response) => {
    if (response.status === 200 && response.body.token) {
      // Store token in localStorage (use correct keys)
      window.localStorage.setItem(AUTH_TOKEN_KEY, response.body.token);

      // Store user if available
      if (response.body.user) {
        window.localStorage.setItem(AUTH_USER_KEY, JSON.stringify(response.body.user));
      }

      // Also set Zustand persisted state
      const zustandState = {
        state: {
          token: response.body.token,
          user: response.body.user || null,
          isAuthenticated: true,
        },
        version: 0,
      };
      window.localStorage.setItem(ZUSTAND_AUTH_KEY, JSON.stringify(zustandState));
    }
  });
});

/**
 * Custom command to logout
 */
Cypress.Commands.add('logout', () => {
  cy.clearAuthStorage();
  cy.visit('/login');
});

/**
 * Custom command to clear all auth storage
 */
Cypress.Commands.add('clearAuthStorage', () => {
  cy.window().then((win) => {
    // Clear all auth-related localStorage keys
    win.localStorage.removeItem(AUTH_TOKEN_KEY);
    win.localStorage.removeItem(AUTH_USER_KEY);
    win.localStorage.removeItem(ZUSTAND_AUTH_KEY);
    // Also clear sessionStorage
    win.sessionStorage.clear();
  });
});
