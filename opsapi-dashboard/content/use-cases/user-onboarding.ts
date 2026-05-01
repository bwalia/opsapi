import type { UseCaseDefinition } from './types';

export const userOnboarding: UseCaseDefinition = {
  slug: 'user-onboarding',
  title: 'User onboarding flow',
  subtitle:
    'Register a new user, exchange credentials for a JWT, and fetch the authenticated profile.',
  intro:
    'This walkthrough shows the calls a typical signup flow makes against OpsAPI. Each step links to its underlying endpoint so you can jump directly into Swagger UI to test it live.',
  steps: [
    {
      title: '1. Create the user',
      description:
        'Call the create endpoint with a unique email and password. OpsAPI hashes the password with bcrypt before persisting and returns the new user record.',
      match: { method: 'post', path: '/api/v2/users' },
    },
    {
      title: '2. Exchange credentials for a JWT',
      description:
        'Post the same credentials to the auth endpoint. OpsAPI returns a signed JWT valid for 24 hours — attach it as a Bearer token on all subsequent requests.',
      match: { method: 'post', path: '/api/v2/auth/login' },
    },
    {
      title: '3. Fetch the authenticated profile',
      description:
        'With the bearer token attached, call the users endpoint to retrieve the full profile including roles and namespace memberships.',
      match: { method: 'get', path: '/api/v2/users/{uuid}' },
    },
  ],
};
