-- =============================================================================
-- LTG1251  Demo 2: vector search next to operational data (slide 16, about 3 min)
-- pgvector + DiskANN with filters, transactionally consistent with the business data.
-- ai.search embeds the question and finds the DiskANN index by itself; it returns
-- (ctid, match_type, score), so join on ctid for the row.
-- Run 00_setup.sql first. Run one numbered step at a time, in one editor session.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;

-- 2.1 Search by meaning (DiskANN): the question is embedded in SQL and every profile is
--     ranked by cosine similarity, higher is closer. Expect F, B, A, E, C. F ranks first
--     on "aseptic filling of vials", with no "fill-finish" in its text.
SELECT c.supplier_id,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 4) AS similarity
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', search_type => 'vector', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY s.score DESC;


-- 2.2 Add a business filter: one WHERE clause on the JSONB facts, in the same query.
--     Expect F, B and A: E and C drop out (not GMP certified).
SELECT c.supplier_id,
       c.metadata ->> 'plant' AS plant,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 4) AS similarity
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', search_type => 'vector', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
WHERE c.metadata @> '{"gmp_certified": true}'
ORDER BY s.score DESC;


-- 2.3 Change a row, search again. Run 2.3a-2.3d one at a time.
-- 2.3a Supplier B's GMP certification lapses. Not committed yet.
BEGIN;
UPDATE profile_context
SET metadata = metadata || '{"gmp_certified": false}'
WHERE supplier_id = 'B';

-- 2.3b The same search, inside the transaction: B is gone. No index rebuild, no sync job.
SELECT c.supplier_id,
       c.metadata ->> 'plant' AS plant,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 4) AS similarity
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', search_type => 'vector', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
WHERE c.metadata @> '{"gmp_certified": true}'
ORDER BY s.score DESC;

-- 2.3c Undo it. Keep this ROLLBACK so the later demos start from the same data.
ROLLBACK;

-- 2.3d Search again: B is back
SELECT c.supplier_id,
       c.metadata ->> 'plant' AS plant,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 4) AS similarity
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', search_type => 'vector', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
WHERE c.metadata @> '{"gmp_certified": true}'
ORDER BY s.score DESC;