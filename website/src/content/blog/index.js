// Every blog post, newest first. Add a file to this folder, then list it here.
import * as oneSignIn from './one-sign-in-every-app';
import * as oneApi from './one-api-many-modules';

export const POSTS = [oneSignIn, oneApi]
    .map((m) => ({ ...m.meta, Body: m.default }))
    .sort((a, b) => (a.date < b.date ? 1 : -1));

export function getPost(slug) {
    return POSTS.find((p) => p.slug === slug);
}
