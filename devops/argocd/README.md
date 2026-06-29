# ArgoCD bootstrap for opsapi

GitOps deploy for the opsapi (lapis) backend across all four environments,
using the existing helm chart at `../helm-charts/diytaxreturn-lapis/`.

| File | What it is |
|---|---|
| [`appproject.yaml`](./appproject.yaml) | Security boundary — defines which repo + which namespaces this Project may deploy. |
| [`applicationset.yaml`](./applicationset.yaml) | One template, four Apps (`opsapi-dev`, `opsapi-int`, `opsapi-acc`, `opsapi-prod`). |

## Why ArgoCD

Today's deploy path is `git push → GitHub Actions self-hosted runner → helm upgrade`.
When the runner goes offline (as it did 2026-06-29 with the cordoned `slworker00`
node), every env is blocked — invisible to anyone not watching the queue.

With ArgoCD the cluster *pulls* the desired state from git on a 3-min interval.
The self-hosted runner is no longer in the deploy critical path; the worst-case
recovery for any deploy is "wait one reconcile cycle". Image rotation, drift
detection, and per-env visibility come for free.

See the analysis in PR description for the full trade-off discussion.

## Pre-cutover state (initial commit)

Every env is created with **`autoSync: false`**. The Applications appear in the
ArgoCD UI as `OutOfSync` (because no sync has run yet), but ArgoCD makes no
changes — it just reports what *would* happen.

This is safe to apply alongside the existing GitHub Actions deploy. The two
mechanisms do not fight because ArgoCD isn't acting.

## Rollout sequence

### 1. Apply the manifests (one-time bootstrap)

```bash
kubectl apply -f devops/argocd/appproject.yaml
kubectl apply -f devops/argocd/applicationset.yaml
```

You should see four Applications in the ArgoCD UI under the `opsapi` project,
all OutOfSync. Open each and inspect the diff — it should match the helm
output you'd get from `helm template ./devops/helm-charts/diytaxreturn-lapis -f values-<env>.yaml`.

### 2. Manually sync `dev` first

In the ArgoCD UI → `opsapi-dev` → Sync. Watch the resources go green.
Confirm the dev pod is Ready, `/health` returns 200.

If anything looks wrong, hit Refresh / Hard-Refresh, or Rollback to the
previous revision. The old `deploy-k3s.yml` workflow is still wired up
and will keep dev working if you delete the Application.

### 3. Enable auto-sync for `dev`

Edit `applicationset.yaml` — for the `dev` element, flip:

```yaml
- env: dev
  revision: main
  autoSync: true        # was: false
  selfHeal: true        # was: false
```

Commit and merge. Now every push to `main` automatically deploys to dev.

### 4. Remove `dev` from `deploy-k3s.yml`'s matrix

In `.github/workflows/deploy-k3s.yml` — the `plan` job's case statement:

```yaml
elif [ "$ref" = "refs/heads/main" ]; then
  ENVS_JSON='["dev","int"]'           # → '["int"]' once ArgoCD owns dev
```

Now there's only one deploy mechanism per env. No tug-of-war.

### 5. Repeat for `int`, then `acc`, then `prod`

Per-env recommended end-state:

| env | autoSync | selfHeal | revision | Rationale |
|---|---|---|---|---|
| dev | `true` | `true` | `main` | Lowest blast radius, move fast |
| int | `true` | `true` | `main` | Lowest blast radius, move fast |
| acc | `true` | `false` | `release` | Auto-deploys on `release` push, but humans can intervene during incidents without ArgoCD reverting |
| prod | `false` | `false` | `release` | Promotion to prod is always a deliberate human Sync click |

Keep prod manual-sync forever. The whole point of GitOps is *traceable* deploys;
that doesn't conflict with requiring a human click for the riskiest one.

## What this doesn't solve

- **Stale-image cache on running pods** — the deeper hmrc_businesses bug. The
  ArgoCD chart still uses `image.tag: latest` (from values-*.yaml). To
  eliminate the floating-tag failure mode entirely, either:
    - Add [argocd-image-updater](https://argocd-image-updater.readthedocs.io/)
      to rewrite `image.tag` to a fresh digest on every push.
    - OR have CI commit the digest back into `values-<env>.yaml` (more
      GitOps-pure, gives a git audit trail per promotion).
  Both are follow-up PRs; this one keeps the existing `:latest` semantics
  to minimise migration surface area.

- **The chart-ownership conflict** between this chart and
  `diy-tax-return-uk`'s `diytaxreturn-fastapi` chart (which today owns
  `*-api.diytaxreturn.co.uk`). ArgoCD will sync both charts to their declared
  state — the conflict has to be solved by deciding which chart owns the
  Ingress (sentinel comments already in values-int.yaml + values-acc.yaml
  document the current decision: fastapi chart wins, this chart's
  `ingress.enabled: false`).

- **The cordoned `slworker00` node.** Uncordon it independently —
  `kubectl uncordon slworker00`. ArgoCD can't deploy pods to an unschedulable
  node either.

## Rollback

If anything goes wrong after merge:

```bash
kubectl -n argocd delete applicationset opsapi
kubectl -n argocd delete appproject opsapi
```

This deletes the ArgoCD-managed Applications but **does NOT delete the cluster
resources they created** (because the Application's finalizer is what triggers
deletion — and we kept `preserveResourcesOnDeletion: false` so generated Apps
disappear with the Set). The chart resources (Deployments, Services, etc) keep
running. The old `deploy-k3s.yml` deploy can resume.

If you want to also tear down the deployed chart resources, set
`preserveResourcesOnDeletion: true` on the ApplicationSet *before* deleting
it — but you almost never want this during a rollback.
