-- =============================================================================
-- LTG1251  Demo 3: keyword + vector in one SQL query (slide 19, about 3 min)
-- BM25 full-text and vector results fused with reciprocal rank fusion, then
-- semantic ranking: one ai.search call each. ai.search returns (ctid, match_type,
-- score); join on ctid for the row. Run 00_setup.sql first; run one numbered step
-- at a time.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;

-- 3.1 Keyword search with BM25 (pg_textsearch): exact terms and IDs. Higher score = better.
--     Expect A first: only its profile holds certificate EU-GMP-2291 (D and B match
--     just "EU" and "GMP").
SELECT c.supplier_id,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 3) AS bm25_score
FROM ai.search('EU-GMP-2291', 'profile_context', search_type => 'fulltext', top_k => 3) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY s.score DESC;

--     (optional) The same ID through vector search: the similarities nearly tie, and E,
--     which holds no EU GMP certificate at all, is third. Embeddings blur identifiers.
SELECT c.supplier_id,
       left(c.profile_text, 280) AS excerpt,
       round(s.score::numeric, 4) AS similarity
FROM ai.search('EU-GMP-2291', 'profile_context', search_type => 'vector', top_k => 3) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY s.score DESC;


-- 3.2 The session question, keywords only. Expect B, A, C, G, F: C (a consulting firm)
--     ranks third on the words "GMP" and "fill-finish"; F, first by meaning in Demo 1,
--     is only fifth. Each search finds what the other misses.
SELECT c.supplier_id,
       left(c.profile_text, 80) AS excerpt,
       round(s.score::numeric, 3) AS bm25_score
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', search_type => 'fulltext', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY s.score DESC;


-- 3.3 Fuse with vector search: hybrid is ai.search's default. It runs both searches and
--     fuses the ranked lists with reciprocal rank fusion: positions, not raw scores,
--     1 / (60 + rank) from each list. match_type shows which lists found each row.
--     Expect B, A, F, C, E. B and A rank high in both lists; F is first by meaning but
--     fifth on keywords, so it lands third.
SELECT row_number() OVER (ORDER BY s.score DESC) AS final_rank,
       c.supplier_id, s.match_type, round(s.score::numeric, 4) AS rrf_score
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', top_k => 5) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY final_rank;


-- 3.4 Rerank the top results: rerank => true sends the question and the fused top 5 to
--     the reranking model (default-reranker), whose relevance score replaces the RRF
--     score. Today it keeps B, A, F on top and scores C and E well below them. Optional
--     second stage: it adds a model call, so measure the latency on your own data.
SELECT row_number() OVER (ORDER BY s.score DESC) AS semantic_rank,
       c.supplier_id, round(s.score::numeric, 3) AS relevance
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'profile_context', top_k => 5, rerank => true) AS s
JOIN profile_context AS c ON c.ctid = s.ctid
ORDER BY semantic_rank;