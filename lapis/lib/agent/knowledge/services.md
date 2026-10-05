---
title: Services
pages: /dashboard/services
api: /api/v2/namespace/services, /api/v2/namespace/github-integrations
modules: services
tools:
suggestions: Deploy the Production API service | Show the latest deployments of a service | Add variable TARGET_ENV=staging to a service
readonly: false
---
# Services
Deployment services: each points at a GitHub repo + workflow file + branch and uses a GitHub integration (a stored Personal Access Token). "Deploy" runs the workflow (workflow_dispatch) with the service's secrets and variables as inputs. Service status: active | inactive | archived. Deployment status: pending, triggered, running, success, failure, cancelled, error.

## Using the page
- Services list: search, status filter, "Settings", "Add Service" (Service Name, Description, GitHub integration, GitHub Owner, Repository Name, Workflow File, Branch, icon, color). Row icons: Deploy ("Trigger Deployment" confirm), Edit, Delete.
- Service page: Edit / Delete / Deploy; Configuration; "Workflow Secrets" ("Add Secret"); "Workflow Variables" ("Add Variable": Variable Key, Variable Value, Description); "Recent Deployments" (sync status, "View on GitHub"); Statistics; GitHub Integration.
- Settings (/dashboard/services/settings): "Add GitHub Integration" (Name, token, GitHub Username), edit/replace token, statistics.

## Rules
- Create requires name, github_owner, github_repo, github_workflow_file; defaults: branch main, icon server, color blue, status active. github_integration_id is the NUMERIC id from the integrations list; the UI requires one and deploy fails without it.
- icon: server|cloud|database|code|globe|shield|zap|box|cpu|hard-drive|terminal|package|layers|git-branch|rocket; color: blue|green|purple|orange|red|cyan|pink|indigo|yellow|teal.
- Deploy needs an active service and services manage permission (or workspace owner). Optional inputs override variables with the same key; keys must match the workflow's workflow_dispatch inputs. Confirm with the user before deploying.
- Secrets and GitHub tokens are entered ONLY in the UI: never ask for a secret value or token and never call the secrets or integration create/update endpoints.
- Variable PUT: always send is_required (omitting it sets false). Duplicate key → 400.
- Deleting a service also deletes its secrets, variables and deployment history.
- {uuid} accepts the service uuid (numeric id also works); {vid}/{did} are the variable/deployment uuid.

## API
- `GET /api/v2/namespace/services?page&per_page&status=active|inactive|archived&search&order_by&order_dir` — list
- `GET /api/v2/namespace/services/stats` — totals (services, deployments, successes, failures, active integrations)
- `GET /api/v2/namespace/services/{uuid}` — detail incl. masked secrets, variables, last 10 deployments
- `POST /api/v2/namespace/services {name*, github_owner*, github_repo*, github_workflow_file*, github_branch, github_integration_id: int, description, icon, color, status}` — create
- `PUT /api/v2/namespace/services/{uuid} {...same fields}` — update
- `DELETE /api/v2/namespace/services/{uuid}` — delete
- `POST /api/v2/namespace/services/{uuid}/deploy {inputs: {KEY: "value"}}` — trigger the workflow
- `GET /api/v2/namespace/services/{uuid}/deployments?page&per_page&status` — deployment history
- `GET /api/v2/namespace/services/{uuid}/deployments/{did}` — one deployment
- `POST /api/v2/namespace/services/{uuid}/deployments/{did}/sync` — refresh status from GitHub
- `POST /api/v2/namespace/services/sync-deployments` — sync all pending deployments
- `GET /api/v2/namespace/services/{uuid}/variables` — variables
- `POST /api/v2/namespace/services/{uuid}/variables {key*, value, description, is_required: bool, default_value}` — add
- `PUT /api/v2/namespace/services/{uuid}/variables/{vid} {key, value, description, is_required, default_value}` — update
- `DELETE /api/v2/namespace/services/{uuid}/variables/{vid}` — delete
- `GET /api/v2/namespace/github-integrations` — integrations (id, name, github_username, status) for github_integration_id
