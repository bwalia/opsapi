-- Foundation: geo extensions (optional) and the same-workspace guard every
-- property_deals table uses for its references.
--
-- References between tables are uuid columns with real foreign keys. A foreign
-- key alone would let workspace A point a row at workspace B's property, so a
-- BEFORE trigger also checks that each referenced row is in the row's own
-- namespace. It runs for every write path (API, jobs, agents), not just routes.
return function(schema, db)
    -- Radius search uses earthdistance (gap map §4). Optional: a database
    -- without it still works, map queries fall back to a bounding box + haversine.
    db.query([[
        DO $$ BEGIN
            CREATE EXTENSION IF NOT EXISTS cube;
            CREATE EXTENSION IF NOT EXISTS earthdistance;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'property_deals: earthdistance unavailable (%), using haversine fallback', SQLERRM;
        END $$
    ]])

    -- TG_ARGV holds pairs: <column>, <referenced table>. kanban_tasks has no
    -- namespace_id (it is resolved through board -> project); users are
    -- checked against namespace membership.
    db.query([[
        CREATE OR REPLACE FUNCTION property_deals_same_namespace() RETURNS trigger AS $fn$
        DECLARE
            row_j jsonb := to_jsonb(NEW);
            ns bigint := (row_j ->> 'namespace_id')::bigint;
            col text;
            tbl text;
            ref text;
            ref_ns bigint;
            i int;
        BEGIN
            FOR i IN 0 .. (TG_NARGS / 2) - 1 LOOP
                col := TG_ARGV[i * 2];
                tbl := TG_ARGV[i * 2 + 1];
                ref := row_j ->> col;
                CONTINUE WHEN ref IS NULL;
                IF TG_OP = 'UPDATE' AND ref IS NOT DISTINCT FROM (to_jsonb(OLD) ->> col) THEN
                    CONTINUE;
                END IF;
                ref_ns := NULL;
                IF tbl = 'kanban_tasks' THEN
                    SELECT p.namespace_id INTO ref_ns
                    FROM kanban_tasks t
                    JOIN kanban_boards b ON b.id = t.board_id
                    JOIN kanban_projects p ON p.id = b.project_id
                    WHERE t.uuid = ref;
                ELSIF tbl = 'users' THEN
                    SELECT m.namespace_id INTO ref_ns
                    FROM users u
                    JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ns
                    WHERE u.uuid = ref;
                ELSIF tbl LIKE 'property\_deals\_%' THEN -- our tables: uuid columns (cast the param, keep the index)
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1::uuid', tbl) INTO ref_ns USING ref;
                ELSE                                     -- core tables: text/varchar uuid columns
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1', tbl) INTO ref_ns USING ref;
                END IF;
                IF ref_ns IS DISTINCT FROM ns THEN
                    -- Worded so helper.plugin-sdk maps it to 422 "A referenced record does not exist".
                    RAISE EXCEPTION 'insert or update on "%" violates foreign key constraint "property_deals_same_namespace" (%)',
                        TG_TABLE_NAME, col USING ERRCODE = 'foreign_key_violation';
                END IF;
            END LOOP;
            RETURN NEW;
        END
        $fn$ LANGUAGE plpgsql
    ]])
end
