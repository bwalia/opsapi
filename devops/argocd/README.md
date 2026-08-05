# ArgoCD bootstrap for opsapi

GitOps deploy for the opsapi (lapis) backend across all four environments,
using the existing helm chart at `../helm-charts/diytaxreturn-lapis/`.

| File | What it is |
|---|---|
| [`appproject.yaml`](./appproject.yaml) | Security boundary — defines which repo + which namespaces this Project may deploy. |
| [`applicationset.yaml`](./applicationset.yaml) | One template, four Apps (`opsapi-dev`, `opsapi-int`, `opsapi-acc`, `opsapi-prod`). |
| [`../../.github/workflows/argocd-sync-int.yml`](../../.github/workflows/argocd-sync-int.yml) | CI-triggered sync for `int`. Fires on push to `main` when the chart or ArgoCD manifests change. This is the piece that gives "push to main → int deployed automatically" without you having to run any commands after merging PR #456. |

## Why ArgoCD

Today's deploy path is `git push → GitHub Actions self-hosted runner → helm upgrade`.
When the runner goes offline (as it did 2026-06-29 with the cordoned `slworker00`
node), every env is blocked — invisible to anyone not watching the queue.

With ArgoCD the cluster *pulls* the desired state from git on a 3-min interval.
The self-hosted runner is no longer in the deploy critical path; the worst-case
recovery for any deploy is "wait one reconcile cycle". Image rotation, drift
detection, and per-env visibility come for free.

See the analysis in PR description for the full trade-off discussion.

## State after merging this PR

Every env is declared with **`autoSync: false`** in the ApplicationSet.
Auto-reconciliation is off — sync only happens when a human clicks Sync
in the UI OR when the `argocd-sync-int.yml` workflow triggers a sync via
`kubectl patch`.

Rationale: keeping autoSync off means ArgoCD won't fight with any
manual-`kubectl`-patch state your team applied during incidents (all four
envs have some). We layer explicit CI-triggered syncs on top only where
the team wants push-to-main deploys.

## What runs automatically after PR #456 merges

Nothing in the cluster changes at the moment of merge. But the **next push to
`main`** that touches the chart or the ArgoCD manifests fires the
[`argocd-sync-int.yml`](../../.github/workflows/argocd-sync-int.yml) workflow,
which:

1. `kubectl apply -f devops/argocd/` — creates the AppProject + ApplicationSet
   on the first run; idempotent no-op on subsequent runs unless the files
   changed.
2. Waits (up to 60s) for the ApplicationSet controller to materialise
   `opsapi-int`.
3. Triggers a sync of `opsapi-int` and waits (up to 4 min) for
   `Synced + Healthy`.

Runs on **`ubuntu-latest`** — deliberately not self-hosted. The whole point
of moving to ArgoCD is to escape the self-hosted-runner SPOF that killed
every deploy on 2026-06-29. Uses the existing `MY_K3S_CONFIG` secret for
cluster access.

At the same time, [`deploy-k3s.yml`](../../.github/workflows/deploy-k3s.yml)
has been edited so main pushes only deploy **`dev`** via the old helm-from-CI
path. `int` is now ArgoCD-only — no tug-of-war.

## Rollout sequence

### 1. `dev` remains on the old helm-from-CI path for now

Nothing to do — `deploy-k3s.yml` still deploys dev on push to main. It's the
lowest-risk env to keep on the old path while ArgoCD proves itself on int.
When you're ready to cut dev over: add `dev` to `argocd-sync-int.yml`'s
`workflow_dispatch.env.options` list, duplicate the sync step for `opsapi-dev`,
and remove `dev` from `deploy-k3s.yml`'s main-push matrix.

### 2. `int` is now ArgoCD-managed via CI-triggered sync

Push to `main` that touches the chart or `devops/argocd/*` → workflow fires →
int syncs → wait for Healthy → done. If sync fails, the workflow fails red
in the Actions tab (unlike today's Force-Refresh-Pods that hides all
non-fatal errors).

### 3. First-run gotcha to watch

The very first sync after PR #456 merges will **adopt** the existing int
resources into ArgoCD ownership. If someone did a `kubectl edit` during the
recent outages that isn't reflected in `values-int.yaml`, ArgoCD will
revert it to the git-declared state. **Before the first sync completes**,
either:

- Reconcile any wanted local changes into `values-int.yaml`, OR
- Cancel the workflow run and manually sync via the ArgoCD UI first, so
  you can inspect the diff before it applies.

### 4. Then `acc`

Same pattern — copy `argocd-sync-int.yml` to `argocd-sync-acc.yml`, change
the `TARGET_ENV` default to `acc`, adjust the trigger paths to also fire on
`release` branch pushes (which is how acc's helm-from-CI currently works).

### 5. `prod` stays manual sync

Do NOT add prod to any CI-triggered workflow. Prod is always a deliberate
click in the ArgoCD UI. This is the same discipline as the old
`deploy-k3s.yml` (which never auto-deployed prod either).

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
