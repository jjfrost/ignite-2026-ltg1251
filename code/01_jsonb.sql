-- =============================================================================
-- LTG1251  JSONB: flexible documents, SQL guarantees (slide 11, about 2 min)
-- Run 00_setup.sql first. Run one numbered step at a time, in one editor session.
-- Same question all session: which suppliers offer GMP-certified sterile fill-finish
-- manufacturing? JSONB holds the facts AI extracted from each supplier's profile.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;

-- 1.0 Query our tables to show the basic outline of the data structure
select * from caldova_ltg.supplier_profiles;
select * from caldova_ltg.profile_context;

-- 1.1 Where AI output lands: ai.extract() reads a profile and returns JSONB facts.
--     One model call (default-chat), in SQL; the same call 00_setup.sql made for every
--     supplier.
SELECT supplier_id,
       ai.extract(text => profile_text, data => ARRAY[
           'plant: string - name of the plant the supplier operates, such as Plant 2; empty string if none',
           'sterile_fill_finish: boolean - true only if the supplier itself offers sterile (aseptic) fill-finish manufacturing of drug products',
           'gmp_certified: boolean - true only if the profile states GMP certification',
           'open_finding: string - ID of an inspection finding whose status is open; empty string if none']) AS extracted_facts
FROM supplier_profiles
WHERE supplier_id = 'A';

--     Stored next to the typed columns: keys stay relational, the facts are a document
SELECT supplier_id, version, metadata AS facts
FROM profile_context
WHERE supplier_id IN ('A', 'B', 'C', 'D', 'E', 'F', 'G')
ORDER BY supplier_id;


-- 1.2 Index the documents. GIN with jsonb_path_ops serves containment (@>) and JSONPath.
CREATE INDEX IF NOT EXISTS profile_facts ON profile_context
    USING gin (metadata jsonb_path_ops);


-- 1.3 Containment: GMP-certified sterile fill-finish, with no open finding.
--     Expect 2 rows: A (Plant 2) and B (Plant 1). F meets both requirements but
--     carries open finding INS-3172; the others miss a requirement.
SELECT supplier_id, metadata ->> 'plant' AS plant
FROM profile_context
WHERE metadata @> '{"gmp_certified": true,
                    "sterile_fill_finish": true}'
  AND metadata ->> 'open_finding' = '';


-- 1.4 JSONPath, joined with relational rows: which suppliers carry an open finding,
--     and which profile version said so? Expect F, INS-3172, version 1.
SELECT c.supplier_id, c.metadata ->> 'open_finding' AS open_finding,
       p.version, p.updated_at
FROM profile_context AS c
JOIN supplier_profiles AS p USING (supplier_id, version)
WHERE c.metadata @@ '$.open_finding != ""';