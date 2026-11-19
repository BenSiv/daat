-- The document/notebook entity type: facade over document/{text,schema_pool,
-- links,markdown,embeddings,passage,aspect,reference} plus entity lifecycle
-- hooks, hybrid lexical/semantic search & snippet extraction, and the
-- `daat document` CLI entry point.

const agent_provider_lib = require("agent_provider")
const aspect_lib = require("document.aspect")
const config = require("config")
const db = require("database")
const doc_embeddings = require("document.embeddings")
const doc_links = require("document.links")
const doc_markdown = require("document.markdown")
const doc_pool = require("document.schema_pool")
const document_text = require("document.text")
const entity = require("entity")
const json = require("dkjson")
const reference = require("document.reference")
const tag = require("tag")
const vector_lib = require("vector")

const document = {}

document.TAG_SCHEMA = tag.TAG_SCHEMA
document.DOCUMENT_TAG_SCHEMA = tag.DOCUMENT_TAG_SCHEMA
document.TAG_RELATION_SCHEMA = tag.TAG_RELATION_SCHEMA
document.TAG_EVIDENCE_SCHEMA = tag.TAG_EVIDENCE_SCHEMA

document.hex_literal = vector_lib.hex_literal
document.pack_vector = vector_lib.pack
document.unpack_vector = vector_lib.unpack

document.CONNECTION_TITLE_SEPARATOR = document_text.CONNECTION_TITLE_SEPARATOR
document.is_connection_title = document_text.is_connection_title
document.connection_title_count = document_text.connection_title_count
document.transcript_conversation = document_text.transcript_conversation
document.embedding_text = document_text.embedding_text

document.link_hash = doc_pool.link_hash
document.link_sync_hash = doc_pool.link_sync_hash
document.ensure_document_pool_columns = doc_pool.ensure_document_pool_columns
document.link_sql_columns_text = doc_pool.link_sql_columns_text
document.knowledge_pool_sql_columns_text = doc_pool.knowledge_pool_sql_columns_text
document.embedding_sql_columns_text = doc_pool.embedding_sql_columns_text
document.ensure_pool_state = doc_pool.ensure_pool_state
document.resync_pool_count = doc_pool.resync_pool_count
document.register_pool_document = doc_pool.register_pool_document
document.init_schema = doc_pool.init_schema
document.ensure_knowledge_pool_folder = doc_pool.ensure_knowledge_pool_folder
document.create_page = doc_pool.create_page
document.update_page = doc_pool.update_page
document.children = doc_pool.children
document.all_active = doc_pool.all_active
document.breadcrumbs = doc_pool.breadcrumbs
document.would_create_cycle = doc_pool.would_create_cycle
document.tier_weight = doc_pool.tier_weight
document.content_hash = doc_pool.content_hash
document.content_hash_matches = doc_pool.content_hash_matches
document.reinforcement_delta = doc_pool.reinforcement_delta
document.base_heat = doc_pool.base_heat
document.pool_effective_heat = doc_pool.pool_effective_heat
document.reinforce_pool_heat = doc_pool.reinforce_pool_heat
document.return_pool_heat = doc_pool.return_pool_heat
document.promotion_target_tier = doc_pool.promotion_target_tier
document.word_count = doc_pool.word_count
document.content_shape = doc_pool.content_shape
document.was_revised = doc_pool.was_revised
document.connectivity_status = doc_pool.connectivity_status
document.title_is_generic = doc_pool.title_is_generic
document.guess_title_from_body = doc_pool.guess_title_from_body

document.parse_link_ref = doc_links.parse_link_ref
document.resolve_link = doc_links.resolve_link
document.resolve_link_text = doc_links.resolve_link_text
document.link_ref = doc_links.link_ref
document.search_for_link = doc_links.search_for_link
document.clip_text = doc_links.clip_text
document.clean_link_context = doc_links.clean_link_context
document.link_context = doc_links.link_context
document.extract_links = doc_links.extract_links
document.upsert_link = doc_links.upsert_link
document.sync_links = doc_links.sync_links
document.linked_neighbors = doc_links.linked_neighbors
document.graph_edges = doc_links.graph_edges
document.weighted_spreading_delta = doc_links.weighted_spreading_delta
document.links = doc_links.links
document.connection_draft = doc_links.connection_draft
document.resolve_dangling_links = doc_links.resolve_dangling_links
document.resync_links = doc_links.resync_links
document.resync_all_links = doc_links.resync_all_links

document.inline_links_to_markdown = doc_markdown.inline_links_to_markdown
document.html_unescape = doc_markdown.html_unescape
document.gnuplot_safe_string = doc_markdown.gnuplot_safe_string
document.plot_spec_to_gnuplot_cfg = doc_markdown.plot_spec_to_gnuplot_cfg
document.render_plot = doc_markdown.render_plot
document.render_plot_fences = doc_markdown.render_plot_fences
document.render_markdown = doc_markdown.render_markdown
document.render_html = doc_markdown.render_html
document.extract_attachment_text = doc_markdown.extract_attachment_text

document.reindex_embedding = doc_embeddings.reindex_embedding
document.refresh_embedding = doc_embeddings.refresh_embedding
document.queue_embedding = doc_embeddings.queue_embedding
document.embed_pending = doc_embeddings.embed_pending
document.repack_all_embeddings = doc_embeddings.repack_all_embeddings
document.reindex_all_embeddings = doc_embeddings.reindex_all_embeddings

const BASE_HEAT = doc_pool.base_heat()

-- Also where every new document's links and embedding get computed --
-- not document.create_page, so the generic entity paths get them too
-- instead of leaving the document invisible to backlinks/semantic search
-- until a `daat repair`. Embedding stays best-effort: a failed provider
-- call never fails the create.
--
-- A new document can also be the target a dangling [[link]] elsewhere
-- has been waiting for (document.resolve_dangling_links).
function document.on_entity_created(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_created(db_path, entity_id)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.register_pool_document(db_path, entity_id)
    doc = entity.get(db_path, "document", entity_id)
    if doc != nil then
        document.sync_links(db_path, entity_id, doc.content)
        reference.sync_document(db_path, entity_id, doc.title, doc.content)
        tag.sync_text_tags(db_path, entity_id, doc.content, doc.created_by)
    end
    document.resolve_dangling_links(db_path)
    document.queue_embedding(db_path, entity_id)
end


-- entity.update's counterpart: re-syncs links on a content change,
-- re-embeds on a content or title change, and retries dangling links on
-- a rename or move (a new title, or a new parent for "subject/title",
-- can be what one was waiting for). `field_changes` is keyed by field
-- name.
function document.on_entity_updated(db_path, entity_type, entity_id, field_changes)
    if entity_type == "document_tag" then
        tag.on_membership_updated(db_path, entity_id, field_changes)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    if field_changes.content != nil or field_changes.title != nil then
        doc = entity.get(db_path, "document", entity_id)
        if doc != nil then
            reference.sync_document(db_path, entity_id, doc.title, doc.content)
        end
    end
    if field_changes.content != nil then
        doc = entity.get(db_path, "document", entity_id)
        if doc != nil then
            document.sync_links(db_path, entity_id, doc.content)
            tag.sync_text_tags(db_path, entity_id, doc.content, doc.updated_by, field_changes.content.old)
        end
    end
    if field_changes.title != nil or field_changes.parent_id != nil then
        document.resolve_dangling_links(db_path)
    end
    if field_changes.content != nil or field_changes.title != nil then
        document.queue_embedding(db_path, entity_id)
    end
end

function document.on_entity_archived(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_archived(db_path, entity_id, true)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.return_pool_heat(db_path, entity_id)
    -- Before drop_derived: it reads the vector it takes out of the centres.
    tag.on_document_archived(db_path, entity_id, true)
    document.drop_derived(db_path, entity_id)
end

function document.on_entity_unarchived(db_path, entity_type, entity_id)
    if entity_type == "document_tag" then
        tag.on_membership_archived(db_path, entity_id, false)
        return
    end
    if entity_type != "document" then
        reference.index_entity(db_path, entity_type, entity_id)
        return
    end
    document.register_pool_document(db_path, entity_id)
    doc = entity.get(db_path, "document", entity_id)
    if doc != nil then
        document.sync_links(db_path, entity_id, doc.content)
        reference.sync_document(db_path, entity_id, doc.title, doc.content)
    end
    document.resolve_dangling_links(db_path)
    -- Its vector went with the archive (drop_derived); re-embedding puts
    -- it back into its tags' centres (document.refresh_embedding). One
    -- archived before drop_derived existed still has its row, though
    -- its vector already left the centres -- cleared so the refresh
    -- doesn't take it out a second time.
    db.exec(db_path, string.format("DELETE FROM document_embedding WHERE document_id = %d;", tonumber(entity_id)))
    document.queue_embedding(db_path, entity_id)
end

-- What an archived document leaves behind: rows derived from it, all
-- rebuilt on unarchive (document.on_entity_unarchived). Its outgoing
-- links are archived rather than deleted, so their raw_strength comes
-- back with them.
function document.drop_derived(db_path, document_id)
    document_id = tonumber(document_id)
    db.exec(db_path, string.format("DELETE FROM document_embedding WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_embedding_due WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_aspect WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_mention WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format("DELETE FROM document_link_sync WHERE document_id = %d;", document_id))
    db.exec(db_path, string.format(
        "UPDATE document_link SET archived_at = %s WHERE from_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        db.now_expr(db_path), document_id))
end


-- Function words dropped from a search query before lexical scoring.
-- Found live: the agent writes queries like "passage OR subculture OR
-- degradation" -- every "or" then matched as a substring of nearly every
-- document ("for", "work", "procedure"), thousands of times in a long
-- PDF, and buried the real hits under whichever documents were longest.
const SEARCH_STOPWORDS = document_text.SEARCH_STOPWORDS
document.search_stopwords = SEARCH_STOPWORDS
const SEARCH_MAX_TERMS = document_text.SEARCH_MAX_TERMS
document.query_terms = document_text.query_terms

-- A LIKE pattern matching `term` anywhere, with LIKE's own wildcards
-- escaped -- paired with ESCAPE '!' at the call site, which both
-- backends accept (MySQL's default escape is a backslash, SQLite has
-- none, so neither default works for both).
function like_anywhere(term)
    escaped = string.gsub(term, "([!%%_])", "!%1")
    return db.quote("%" .. escaped .. "%")
end

-- SQL expression for how many times `term` (already lowercase) occurs
-- in `column`: the length lost by deleting every occurrence, divided by
-- the term's own length. Plain LENGTH/LOWER/REPLACE, so it means the
-- same on SQLite and MySQL (byte vs. character LENGTH doesn't matter --
-- all three LENGTHs use the same unit).
function occurrence_count_sql(column, term)
    lowered = "LOWER(COALESCE(" .. column .. ", ''))"
    quoted = db.quote(term)
    return string.format("((LENGTH(%s) - LENGTH(REPLACE(%s, %s, ''))) / LENGTH(%s))", lowered, lowered, quoted, quoted)
end

-- A document is searchable unless archived or folded into a canonical
-- duplicate (it would compete with its own canonical for the same
-- slot). Never by kind: a chat transcript, a distilled note and a
-- synced file are all knowledge on the same level, ranked by relevance
-- and usage (heat, tier) alone.
const SEARCHABLE_DOCUMENT_WHERE = """
(d.archived_at IS NULL OR d.archived_at = '')
AND d.merged_into IS NULL
"""

const SEARCH_RESULT_COLUMNS = """
d.id, d.title, d.tier, d.retrieval_count, d.raw_heat, d.log_scale_at_write,
d.source_type, d.source_id, d.content_hash, d.created_at, d.external_id
"""

-- How many candidates each ranking (lexical, semantic) contributes to
-- the fused list -- well past any `limit` a caller asks for, so fusion
-- has real overlap to work with.
const SEARCH_CANDIDATES_PER_RANKING = 50
-- Reciprocal-rank-fusion constant (the standard 60): flattens the gap
-- between neighbouring ranks so neither ranking's #1 dominates alone.
const SEARCH_RRF_K = 60
-- Cosine similarity at or below which an embedding match is not a
-- match at all -- an irrelevant document at the bottom of a results
-- list is still a wrong result.
const SEARCH_SIMILARITY_FLOOR = 0.45
-- BM25's usual constants: term-frequency saturation and how strongly a
-- long document's counts are discounted for its length.
const BM25_K1 = 1.2
const BM25_B = 0.75
-- A query term in the title counts as this many content-weight hits'
-- worth of evidence, on top of the content score.
const SEARCH_TITLE_WEIGHT = 2.0

-- How many documents get exact per-term counts (stage 2 below) after
-- the cheap presence pass narrows the field.
const SEARCH_COUNTED_CANDIDATES = 200

-- Lexical ranking, computed in SQL in two stages, and never by reading
-- content into Lua. Found live: the previous version selected every
-- active document's full content and embedding (~290 MB in production)
-- into Lua on every call and counted substrings there, taking 30-120 s
-- per search; that, not the model, was most of what users saw as the
-- agent "sleeping".
--
-- Stage 1 asks only *whether* each term occurs (LIKE, which both
-- backends evaluate case-insensitively and which stops at the first
-- match) and ranks by the rarity-weighted share of terms present.
-- Stage 2 counts occurrences (LOWER + REPLACE over the whole text --
-- the expensive part, so only for the top SEARCH_COUNTED_CANDIDATES)
-- and ranks those by BM25 over content (saturating term frequency,
-- document length normalisation, rarer terms weighted higher) plus a
-- title bonus, so a 500-page PDF that mentions a common word 2,000
-- times no longer outranks a short note about exactly the thing asked
-- for.
function lexical_ranking(db_path, terms, query_text)
    if #terms == 0 then
        return {}
    end
    presence_columns = {}
    matches_any = {}
    for i, term in ipairs(terms) do
        content_like = "d.content LIKE " .. like_anywhere(term) .. " ESCAPE '!'"
        title_like = "d.title LIKE " .. like_anywhere(term) .. " ESCAPE '!'"
        table.insert(presence_columns, string.format("CASE WHEN %s THEN 1 ELSE 0 END AS p%d", content_like, i))
        table.insert(matches_any, title_like)
        table.insert(matches_any, content_like)
    end
    candidates = db.query(db_path, string.format("""
        SELECT %s, %s
        FROM document d
        WHERE %s AND (%s);
    """, SEARCH_RESULT_COLUMNS, table.concat(presence_columns, ", "), SEARCHABLE_DOCUMENT_WHERE, table.concat(matches_any, " OR ")))
    if candidates == nil or #candidates == 0 then
        return {}
    end

    total_rows = db.query(db_path, "SELECT COUNT(*) AS n FROM document d WHERE " .. SEARCHABLE_DOCUMENT_WHERE .. ";")
    total = tonumber(total_rows[1].n)
    document_frequency = {}
    for i = 1, #terms do
        document_frequency[i] = 0
    end
    for _, row in ipairs(candidates) do
        row.title_lower = ""
        if row.title != nil then
            row.title_lower = string.lower(row.title)
        end
        row.in_title = {}
        for i, term in ipairs(terms) do
            row.in_title[i] = string.find(row.title_lower, term, 1, true) != nil
            if tonumber(row["p" .. tostring(i)]) == 1 or row.in_title[i] == true then
                document_frequency[i] = document_frequency[i] + 1
            end
        end
    end
    idf = {}
    for i = 1, #terms do
        idf[i] = math.log(1 + (total - document_frequency[i] + 0.5) / (document_frequency[i] + 0.5))
    end
    lower_query = ""
    if query_text != nil then
        lower_query = string.lower(query_text)
    end

    -- Stage 1: presence only.
    for _, row in ipairs(candidates) do
        presence = 0
        for i = 1, #terms do
            if tonumber(row["p" .. tostring(i)]) == 1 then
                presence = presence + idf[i]
            end
            if row.in_title[i] == true then
                presence = presence + idf[i] * SEARCH_TITLE_WEIGHT
            end
        end
        row.lexical_score = presence
    end
    table.sort(candidates, function(a, b) return a.lexical_score > b.lexical_score end)
    counted = {}
    for i = 1, math.min(#candidates, SEARCH_COUNTED_CANDIDATES) do
        table.insert(counted, candidates[i])
    end

    -- Stage 2: occurrence counts for the survivors.
    count_columns = {}
    for i, term in ipairs(terms) do
        table.insert(count_columns, occurrence_count_sql("d.content", term) .. " AS c" .. tostring(i))
    end
    ids = {}
    by_id = {}
    for _, row in ipairs(counted) do
        table.insert(ids, tostring(tonumber(row.id)))
        by_id[tonumber(row.id)] = row
    end
    count_rows = db.query(db_path, string.format("SELECT d.id, LENGTH(COALESCE(d.content, '')) AS content_length, %s FROM document d WHERE d.id IN (%s);",
        table.concat(count_columns, ", "), table.concat(ids, ", ")))
    length_sum = 0
    if count_rows != nil then
        for _, count_row in ipairs(count_rows) do
            row = by_id[tonumber(count_row.id)]
            row.content_length = tonumber(count_row.content_length)
            for i = 1, #terms do
                row["c" .. tostring(i)] = tonumber(count_row["c" .. tostring(i)])
            end
        end
    end
    for _, row in ipairs(counted) do
        if row.content_length == nil then
            row.content_length = 0
        end
        length_sum = length_sum + row.content_length
    end
    -- Average over the counted candidates rather than the whole pool:
    -- one less full-table pass, and only the ratio between documents
    -- matters.
    average_length = math.max(length_sum / #counted, 1)

    for _, row in ipairs(counted) do
        score = 0
        length_norm = BM25_K1 * (1 - BM25_B + BM25_B * row.content_length / average_length)
        for i = 1, #terms do
            count = row["c" .. tostring(i)]
            if count != nil and count > 0 then
                score = score + idf[i] * (count * (BM25_K1 + 1)) / (count + length_norm)
            end
            if row.in_title[i] == true then
                score = score + idf[i] * SEARCH_TITLE_WEIGHT
            end
        end
        -- The whole multi-word query appearing verbatim in the title is
        -- the strongest single signal a lexical match can give.
        if #terms > 1 and lower_query != "" and string.find(row.title_lower, lower_query, 1, true) != nil then
            score = score * 1.5
        end
        row.lexical_score = score
    end
    table.sort(counted, function(a, b) return a.lexical_score > b.lexical_score end)
    return counted
end

-- Embedding vectors are stored twice: vector_json (the record of what
-- the provider returned, read by tag.lua and visible to entity.query)
-- and vector_packed, the same vector L2-normalised and packed as
-- little-endian float32 -- what search actually reads. ~4x smaller on
-- the wire than the JSON, decoded by one string.unpack instead of a JSON
-- parse (JSON decoding alone was ~9 s per search over ~8,000 documents),
-- and pre-normalised so similarity is a plain dot product.
document.pack_vector = vector_lib.pack
document.unpack_vector = vector_lib.unpack
const dot_product = vector_lib.dot

-- Semantic ranking: every searchable document's embedding against the
-- query's, keeping those above the similarity floor. Reads only
-- vector_packed; a row not yet packed (saved before the column existed,
-- until `daat repair embeddings-packed` runs) falls back to its JSON.
-- With search_aspects, a document's similarity is the best of its own
-- vector and its aspects (src/aspect.lua), and an entry found through
-- an aspect says which one and where its passage starts.
function semantic_ranking(db_path, query_vector, model)
    query_packed = document.pack_vector(query_vector)
    if query_packed == nil then
        return {}
    end
    query_unit = document.unpack_vector(query_packed)
    rows = db.query(db_path, string.format("""
        SELECT e.document_id, e.vector_packed,
               CASE WHEN e.vector_packed IS NULL THEN e.vector_json END AS vector_json
        FROM document_embedding e
        JOIN document d ON d.id = e.document_id
        WHERE e.model = %s AND %s;
    """, db.quote(model), SEARCHABLE_DOCUMENT_WHERE))
    if rows == nil then
        return {}
    end
    best = {}
    for _, row in ipairs(rows) do
        unit = document.unpack_vector(row.vector_packed)
        if unit == nil and row.vector_json != nil then
            decoded, _, _ = json.decode(row.vector_json)
            unit = document.unpack_vector(document.pack_vector(decoded))
        end
        id = tonumber(row.document_id)
        best[id] = {id = id, similarity = dot_product(query_unit, unit)}
    end
    if config.load().search_aspects == true then
        for id, match in pairs(aspect_lib.best_matches(db_path, query_unit, model, SEARCHABLE_DOCUMENT_WHERE)) do
            if best[id] == nil or match.similarity > best[id].similarity then
                best[id] = {id = id, similarity = match.similarity, aspect = match.aspect, aspect_offset = match.passage_offset}
            end
        end
    end
    ranked = {}
    for _, entry in pairs(best) do
        if entry.similarity > SEARCH_SIMILARITY_FLOOR then
            table.insert(ranked, entry)
        end
    end
    -- Ties by id, so the order never depends on table traversal.
    table.sort(ranked, function(a, b)
        if a.similarity != b.similarity then
            return a.similarity > b.similarity
        end
        return a.id < b.id
    end)
    return ranked
end

-- Searches active documents by lexical and embedding relevance, fused by
-- reciprocal rank (a document near the top of both rankings beats one
-- at the top of only one; no score-scale tuning between the two), with
-- tier/heat reinforcement applied last as a bounded multiplier.
--
-- Found live: reinforcement used to be *added* -- tier_weight * 10 plus
-- effective heat, which reaches ~12 for the most-retrieved documents
-- against a relevance score of a few points -- so the same handful of
-- "hot" documents (a computational-neuroscience proceedings, a maths
-- software proceedings) came back for almost any query, which retrieved
-- them again and made them hotter. As a multiplier capped at +50%,
-- reinforcement still breaks near-ties between relevant documents but
-- can't carry an irrelevant one.
--
-- `use_semantic` (default true) computes the *query's* own embedding
-- fresh each call (one cheap API call); a document only contributes a
-- semantic match if it was already indexed (document.reindex_embedding).
-- Returns at most `limit` rows, each with its full content (for the
-- caller's excerpt and knowledge.lua's content_hash) and `score`.
function document.search(db_path, query_text, limit, use_semantic)
    if limit == nil then
        limit = 20
    end
    if use_semantic == nil then
        use_semantic = true
    end

    terms = document.query_terms(query_text)
    lexical = lexical_ranking(db_path, terms, query_text)

    semantic = {}
    -- Also returned, so passage scoring (src/passage.lua) can reuse the
    -- query's embedding instead of asking for it again.
    query_vector = nil
    query_model = nil
    if use_semantic == true and query_text != nil and query_text != "" then
        model = agent_provider_lib.embedding_model()
        if model != nil then
            query_model = model
            query_vector, _ = agent_provider_lib.embeddings(model, query_text)
            if query_vector != nil then
                semantic = semantic_ranking(db_path, query_vector, model)
            end
        end
    end

    fused = {}
    by_id = {}
    rankings = {}
    for rank = 1, math.min(#lexical, SEARCH_CANDIDATES_PER_RANKING) do
        table.insert(rankings, {id = tonumber(lexical[rank].id), rank = rank, row = lexical[rank]})
    end
    -- Which aspect found a document, when one did (search_aspects).
    found_by_aspect = {}
    for rank = 1, math.min(#semantic, SEARCH_CANDIDATES_PER_RANKING) do
        table.insert(rankings, {id = semantic[rank].id, rank = rank})
        if semantic[rank].aspect != nil then
            found_by_aspect[semantic[rank].id] = semantic[rank]
        end
    end
    for _, ranked in ipairs(rankings) do
        entry = by_id[ranked.id]
        if entry == nil then
            entry = {id = ranked.id, fused = 0.0}
            by_id[ranked.id] = entry
            table.insert(fused, entry)
        end
        entry.fused = entry.fused + 1.0 / (SEARCH_RRF_K + ranked.rank)
        if ranked.row != nil then
            entry.row = ranked.row
        end
    end
    if #fused == 0 then
        return {}
    end

    -- Semantic-only candidates still need their metadata row.
    missing = {}
    for _, entry in ipairs(fused) do
        if entry.row == nil then
            table.insert(missing, tostring(entry.id))
        end
    end
    if #missing > 0 then
        meta_rows = db.query(db_path, string.format("SELECT %s FROM document d WHERE d.id IN (%s);",
            SEARCH_RESULT_COLUMNS, table.concat(missing, ", ")))
        if meta_rows != nil then
            for _, row in ipairs(meta_rows) do
                entry = by_id[tonumber(row.id)]
                if entry != nil then
                    entry.row = row
                end
            end
        end
    end

    -- One shared log_pool_scale read, reused for every row's effective_heat.
    document.ensure_pool_state(db_path)
    pool_state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = 0.0
    if pool_state_rows != nil and pool_state_rows[1] != nil then
        log_pool_scale = tonumber(pool_state_rows[1].log_pool_scale)
    end

    scored = {}
    for _, entry in ipairs(fused) do
        row = entry.row
        if row != nil then
            effective_heat = document.pool_effective_heat(row.raw_heat, row.log_scale_at_write, log_pool_scale)
            heat_boost = 0.1 * math.log(math.max(effective_heat, 0.01) / BASE_HEAT)
            heat_boost = math.max(-0.1, math.min(heat_boost, 0.15))
            reinforcement = 1.0 + document.tier_weight(row.tier) + heat_boost
            table.insert(scored, {
                id = row.id, title = row.title, score = entry.fused * reinforcement,
                tier = row.tier, retrieval_count = row.retrieval_count,
                source_type = row.source_type,
                source_id = row.source_id, content_hash = row.content_hash,
                created_at = row.created_at, external_id = row.external_id,
            })
            by_aspect = found_by_aspect[tonumber(row.id)]
            if by_aspect != nil then
                scored[#scored].aspect = by_aspect.aspect
                scored[#scored].aspect_offset = by_aspect.aspect_offset
            end
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)

    results = {}
    for i = 1, math.min(limit, #scored) do
        table.insert(results, scored[i])
    end
    if #results == 0 then
        return results, query_vector, query_model
    end

    -- Content only for what's actually returned.
    ids = {}
    for _, r in ipairs(results) do
        table.insert(ids, tostring(tonumber(r.id)))
    end
    content_rows = db.query(db_path, string.format("SELECT id, content FROM document WHERE id IN (%s);", table.concat(ids, ", ")))
    content_by_id = {}
    if content_rows != nil then
        for _, row in ipairs(content_rows) do
            content_by_id[tonumber(row.id)] = row.content
        end
    end
    for _, r in ipairs(results) do
        r.content = content_by_id[tonumber(r.id)]
    end
    return results, query_vector, query_model
end

-- Where a document's own text starts: past a leading metadata preamble
-- (synced files open with quoted lines -- source path, author, "synced
-- daily" -- closed by a "---" rule), else 1. Only a preamble closed by
-- a rule counts, so a document that merely opens with a quote keeps it.
-- Shared by search excerpts and passage splitting (src/passage.lua).
document.preamble_end = document_text.preamble_end

-- The passage of `content` most worth showing for a search: the window
-- of `max_length` characters holding the most distinct query terms
-- (then the most hits), widened back to a line or word start. Found
-- live: excerpts used to be the first N characters, which for synced
-- files is a metadata preamble (source path, author, "synced daily"
-- notice) and a cover page -- the model saw the same boilerplate for
-- every hit and searched again. With no term in the content (a
-- semantic-only match), a leading blockquote preamble closed by a
-- horizontal rule is skipped instead.
function document.search_snippet(content, query_text, max_length)
    if content == nil or content == "" then
        return ""
    end
    lower = string.lower(content)
    snippet_terms = document.query_terms(query_text)
    hits = {}
    for i, term in ipairs(snippet_terms) do
        position = 1
        while #hits < 2000 do
            found = string.find(lower, term, position, true)
            if found == nil then
                break
            end
            table.insert(hits, {at = found, term = i})
            position = found + string.len(term)
        end
    end
    start = 1
    if #hits > 0 then
        table.sort(hits, function(a, b) return a.at < b.at end)
        best_distinct = 0
        best_count = 0
        left = 1
        in_window = {}
        for i = 1, #snippet_terms do
            in_window[i] = 0
        end
        distinct = 0
        for right = 1, #hits do
            in_window[hits[right].term] = in_window[hits[right].term] + 1
            if in_window[hits[right].term] == 1 then
                distinct = distinct + 1
            end
            while hits[right].at - hits[left].at > max_length / 2 do
                in_window[hits[left].term] = in_window[hits[left].term] - 1
                if in_window[hits[left].term] == 0 then
                    distinct = distinct - 1
                end
                left = left + 1
            end
            count = right - left + 1
            if distinct > best_distinct or (distinct == best_distinct and count > best_count) then
                best_distinct = distinct
                best_count = count
                start = hits[left].at
            end
        end
        -- A little lead-in, from the start of that line if it's close.
        lead_start = math.max(1, start - 150)
        line_start = nil
        search_from = lead_start
        while true do
            newline = string.find(content, "\n", search_from, true)
            if newline == nil or newline >= start then
                break
            end
            line_start = newline + 1
            search_from = newline + 1
        end
        if line_start != nil then
            start = line_start
        else
            start = lead_start
        end
    else
        start = document.preamble_end(content)
    end
    while start > 1 and string.find(string.sub(content, start - 1, start - 1), "%w") != nil do
        start = start - 1
    end
    body = string.sub(content, start)
    prefix = ""
    if start > 1 then
        prefix = "..."
    end
    if string.len(body) <= max_length then
        return prefix .. body
    end
    truncated = string.sub(body, 1, max_length)
    trimmed = string.match(truncated, "^(.*)%s%S*$")
    if trimmed != nil and string.len(trimmed) > max_length - 40 then
        truncated = trimmed
    end
    return prefix .. truncated .. "..."
end

-- CLI entry point: `daat document create-json`. The link/embedding/
-- pool-count backfills that used to live here are `daat repair` now
-- (src/repair.lua).
-- `daat repair knowledge`: rows derived from documents (or tags) that
-- are no longer active -- leftovers from before document.drop_derived
-- ran on archive, or from a raw SQL write. Only rows rebuilt from active
-- documents anyway: never the knowledge_* history, memberships or the
-- ledger. Embeddings from another model than the current one are only
-- counted: deleting them would just leave search without vectors until
-- `daat repair embeddings` re-embeds. -> {{label, action, count}, ...}
const ACTIVE_DOCUMENT_IDS = "SELECT id FROM document WHERE archived_at IS NULL OR archived_at = ''"
const ACTIVE_TAG_IDS = "SELECT id FROM tag WHERE archived_at IS NULL OR archived_at = ''"

function document.prune_derived(db_path, dry_run)
    checks = {
        {label = "embeddings of archived or missing documents", action = "deleted",
         tbl = "document_embedding", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "queued embeddings of archived or missing documents", action = "deleted",
         tbl = "document_embedding_due", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "aspects of archived or missing documents", action = "deleted",
         tbl = "document_aspect", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "references from archived or missing documents", action = "deleted",
         tbl = "document_mention", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "live links from archived or missing documents", action = "archived",
         tbl = "document_link", where = "(archived_at IS NULL OR archived_at = '') AND from_document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "link sync records of archived or missing documents", action = "deleted",
         tbl = "document_link_sync", where = "document_id NOT IN (" .. ACTIVE_DOCUMENT_IDS .. ")"},
        {label = "centres of archived or missing tags", action = "deleted",
         tbl = "tag_centre", where = "tag_id NOT IN (" .. ACTIVE_TAG_IDS .. ")"},
    }
    results = {}
    for _, check in ipairs(checks) do
        rows = db.query(db_path, string.format("SELECT COUNT(*) AS n FROM %s WHERE %s;", check.tbl, check.where))
        count = 0
        if rows != nil and rows[1] != nil then
            count = tonumber(rows[1].n)
        end
        if count > 0 and dry_run != true then
            if check.action == "archived" then
                db.exec(db_path, string.format("UPDATE %s SET archived_at = %s WHERE %s;", check.tbl, db.now_expr(db_path), check.where))
            else
                db.exec(db_path, string.format("DELETE FROM %s WHERE %s;", check.tbl, check.where))
            end
        end
        table.insert(results, {label = check.label, action = check.action, count = count})
    end

    model = agent_provider_lib.embedding_model()
    if model != nil then
        rows = db.query(db_path, string.format("SELECT COUNT(*) AS n FROM document_embedding WHERE model != %s;", db.quote(model)))
        if rows != nil and rows[1] != nil then
            table.insert(results, {label = "embeddings from another model than " .. model .. " (run `daat repair embeddings`)",
                action = "left", count = tonumber(rows[1].n)})
        end
    end
    return results
end

function document.do_document(cmd_args, db_path)
    action = cmd_args[1]

    -- What a document's embedding is made from, after embedding_skip
    -- and the transcript rule -- to check a pattern against real text.
    if action == "embedding-text" then
        text = document.embedding_text(db_path, tonumber(cmd_args[2]))
        if text == nil then
            print("Usage: daat document embedding-text <document_id>")
            return
        end
        print(text)
        return
    end

    if action == "embed-pending" then
        counts = document.embed_pending(db_path)
        print(string.format("Embedded %d, unchanged %d, failed %d, dropped %d (archived); %d still waiting",
            counts.embedded, counts.unchanged, counts.failed, counts.dropped, counts.waiting))
        for _, line in ipairs(counts.upkeep) do
            print("tag upkeep: " .. line)
        end
        return
    end

    -- Bulk document import (e.g. meeting notes, a literature corpus).
    -- Links and embeddings come from entity.create's own document hook
    -- either way, same as `entity create-json`; what differs is that
    -- this is deliberately NOT all-or-nothing the way create_batch's own
    -- validate-everything-first gate is: a real, heterogeneous batch
    -- (hundreds of files of unpredictable quality) shouldn't have one
    -- bad row block every other row -- each is created independently,
    -- successes and failures both reported.
    if action == "create-json" then
        input = io.read("*all")
        rows_values, _, decode_err = json.decode(input)
        if rows_values == nil then
            print(json.encode({error = "Invalid JSON input: " .. tostring(decode_err)}))
            return
        end
        author = os.getenv("USER")
        created_ids = {}
        failed = {}
        for i, values in ipairs(rows_values) do
            -- pcalled: db.exec/db.query raise a hard Lua error() on a
            -- genuine SQL failure (e.g. "Data too long for column")
            -- rather than returning nil+issues -- without this, one
            -- such row would crash the whole create-json process,
            -- losing every other row already queued in the same
            -- invocation, not just the bad one.
            ok, id_or_err, issues = pcall(document.create_page, db_path, author, values.title, values.parent_id, values.content, nil)
            if ok == false then
                table.insert(failed, {row_index = i, title = values.title, issues = tostring(id_or_err)})
            elseif id_or_err != nil then
                table.insert(created_ids, id_or_err)
            else
                table.insert(failed, {row_index = i, title = values.title, issues = issues})
            end
        end
        print(json.encode({created_ids = created_ids, failed = failed}))
        return
    end

    print("Usage: daat document <create-json|embed-pending|embedding-text>")
end

entity.register_lifecycle_listener({
    on_settle_write_ddl = function(db_path, entity_type)
        if entity_type == "document" then
            document.ensure_pool_state(db_path)
        end
    end,
    on_created = function(db_path, entity_type, new_entity_id)
        document.on_entity_created(db_path, entity_type, new_entity_id)
    end,
    on_updated = function(db_path, entity_type, entity_id, field_changes)
        document.on_entity_updated(db_path, entity_type, entity_id, field_changes)
    end,
    on_archived = function(db_path, entity_type, entity_id)
        document.on_entity_archived(db_path, entity_type, entity_id)
    end,
    on_unarchived = function(db_path, entity_type, entity_id)
        document.on_entity_unarchived(db_path, entity_type, entity_id)
    end,
})

return document
