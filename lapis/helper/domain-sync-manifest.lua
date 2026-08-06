--[[
    Domain Sync — k3s Manifest Generator
    ====================================

    Renders a self-contained Kubernetes CronJob (scheduled) or Job (run-once)
    that, each run:
      1. fetches the live domain export from opsapi (GET /api/v2/domains/export),
      2. writes it as JSON to the configured path inside the target GitHub repo,
      3. commits and pushes to the configured branch.

    Secrets: NONE are baked into the manifest. Both the GitHub PAT and the opsapi
    machine token are read at runtime from a single Kubernetes Secret whose name
    is `github_token_secret_ref` — populated by the External Secrets Operator from
    the vault (see docs). The manifest references only the Secret + key names.

    Non-secret parameters (repo, branch, path, schedule, base URL, namespace) are
    rendered as literals; they are not sensitive.
]]

local DomainSyncManifest = {}

-- Minimal YAML scalar escaping: wrap in double quotes, escape backslash + quote.
local function q(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

-- Kubernetes name-safe slug.
local function slug(s)
    s = tostring(s or "sync"):lower():gsub("[^a-z0-9%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if s == "" then s = "sync" end
    return s:sub(1, 40)
end

-- The container script (POSIX sh). Fails loudly (set -e). x-access-token:<PAT>
-- is GitHub's documented way to authenticate a git push with a PAT.
local function container_script()
    return table.concat({
        "set -eu",
        "apk add --no-cache git curl jq >/dev/null",
        'echo "Fetching domain export from opsapi..."',
        'curl -fsSL -H "Authorization: Bearer ${OPSAPI_TOKEN}" -H "X-Namespace-Id: ${NAMESPACE_ID}" ' ..
            '"${OPSAPI_BASE}/api/v2/domains/export" | jq . > /tmp/domains.json',
        'echo "Cloning ${GIT_REPO} (${GIT_BRANCH})..."',
        'git clone --depth 1 -b "${GIT_BRANCH}" ' ..
            '"https://x-access-token:${GITHUB_TOKEN}@github.com/${GIT_REPO}.git" /tmp/repo',
        'mkdir -p "/tmp/repo/$(dirname "${FILE_PATH}")"',
        'cp /tmp/domains.json "/tmp/repo/${FILE_PATH}"',
        'cd /tmp/repo',
        'git config user.name "${AUTHOR_NAME}"',
        'git config user.email "${AUTHOR_EMAIL}"',
        'git add "${FILE_PATH}"',
        'if git diff --cached --quiet; then echo "No changes"; exit 0; fi',
        'git commit -m "chore(domains): sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"',
        'git push origin "${GIT_BRANCH}"',
        'echo "Domain sync complete."',
    }, "\n")
end

-- Build the pod spec (containers + env), each line prefixed with `indent`.
local function pod_spec_lines(cfg, opts, indent)
    local gh_key = cfg.github_token_secret_key or "github-token"
    local op_key = cfg.opsapi_token_secret_key or "opsapi-token"
    local env = {
        { "GIT_REPO", cfg.github_repo },
        { "GIT_BRANCH", cfg.github_branch or "main" },
        { "FILE_PATH", cfg.file_path or "domains.json" },
        { "OPSAPI_BASE", opts.base_url },
        { "NAMESPACE_ID", opts.namespace_uuid or "" },
        { "AUTHOR_NAME", cfg.commit_author_name or "opsapi-domain-sync" },
        { "AUTHOR_EMAIL", cfg.commit_author_email or "domain-sync@opsapi" },
    }

    local lines = {}
    local function add(s) table.insert(lines, indent .. s) end

    add("restartPolicy: Never")
    add("containers:")
    add("  - name: domain-sync")
    add('    image: "alpine:3.20"')
    add('    command: ["/bin/sh", "-c"]')
    add("    args:")
    add("      - |")
    -- script body, indented under the block scalar
    for sline in (container_script() .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, indent .. "        " .. sline)
    end
    add("    env:")
    for _, kv in ipairs(env) do
        add("      - name: " .. kv[1])
        add("        value: " .. q(kv[2]))
    end
    -- Secrets from the ESO-populated k8s Secret
    add("      - name: GITHUB_TOKEN")
    add("        valueFrom:")
    add("          secretKeyRef:")
    add("            name: " .. q(cfg.github_token_secret_ref))
    add("            key: " .. q(gh_key))
    add("      - name: OPSAPI_TOKEN")
    add("        valueFrom:")
    add("          secretKeyRef:")
    add("            name: " .. q(cfg.github_token_secret_ref))
    add("            key: " .. q(op_key))

    return lines
end

-- Validate the config + resolve the base URL. Returns base_url, err.
local function resolve(cfg, opts)
    if not cfg then return nil, "sync config required" end
    if not cfg.github_repo or cfg.github_repo == "" then
        return nil, "github_repo is required (owner/repo)"
    end
    if not cfg.github_token_secret_ref or cfg.github_token_secret_ref == "" then
        return nil, "github_token_secret_ref is required (name of the ESO-populated k8s Secret)"
    end
    local base_url = (opts and opts.opsapi_base_url_override) or cfg.opsapi_base_url
    if not base_url or base_url == "" then
        return nil, "opsapi_base_url is required (where the CronJob fetches the export)"
    end
    return base_url, nil
end

--- Render a scheduled CronJob manifest.
function DomainSyncManifest.render_cronjob(cfg, opts)
    opts = opts or {}
    local base_url, err = resolve(cfg, opts)
    if not base_url then return nil, err end
    opts.base_url = base_url

    local name = "domain-sync-" .. slug(cfg.name or cfg.uuid)
    local k8s_ns = opts.k8s_namespace or "default"

    local out = {
        "apiVersion: batch/v1",
        "kind: CronJob",
        "metadata:",
        "  name: " .. q(name),
        "  namespace: " .. q(k8s_ns),
        "  labels:",
        '    app.kubernetes.io/managed-by: "opsapi"',
        '    opsapi.io/feature: "domain-sync"',
        "spec:",
        "  schedule: " .. q(cfg.schedule or "0 3 * * *"),
        "  concurrencyPolicy: Forbid",
        "  successfulJobsHistoryLimit: 3",
        "  failedJobsHistoryLimit: 3",
        "  jobTemplate:",
        "    spec:",
        "      backoffLimit: 2",
        "      template:",
        "        spec:",
    }
    for _, l in ipairs(pod_spec_lines(cfg, opts, "          ")) do table.insert(out, l) end
    return table.concat(out, "\n") .. "\n", nil
end

--- Render a run-once Job manifest (for "sync now").
function DomainSyncManifest.render_job(cfg, opts)
    opts = opts or {}
    local base_url, err = resolve(cfg, opts)
    if not base_url then return nil, err end
    opts.base_url = base_url

    local name = "domain-sync-run-" .. slug(cfg.name or cfg.uuid)
    local k8s_ns = opts.k8s_namespace or "default"

    local out = {
        "apiVersion: batch/v1",
        "kind: Job",
        "metadata:",
        "  name: " .. q(name),
        "  namespace: " .. q(k8s_ns),
        "  labels:",
        '    app.kubernetes.io/managed-by: "opsapi"',
        '    opsapi.io/feature: "domain-sync"',
        "spec:",
        "  backoffLimit: 2",
        "  ttlSecondsAfterFinished: 600",
        "  template:",
        "    spec:",
    }
    for _, l in ipairs(pod_spec_lines(cfg, opts, "      ")) do table.insert(out, l) end
    return table.concat(out, "\n") .. "\n", nil
end

return DomainSyncManifest
