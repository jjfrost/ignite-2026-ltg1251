-- =============================================================================
-- LTG1251  Demo 5: It all comes together: one query, one transaction, five data
-- models. Run after 04_graph.sql, one numbered step at a time.
-- 5.4 commits a new profile version: run 99_reset.sql before running this file again.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;

-- 5.1 One query, one snapshot: vector + full-text (ai.search), the JSONB facts,
--     the graph (open_risks) and a relational join. Expect B and A.
SELECT c.supplier_id, round(s.score::numeric, 4) AS rrf_score
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
LEFT JOIN open_risks AS r USING (supplier_id)
WHERE c.metadata @> '{"gmp_certified": true, "sterile_fill_finish": true}'
  AND r.finding IS NULL
ORDER BY s.score DESC;