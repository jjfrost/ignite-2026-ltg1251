-- =============================================================================
-- LTG1251  Demo 4: add graph context only when it helps (slide 22, about 2 min)
-- Follow supplier -> plant -> finding with openCypher (Apache AGE), in the same
-- PostgreSQL database. Run 00_setup.sql first; run one numbered step at a time.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;   -- Apache AGE needs ag_catalog on the path

-- 4.1 The graph's ontology, registered once with ai.create_graph (00_setup.sql 0.6). A
--     pipeline loads it from the extracted JSONB facts: ai.graph_sink MERGEs each node
--     on its identity, so loading takes a mapping, not hand-written Cypher. Same
--     database, same transaction log.
SELECT e ->> 'from' AS from_node, e ->> 'label' AS relationship, e ->> 'to' AS to_node
FROM ai.graphs, jsonb_array_elements(ontology -> 'edges') AS e
WHERE name = 'caldova_ltg_graph';

--     What it built. Expect 51 suppliers and 50 plants (C operates none), the GMP
--     certification and one open finding.
SELECT * FROM cypher('caldova_ltg_graph', $c$
    MATCH (n)
    OPTIONAL MATCH (n)-[e]->(m)
    RETURN n, e, m
$c$) AS (node agtype, relationship agtype, target agtype);


-- 4.2 Traverse supplier -> plant <- open finding for Supplier F (hybrid rank 3) and
--     Supplier A. One openCypher query, called from SQL; open the result's graph view.
--     The open finding INS-3172 is observed at F's Plant 3. A's Plant 2 has none.
SELECT *
FROM cypher('caldova_ltg_graph', $c$
    MATCH (s:Supplier)-[o:OPERATES]->(p:Plant)
    WHERE s.id IN ['A', 'F']
    OPTIONAL MATCH (p)-[h:HOLDS]->(c:Certification)
    OPTIONAL MATCH (p)<-[r:OBSERVED_AT]-(f:Finding)
    RETURN s, o, p, h, c, r, f
$c$) AS (supplier agtype, operates agtype, plant agtype, holds agtype,
         certification agtype, observed_at agtype, finding agtype);


-- 4.3 Join the graph to the search results: the session question, checked against the
--     JSONB requirements and the graph in one query. F ranks third on text and meaning,
--     but the open finding at its Plant 3 rules it out. Expect A and B to qualify.
SELECT row_number() OVER (ORDER BY s.score DESC) AS final_rank, c.supplier_id,
       CASE WHEN r.finding IS NOT NULL
                THEN format('excluded: open finding %s at %s', r.finding, r.plant)
            WHEN c.metadata @> '{"sterile_fill_finish": true, "gmp_certified": true}'
                THEN 'qualifies'
            ELSE 'excluded: requirements not met' END AS decision
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
LEFT JOIN open_risks AS r USING (supplier_id)
ORDER BY final_rank;
--     open_risks is a view over one openCypher MATCH (00_setup.sql 0.6). A missing
--     finding edge isn't proof of no risk: the graph is only as complete as its sources.
