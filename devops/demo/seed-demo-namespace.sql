-- Calibrate the `demo` tenant after the first boot of opsapi-demo.
--
-- The namespace row itself is created by scripts/setup-namespace.lua on first
-- boot (setup.namespaceSlug=demo), together with its owner, default roles and
-- menu — do not INSERT it by hand. This only sets what setup leaves default.
--
-- Run:
--   kubectl -n demo exec -i opsapi-demo-db-0 -- psql -U pguser -d opsapi_demo \
--     -v ON_ERROR_STOP=1 < devops/demo/seed-demo-namespace.sql

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM namespaces WHERE slug = 'demo') THEN
        RAISE EXCEPTION 'namespace "demo" not found - has opsapi-demo booted (setup-namespace) yet?';
    END IF;
END $$;

UPDATE namespaces
SET name                     = 'Demo',
    status                   = 'active',
    project_code             = 'core_only',
    -- First entry = primary: password-reset and invite links point here.
    -- Origins only (scheme + host), no paths.
    allowed_redirect_origins = ARRAY[
        'https://dashboard.demo.opsapi.org',
        'https://hello-java.demo.opsapi.org',
        'https://hello-php.demo.opsapi.org'
    ],
    updated_at               = NOW()
WHERE slug = 'demo';

COMMIT;

SELECT id, slug, status, project_code, allowed_redirect_origins
FROM namespaces WHERE slug = 'demo';
