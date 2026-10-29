// Every technote, newest first. Add a file to this folder, then list it here.
import * as edgeDnsAndTls from './edge-dns-and-tls';
import * as hmrcMtdFiling from './hmrc-mtd-filing';
import * as kubernetesDeployment from './kubernetes-deployment';
import * as modulesMap from './modules-map';
import * as multiTenancyAndRbac from './multi-tenancy-and-rbac';
import * as observabilityAndErrors from './observability-and-errors';
import * as pluginsAndConsumerProjects from './plugins-and-consumer-projects';
import * as projectCodeFeatureGating from './project-code-feature-gating';
import * as publicDemoAccount from './public-demo-account';
import * as requestLifecycle from './request-lifecycle';
import * as samlSingleSignOn from './saml-single-sign-on';
import * as ssoSignInFlow from './sso-sign-in-flow';
import * as webhooksAndEvents from './webhooks-and-events';
import * as zeroTrustAdminAccess from './zero-trust-admin-access';

export const TECHNOTES = [edgeDnsAndTls, hmrcMtdFiling, kubernetesDeployment, modulesMap, multiTenancyAndRbac, observabilityAndErrors, pluginsAndConsumerProjects, projectCodeFeatureGating, publicDemoAccount, requestLifecycle, samlSingleSignOn, ssoSignInFlow, webhooksAndEvents, zeroTrustAdminAccess]
    .map((m) => ({ ...m.meta, Body: m.default }))
    .sort((a, b) => (a.date < b.date ? 1 : -1));

export function getTechnote(slug) {
    return TECHNOTES.find((t) => t.slug === slug);
}
