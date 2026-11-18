-- =============================================================================
-- LTG1251  Do you really need a separate vector database?  SETUP (off camera)
-- Caldova is fictional; all data is synthetic. Same story and data as BRK370
-- (..\demo-brk370\ignite-demo.sql), with its own schema, graph and pipeline so the
-- two never collide:
--   LTG1251: schema caldova_ltg,  graph caldova_ltg_graph, pipeline caldova_ltg_graph_load
--   BRK370:  schema caldova_demo, graph supplier_graph, pipelines supplier_enrichment
--            and supplier_graph_load (never touched here)
-- Run on jfrost-hdb-041, database postgres: the managed models default-chat,
-- default-embedding and default-reranker are registered there, and the ai functions
-- use them by default.
-- Checked on azure_ai 2.5.3 (unified ai namespace build), vector 0.8.7, pg_diskann 0.7.3,
-- pg_textsearch 1.5.1, age 1.8.0 and pg_durable 0.2.7. In this build ai.extract and
-- ai.embed are both direct functions (text => ...) and pipeline steps (input => ...),
-- so call them with named arguments.
--
-- Run 0.1-0.8 in order; re-runnable from 0.2. Step 0.4 calls the models
-- (about 2 minutes). Then run the demos one numbered step at a time:
--   01_jsonb.sql           JSONB: flexible documents, SQL guarantees     slide 11
--   02_vector_search.sql   Demo 1: vector search next to operational data slide 16
--   03_hybrid_search.sql   Demo 2: keyword + vector in one SQL query      slide 19
--   04_graph.sql           Demo 3: add graph context only when it helps   slide 22
--   05_all_together.sql    One transaction, one query, five data models   slide 10
-- Between rehearsals, 99_reset.sql puts everything back without model calls.
-- =============================================================================
SET search_path = caldova_ltg, public, ag_catalog;   -- Apache AGE needs ag_catalog on the path

-- 0.1 Preflight (read-only): the extensions and the managed models
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'age', 'azure_ai', 'pg_durable')
ORDER BY extname;

SELECT alias, model_name
FROM model_registry.model_list_all()
ORDER BY alias;
--     Expect all six extensions and default-chat, default-embedding, default-reranker.
--     A missing extension needs an admin, once per database (pg_textsearch and
--     pg_durable must also be allowlisted and preloaded in the server parameters):
--     CREATE EXTENSION IF NOT EXISTS <name>;


-- 0.2 Start clean (LTG1251 objects only). A graph registration is permanent (there is
--     no ai.drop_graph), so 0.6 keeps caldova_ltg_graph and only empties it.
SELECT ai.drop_pipeline(name)
FROM ai.pipelines
WHERE name = 'caldova_ltg_graph_load';
DROP SCHEMA IF EXISTS caldova_ltg CASCADE;
CREATE SCHEMA caldova_ltg;


-- 0.3 Source: supplier profiles. An update adds a new version; nothing is overwritten.
CREATE TABLE caldova_ltg.supplier_profiles (
    supplier_id  text,
    version      int,
    profile_text text NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (supplier_id, version)
);

--     Derived AI context, kept apart from the source: one row per supplier, from its
--     newest version. Typed columns for keys; JSONB facts and the embedding next to the
--     text. The graph keys are generated from the facts, NULL when a profile has none.
CREATE TABLE caldova_ltg.profile_context (
    supplier_id   text PRIMARY KEY,
    version       int NOT NULL,
    profile_text  text NOT NULL,
    updated_at    timestamptz NOT NULL,
    metadata      jsonb,
    embedding     vector(1536),
    plant         text GENERATED ALWAYS AS (nullif(metadata ->> 'plant', '')) STORED,
    certification text GENERATED ALWAYS AS
                      (CASE WHEN metadata @> '{"gmp_certified": true}' THEN 'GMP' END) STORED,
    open_finding  text GENERATED ALWAYS AS (nullif(metadata ->> 'open_finding', '')) STORED,
    FOREIGN KEY (supplier_id, version)
        REFERENCES caldova_ltg.supplier_profiles ON DELETE CASCADE
);

--     Version 1 of every profile. A-G tell the story; P201-P244 are background
--     packaging suppliers.
INSERT INTO caldova_ltg.supplier_profiles (supplier_id, version, profile_text) VALUES
('A', 1, $p$Supplier A. Contract manufacturer of injectable drug products.
Capability: sterile fill-finish of vials and prefilled syringes.
Plant 2: aseptic processing of injectables on two isolator lines.
Plant 2 holds EU GMP certificate EU-GMP-2291, renewed March 2026.
Inspection history: the January 2026 inspection of Plant 2 closed with no open findings.$p$),
('B', 1, $p$Supplier B. Biologics drug product manufacturer.
Capability: sterile fill-finish of vials and cartridges, with lyophilization.
Plant 1: high-speed aseptic filling line in a grade A cleanroom.
Plant 1 is GMP certified (EU-GMP-1840).
Inspection history: all findings from the August 2026 inspection of Plant 1 are closed.$p$),
('C', 1, $p$Supplier C. Quality consulting and training firm.
Services: mock regulatory inspections, staff training, and GMP audit preparation for fill-finish sites.
Supplier C does not manufacture drug products and operates no plant.$p$),
('D', 1, $p$Supplier D. Biologics contract development and manufacturing organization.
Capability: drug substance manufacturing by cell culture and purification.
Plant 5: single-use bioreactor suites from 200 to 2,000 liters.
Plant 5 holds EU GMP certificate EU-GMP-3307.$p$),
('E', 1, $p$Supplier E. Contract manufacturer of ophthalmic products.
Capability: aseptic blow-fill-seal filling of eye drops in single-dose containers.
Plant 6: blow-fill-seal lines in a controlled cleanroom.
Certification: ISO 13485.$p$),
('F', 1, $p$Supplier F. Manufacturer of sterile injectables.
Capability: aseptic filling of vials and ampoules.
Plant 3: filling on a restricted access barrier system line.
Plant 3 holds GMP certification.
Inspection history: the September 2026 inspection of Plant 3 recorded finding INS-3172, incomplete aseptic process simulation records. Status: open.$p$),
('G', 1, $p$Supplier G. Packaging and labeling services.
Capability: secondary packaging and labeling of vials received from fill-finish manufacturers.
Plant 7: packaging hall with serialization lines.
Certification: ISO 9001.$p$);

INSERT INTO caldova_ltg.supplier_profiles (supplier_id, version, profile_text)
SELECT 'P' || n, 1,
       format('Supplier P%s. Packaging supplier. Capability: secondary packaging, labeling, '
              'warehousing and shipping. Plant: Packaging Site %s. Certification: ISO 9001. '
              'Supplier P%s does not manufacture drug products.', n, n, n)
FROM generate_series(201, 244) AS n;

INSERT INTO caldova_ltg.profile_context (supplier_id, version, profile_text, updated_at)
SELECT supplier_id, version, profile_text, updated_at
FROM caldova_ltg.supplier_profiles;


-- 0.4 AI context (about 2 minutes): ai.extract() returns the facts as JSONB and ai.embed()
--     embeds the text, with the default managed models. The same steps the BRK370 AI
--     pipeline runs, called directly here.
--     Re-runnable: each UPDATE only fills rows that are still missing a value.
UPDATE caldova_ltg.profile_context
SET metadata = ai.extract(text => profile_text, data => ARRAY[
        'plant: string - name of the plant the supplier operates, such as Plant 2; empty string if none',
        'sterile_fill_finish: boolean - true only if the supplier itself offers sterile (aseptic) fill-finish manufacturing of drug products',
        'gmp_certified: boolean - true only if the profile states GMP certification',
        'open_finding: string - ID of an inspection finding whose status is open; empty string if none'])
WHERE metadata IS NULL;

UPDATE caldova_ltg.profile_context
SET embedding = ai.embed(text => profile_text)
WHERE embedding IS NULL;


-- 0.5 Search indexes, built after the load: DiskANN for meaning, BM25 for exact terms.
--     ai.search finds both by itself. The JSONB GIN index (profile_facts) is created
--     live in 01_jsonb.sql.
CREATE INDEX profile_diskann ON caldova_ltg.profile_context
    USING diskann (embedding vector_cosine_ops);
CREATE INDEX profile_bm25 ON caldova_ltg.profile_context
    USING bm25 (profile_text) WITH (text_config = 'english');
ANALYZE caldova_ltg.supplier_profiles, caldova_ltg.profile_context;


-- 0.6 Knowledge graph: suppliers operate plants, plants hold certifications, inspection
--     findings are observed at plants. ai.create_graph registers the ontology and creates
--     the Apache AGE graph and its node labels; loading MERGEs each node on its identity.
--     disp_label is the caption the VS Code graph view shows; edges carry the profile
--     version that asserted them.
SELECT ai.create_graph('caldova_ltg_graph', $o${
    "nodes": [
        {"label": "Supplier",      "identity": "id",   "properties": ["id", "disp_label"]},
        {"label": "Plant",         "identity": "name", "properties": ["name", "disp_label"]},
        {"label": "Certification", "identity": "name", "properties": ["name", "disp_label"]},
        {"label": "Finding",       "identity": "id",   "properties": ["id", "disp_label"]}
    ],
    "edges": [
        {"label": "OPERATES",    "from": "Supplier", "to": "Plant",         "properties": ["version"]},
        {"label": "HOLDS",       "from": "Plant",    "to": "Certification", "properties": ["version"]},
        {"label": "OBSERVED_AT", "from": "Finding",  "to": "Plant",         "properties": ["version"]}
    ]
}$o$)
WHERE NOT EXISTS (SELECT 1 FROM ai.graphs WHERE name = 'caldova_ltg_graph');

SELECT * FROM cypher('caldova_ltg_graph', $c$ MATCH (n) DETACH DELETE n $c$) AS (deleted agtype);

--     ai.create_graph doesn't create the edge labels, and a view compiled before they
--     exist stays empty, so create them now
SELECT create_elabel('caldova_ltg_graph', edge::cstring)
FROM unnest(ARRAY['OPERATES', 'HOLDS', 'OBSERVED_AT']) AS edge
WHERE NOT EXISTS (SELECT 1 FROM ag_label AS l JOIN ag_graph AS g ON g.graphid = l.graph
                  WHERE g.name = 'caldova_ltg_graph' AND l.name = edge);

--     Open findings, read from the graph: supplier -> plant <- open finding.
--     Only open findings are extracted, so every Finding in the graph is open.
CREATE VIEW caldova_ltg.open_risks AS
SELECT supplier::text AS supplier_id, plant::text AS plant, finding::text AS finding
FROM cypher('caldova_ltg_graph', $c$
    MATCH (s:Supplier)-[:OPERATES]->(p:Plant)<-[:OBSERVED_AT]-(f:Finding)
    RETURN s.id, p.disp_label, f.id
$c$) AS (supplier agtype, plant agtype, finding agtype);

--     Load the graph from the facts with a pipeline: plant names normalized
--     (ai.deduplicate), then MERGEd into the graph on each node's identity
--     (ai.graph_sink). The mapping replaces hand-written Cypher.
SELECT ai.create_pipeline(
    name    => 'caldova_ltg_graph_load',
    source  => ai.table_source('profile_context', schema_name => 'caldova_ltg',
                               incremental_column => 'updated_at'),
    steps   => ARRAY[ai.deduplicate('plant')],
    sink    => ai.graph_sink('caldova_ltg_graph', $m${
        "nodes": [
            {"label": "Supplier",      "property": "id",         "from": "supplier_id"},
            {"label": "Supplier",      "property": "disp_label", "from": "supplier_id"},
            {"label": "Plant",         "property": "name",       "from": "plant"},
            {"label": "Plant",         "property": "disp_label", "from": "$.metadata.plant"},
            {"label": "Certification", "property": "name",       "from": "certification"},
            {"label": "Certification", "property": "disp_label", "from": "certification"},
            {"label": "Finding",       "property": "id",         "from": "open_finding"},
            {"label": "Finding",       "property": "disp_label", "from": "open_finding"}
        ],
        "edges": [
            {"edge_label": "OPERATES",    "from_key": "supplier_id",  "to_key": "plant",
             "properties": {"version": "version"}},
            {"edge_label": "HOLDS",       "from_key": "plant",        "to_key": "certification",
             "properties": {"version": "version"}},
            {"edge_label": "OBSERVED_AT", "from_key": "open_finding", "to_key": "plant",
             "properties": {"version": "version"}}
        ]
    }$m$)
);

SELECT ai.run('caldova_ltg_graph_load');

--     pg_durable runs it in the background: repeat until the run shows completed
--     (about a second, 51 rows)
SELECT run_id, status, rows_processed, error
FROM ai.result('caldova_ltg_graph_load');


-- 0.7 Rehearsal gate: stops with an error if the AI extraction drifted from the story.
--     To fix a drifted row: UPDATE caldova_ltg.profile_context SET metadata = NULL
--     WHERE supplier_id = '<id>'; re-run the first UPDATE in 0.4, rebuild the graph
--     with the two statements below, then run 0.7 again.
--       SELECT * FROM cypher('caldova_ltg_graph', $c$ MATCH (n) DETACH DELETE n $c$) AS (deleted agtype);
--       SELECT ai.backfill('caldova_ltg_graph_load');   -- reloads every row
DO $gate$
DECLARE
    qualifying text;
    a_facts jsonb;
    f_facts jsonb;
BEGIN
    SELECT string_agg(supplier_id, ', ' ORDER BY supplier_id) INTO qualifying
    FROM caldova_ltg.profile_context
    WHERE metadata @> '{"gmp_certified": true, "sterile_fill_finish": true}'
      AND metadata ->> 'open_finding' = '';
    SELECT metadata INTO a_facts FROM caldova_ltg.profile_context WHERE supplier_id = 'A';
    SELECT metadata INTO f_facts FROM caldova_ltg.profile_context WHERE supplier_id = 'F';

    IF qualifying IS DISTINCT FROM 'A, B'
       OR NOT coalesce(a_facts @> '{"plant": "Plant 2"}', false)
       OR NOT coalesce(f_facts @> '{"plant": "Plant 3", "gmp_certified": true,
                                    "sterile_fill_finish": true, "open_finding": "INS-3172"}', false) THEN
        RAISE EXCEPTION 'Story check failed. Requirements met by: % (expected A, B). A: %. F: %.',
            coalesce(qualifying, 'nobody'), a_facts, f_facts;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM caldova_ltg.open_risks
                   WHERE supplier_id = 'F' AND plant = 'Plant 3' AND finding = 'INS-3172') THEN
        RAISE EXCEPTION 'The graph shows no open finding at Supplier F''s plant. Repeat the ai.result check in 0.6 until the run shows completed.';
    END IF;
    RAISE NOTICE 'Story check passed: A and B meet the requirements; F has open finding INS-3172 at Plant 3.';
END
$gate$;

--     Today's hybrid ranks for the session question. The ranks on slide 18 are
--     illustrative; say what this shows (F should be in the top 5 for Demo 3).
SELECT row_number() OVER (ORDER BY s.score DESC) AS final_rank, c.supplier_id,
       s.match_type, round(s.score::numeric, 4) AS rrf_score
FROM ai.search('Which suppliers offer GMP-certified sterile fill-finish manufacturing?',
               'caldova_ltg.profile_context', top_k => 5) AS s
JOIN caldova_ltg.profile_context AS c ON c.ctid = s.ctid
ORDER BY final_rank;


-- 0.8 Snapshot the AI context for 99_reset.sql, which resets without calling the models
CREATE TABLE caldova_ltg.profile_context_baseline AS
SELECT supplier_id, version, profile_text, updated_at, metadata, embedding
FROM caldova_ltg.profile_context;
