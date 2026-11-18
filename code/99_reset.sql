-- =============================================================================
-- LTG1251  RESET between rehearsals: back to the start of 01_jsonb.sql.
-- No model calls: the AI context comes back from the snapshot 00_setup.sql 0.8 took.
-- Run the whole file. To rebuild everything from scratch, re-run 00_setup.sql instead.
-- =============================================================================
ROLLBACK;   -- closes a demo transaction left open (a warning if there is none)
SET search_path = caldova_ltg, public, ag_catalog;

-- R.1 Remove profile versions added during the session; their context rows cascade
DELETE FROM supplier_profiles WHERE version > 1;

-- R.2 Restore the facts and embeddings captured at setup (the graph keys regenerate)
TRUNCATE profile_context;
INSERT INTO profile_context (supplier_id, version, profile_text, updated_at, metadata, embedding)
SELECT * FROM profile_context_baseline;

-- R.3 Drop what the demos create live
DROP INDEX IF EXISTS profile_facts;          -- 01_jsonb.sql 1.2
DROP TABLE IF EXISTS pg_temp.new_version;    -- 05_all_together.sql 5.3

-- R.4 Remove what 5.4 added to the graph: open finding INS-4471 and its edge
SELECT *
FROM cypher('caldova_ltg_graph', $c$
    MATCH (f:Finding {id: 'INS-4471'})
    DETACH DELETE f
$c$) AS (deleted agtype);

-- R.5 Check. Expect A and B, then F with INS-3172 at Plant 3.
SELECT supplier_id, version, metadata ->> 'plant' AS plant
FROM profile_context
WHERE metadata @> '{"gmp_certified": true, "sterile_fill_finish": true}'
  AND metadata ->> 'open_finding' = ''
ORDER BY supplier_id;

SELECT supplier_id, plant, finding
FROM open_risks;
