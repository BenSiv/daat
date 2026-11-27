-- Retrieval logging, deferred/inline review gates, spreading activation,
-- reply classification, and shared search_for_display formatting.

const config = require("config")
const curate_lib = require("knowledge.curate")
const db = require("database")
const document = require("document")
const entity = require("entity")
const knowledge_links = require("knowledge.links")
const knowledge_store = require("knowledge.store")
const passage_lib = require("document.passage")

const knowledge_review = {}

const CURATED_SOURCE_TYPES = {curated = true, reference = true, record = true}
const RETRIEVAL_REVIEW_STALE_SECONDS = 900

function knowledge_review.can_hold_tier(source_type)
    return source_type != nil and CURATED_SOURCE_TYPES[source_type] == true
end

function knowledge_review.distill_document(db_path, author, source_document_id, title, body)
    document_id, issues = knowledge_store.create_document_note(db_path, author, title, body, "distilled", source_document_id, nil)
    if document_id == nil then
        messages = {}
        if issues != nil then
            for _, issue in ipairs(issues) do
                if issue.severity == "error" then
                    table.insert(messages, tostring(issue.message))
                end
            end
        end
        if #messages == 0 then
            return nil, "failed to create the distilled document"
        end
        return nil, table.concat(messages, "; ")
    end
    return document_id
end

function knowledge_review.begin_retrieval(db_path, session_id, query_text, hit_count, author, status)
    if status == nil then
        status = "reviewed"
    end
    reviewed_expr = "NULL"
    if status == "reviewed" then
        reviewed_expr = db.now_expr(db_path)
    end
    _, retrieval_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_retrieval (session_id, author, query_text, hit_count, status, reviewed_at) VALUES (%s, %s, %s, %d, %s, %s);",
        db.literal(session_id), db.literal(author), db.literal(query_text), tonumber(hit_count), db.quote(status), reviewed_expr
    ))
    return tonumber(retrieval_id)
end

function knowledge_review.queue_retrieval_hits(db_path, retrieval_id, results)
    if results == nil or #results == 0 then
        return
    end
    values = {}
    for rank, r in ipairs(results) do
        aspect_literal = "NULL"
        if tonumber(r.aspect) != nil then
            aspect_literal = tostring(tonumber(r.aspect))
        end
        score = tonumber(r.score)
        if score == nil then
            score = 0
        end
        table.insert(values, string.format("(%d, %d, %d, %.17g, %s)",
            tonumber(retrieval_id), tonumber(r.id), tonumber(rank), score, aspect_literal))
    end
    db.exec(db_path, string.format(
        "%s knowledge_retrieval_hit (retrieval_id, document_id, `rank`, score, aspect) VALUES %s;",
        db.replace_into(db_path), table.concat(values, ", ")
    ))
end

function knowledge_review.record_retrieval_hit(db_path, retrieval_id, document_id, tier, rank, score, content_hash, aspect)
    delta = document.reinforcement_delta(tier)
    tier_weight = document.tier_weight(tier)
    db.exec(db_path, string.format(
        "UPDATE document SET retrieval_count = retrieval_count + 1, " ..
        "content_hash = %s, updated_at = %s WHERE id = %d;",
        db.quote(content_hash), db.now_expr(db_path), tonumber(document_id)
    ))
    document.reinforce_pool_heat(db_path, document_id, delta)
    aspect_literal = "NULL"
    if tonumber(aspect) != nil then
        aspect_literal = tostring(tonumber(aspect))
    end
    db.exec(db_path, string.format(
        "%s knowledge_retrieval_hit (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta, aspect) " ..
        "VALUES (%d, %d, %d, %.17g, %.17g, %.17g, %s);",
        db.replace_into(db_path),
        tonumber(retrieval_id), tonumber(document_id), tonumber(rank), tonumber(score), tier_weight, delta, aspect_literal
    ))
    return delta
end

-- Only system-derived (`source_type` set) rows fold on hash match; user-authored docs stay active.
-- See doc/decisions/007-usage-driven-knowledge-pool-and-curation-ladder.md.
function knowledge_review.duplication_status(db_path, document_id, content_hash, source_type)
    if content_hash == nil or content_hash == "" then
        return "unique"
    end
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE content_hash = %s AND id != %d AND (archived_at IS NULL OR archived_at = '') AND merged_into IS NULL ORDER BY id ASC LIMIT 1;",
        db.quote(content_hash), tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return "unique"
    end
    canonical_id = tonumber(rows[1].id)
    if canonical_id < tonumber(document_id) then
        if source_type != nil and source_type != "" then
            db.exec(db_path, string.format(
                "UPDATE document SET duplicate_of = %d, merged_into = %d WHERE id = %d;",
                canonical_id, canonical_id, tonumber(document_id)
            ))
            document.return_pool_heat(db_path, document_id)
        end
        return "duplicate-of-" .. tostring(canonical_id)
    end
    return "unique"
end

function knowledge_review.review_retrieval(db_path, retrieval_id, author)
    rows = db.query(db_path, string.format(
        "SELECT document_id, aspect, reviewed_at FROM knowledge_retrieval_hit WHERE retrieval_id = %d;", tonumber(retrieval_id)
    ))
    if rows == nil then
        return
    end
    curate_aspects = config.load().curate_aspects == true
    peer_count = #rows - 1
    if peer_count < 0 then
        peer_count = 0
    end

    for _, row in ipairs(rows) do
        already_reviewed = row.reviewed_at != nil and row.reviewed_at != ""
        doc = nil
        if not already_reviewed then
            doc = knowledge_store.get_document(db_path, row.document_id)
        end
        if doc != nil then
            is_system = doc.source_type != nil and doc.source_type != ""
            body = doc.content
            if body == nil then
                body = ""
            end
            content_shape = document.content_shape(body)
            duplication = knowledge_review.duplication_status(db_path, doc.id, doc.content_hash, doc.source_type)
            connectivity = document.connectivity_status(peer_count)

            title_status = "ok"
            new_title = doc.title
            if is_system and document.title_is_generic(doc.title) then
                new_title = document.guess_title_from_body(body)
                title_status = "retitled"
            end

            target_tier = tonumber(doc.tier)
            if knowledge_store.due_for_review(tonumber(doc.retrieval_count), doc.effective_heat) then
                if not knowledge_review.can_hold_tier(doc.source_type) then
                    target_tier = 0
                    curate_lib.queue(db_path, doc)
                end
            end
            hit_aspect = tonumber(row.aspect)
            if curate_aspects and hit_aspect != nil and not knowledge_review.can_hold_tier(doc.source_type) then
                aspect_hits = db.query(db_path, string.format(
                    "SELECT COUNT(*) AS n FROM knowledge_retrieval_hit WHERE document_id = %d AND aspect = %d AND reinforcement_delta IS NOT NULL;",
                    tonumber(doc.id), hit_aspect))
                if aspect_hits != nil and aspect_hits[1] != nil and knowledge_store.due_for_review(tonumber(aspect_hits[1].n), 0) then
                    curate_lib.queue_aspect(db_path, doc, hit_aspect)
                end
            end

            if new_title != doc.title then
                entity.update(db_path, "document", doc.id, {title = new_title}, "system")
            end
            db.exec(db_path, string.format(
                "UPDATE document SET tier = %d, updated_at = %s WHERE id = %d;",
                target_tier, db.now_expr(db_path), doc.id
            ))
            db.exec(db_path, string.format(
                "UPDATE knowledge_retrieval_hit SET atomicity_status = %s, connectivity_status = %s, duplication_status = %s, title_status = %s, reviewed_at = %s " ..
                "WHERE retrieval_id = %d AND document_id = %d;",
                db.quote(content_shape), db.quote(connectivity), db.quote(duplication), db.quote(title_status), db.now_expr(db_path),
                tonumber(retrieval_id), doc.id
            ))
        end
    end

    document_ids = {}
    for _, row in ipairs(rows) do
        table.insert(document_ids, row.document_id)
    end
    knowledge_links.maybe_link_co_retrieved(db_path, author, document_ids)
end

function knowledge_review.reply_has_visible_reasoning(text)
    if text == nil or text == "" then
        return false
    end
    if string.find(text, "<think>", 1, true) != nil then
        return true
    end
    if string.find(text, "</think>", 1, true) != nil then
        return true
    end
    if string.find(text, "Thinking...", 1, true) != nil then
        return true
    end
    return string.find(string.lower(text), "thinking:", 1, true) == 1
end

function knowledge_review.classify_reply(is_error, text)
    if is_error == true then
        return "error", "error", "none"
    end
    if knowledge_review.reply_has_visible_reasoning(text) then
        return "reasoning-visible", "review", "visible"
    end
    if text != nil and text != "" then
        return "final", "ok", "none"
    end
    return "empty", "empty", "none"
end

function knowledge_review.spread_activation(db_path, retrieval_id, document_id, base_delta, hit_ids)
    neighbors = document.linked_neighbors(db_path, document_id)
    if #neighbors == 0 then
        return
    end
    total_strength = 0
    for _, neighbor in ipairs(neighbors) do
        total_strength = total_strength + tonumber(neighbor.raw_strength)
    end
    for _, neighbor in ipairs(neighbors) do
        neighbor_id = tonumber(neighbor.id)
        if neighbor_id != nil and hit_ids[neighbor_id] == nil then
            neighbor_doc = knowledge_store.get_document(db_path, neighbor_id)
            if neighbor_doc != nil then
                delta = document.weighted_spreading_delta(base_delta, neighbor.raw_strength, total_strength)
                tier_weight = document.tier_weight(neighbor_doc.tier)
                db.exec(db_path, string.format(
                    "UPDATE document SET updated_at = %s WHERE id = %d;",
                    db.now_expr(db_path), neighbor_id
                ))
                document.reinforce_pool_heat(db_path, neighbor_id, delta)
                db.exec(db_path, string.format(
                    "%s knowledge_retrieval_hit (retrieval_id, document_id, `rank`, score, tier_weight, reinforcement_delta) " ..
                    "VALUES (%d, %d, NULL, NULL, %.17g, %.17g);",
                    db.replace_into(db_path), tonumber(retrieval_id), neighbor_id, tier_weight, delta
                ))
            end
        end
    end
end

function knowledge_review.search_and_log(db_path, query_text, limit, use_semantic, session_id, author)
    results, query_vector, query_model = document.search(db_path, query_text, limit, use_semantic)
    mode = config.load().search_review_mode
    if mode != "inline" then
        if #results == 0 then
            retrieval_id = knowledge_review.begin_retrieval(db_path, session_id, query_text, 0, author, "reviewed")
            return results, retrieval_id, query_vector, query_model
        end
        retrieval_id = knowledge_review.begin_retrieval(db_path, session_id, query_text, #results, author, "pending")
        knowledge_review.queue_retrieval_hits(db_path, retrieval_id, results)
        return results, retrieval_id, query_vector, query_model
    end
    retrieval_id = knowledge_review.begin_retrieval(db_path, session_id, query_text, #results, author, "running")
    hit_ids = {}
    for _, r in ipairs(results) do
        hit_ids[tonumber(r.id)] = true
    end
    for rank, r in ipairs(results) do
        tier = tonumber(r.tier)
        if tier == nil then
            tier = 0
        end
        delta = knowledge_review.record_retrieval_hit(db_path, retrieval_id, r.id, tier, rank, r.score, document.content_hash(r.content), r.aspect)
        knowledge_review.spread_activation(db_path, retrieval_id, r.id, delta, hit_ids)
    end
    if #results > 0 then
        knowledge_review.review_retrieval(db_path, retrieval_id, author)
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_retrieval SET status = 'reviewed', reviewed_at = %s WHERE id = %d;",
        db.now_expr(db_path), tonumber(retrieval_id)
    ))
    return results, retrieval_id, query_vector, query_model
end

function new_retrieval_claim_token()
    crypto_lib = require("crypto")
    return crypto_lib.random_hex(8)
end

function claim_retrieval_review(db_path, retrieval_id, stale_cutoff)
    token = new_retrieval_claim_token()
    if token == nil then
        return false, nil
    end
    now_utc = os.date("!%Y-%m-%d %H:%M:%S")
    db.exec(db_path, string.format("""
        UPDATE knowledge_retrieval
        SET status = 'running', claim_token = %s, claimed_at = %s
        WHERE id = %d AND (status = 'pending' OR (status = 'running' AND claimed_at IS NOT NULL AND claimed_at < %s));
    """, db.quote(token), db.quote(now_utc), tonumber(retrieval_id), db.quote(stale_cutoff)))
    rows = db.query(db_path, string.format(
        "SELECT status, claim_token, author FROM knowledge_retrieval WHERE id = %d;",
        tonumber(retrieval_id)
    ))
    if rows == nil or rows[1] == nil or rows[1].status != "running" or rows[1].claim_token != token then
        return false, nil
    end
    return true, rows[1].author
end

function knowledge_review.apply_retrieval(db_path, retrieval_id, author)
    hits = db.query(db_path, string.format("""
        SELECT document_id, `rank`, score, aspect, reinforcement_delta
        FROM knowledge_retrieval_hit
        WHERE retrieval_id = %d AND `rank` IS NOT NULL
        ORDER BY `rank` ASC;
    """, tonumber(retrieval_id)))
    if hits == nil then
        hits = {}
    end
    if #hits > 0 then
        hit_ids = {}
        id_literals = {}
        for _, h in ipairs(hits) do
            doc_id = tonumber(h.document_id)
            if doc_id != nil and hit_ids[doc_id] == nil then
                hit_ids[doc_id] = true
                table.insert(id_literals, tostring(doc_id))
            end
        end
        docs_by_id = {}
        if #id_literals > 0 then
            doc_rows = db.query(db_path, string.format(
                "SELECT id, tier, content, archived_at FROM document WHERE id IN (%s);",
                table.concat(id_literals, ", ")
            ))
            if doc_rows != nil then
                for _, d in ipairs(doc_rows) do
                    docs_by_id[tonumber(d.id)] = d
                end
            end
        end
        for _, h in ipairs(hits) do
            if tonumber(h.reinforcement_delta) == nil then
                doc_id = tonumber(h.document_id)
                doc = docs_by_id[doc_id]
                if doc != nil and (doc.archived_at == nil or doc.archived_at == "") then
                    tier = tonumber(doc.tier)
                    if tier == nil then
                        tier = 0
                    end
                    score = tonumber(h.score)
                    if score == nil then
                        score = 0
                    end
                    delta = knowledge_review.record_retrieval_hit(
                        db_path, retrieval_id, doc_id, tier, h.rank, score, document.content_hash(doc.content), h.aspect)
                    knowledge_review.spread_activation(db_path, retrieval_id, doc_id, delta, hit_ids)
                else
                    db.exec(db_path, string.format(
                        "UPDATE knowledge_retrieval_hit SET tier_weight = 0, reinforcement_delta = 0, reviewed_at = %s WHERE retrieval_id = %d AND document_id = %d;",
                        db.now_expr(db_path), tonumber(retrieval_id), doc_id
                    ))
                end
            end
        end
        effective_author = author
        if effective_author == nil or effective_author == "" then
            effective_author = "system"
        end
        knowledge_review.review_retrieval(db_path, retrieval_id, effective_author)
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_retrieval SET status = 'reviewed', claim_token = NULL, claimed_at = NULL, reviewed_at = %s WHERE id = %d;",
        db.now_expr(db_path), tonumber(retrieval_id)
    ))
    return #hits
end

function knowledge_review.run_pending_reviews(db_path, limit, stale_seconds)
    if limit == nil then
        limit = 25
    end
    if stale_seconds == nil then
        stale_seconds = RETRIEVAL_REVIEW_STALE_SECONDS
    end
    stale_cutoff = os.date("!%Y-%m-%d %H:%M:%S", os.time() - math.floor(tonumber(stale_seconds)))
    rows = db.query(db_path, string.format("""
        SELECT id FROM knowledge_retrieval
        WHERE status = 'pending' OR (status = 'running' AND claimed_at IS NOT NULL AND claimed_at < %s)
        ORDER BY id ASC LIMIT %d;
    """, db.quote(stale_cutoff), tonumber(limit)))
    lines = {}
    if rows == nil then
        return lines
    end
    for _, row in ipairs(rows) do
        rid = tonumber(row.id)
        claimed, claimed_author = claim_retrieval_review(db_path, rid, stale_cutoff)
        if claimed == true then
            hit_count = knowledge_review.apply_retrieval(db_path, rid, claimed_author)
            table.insert(lines, string.format("retrieval #%d reviewed (%d hits)", rid, hit_count))
        end
    end
    return lines
end

function knowledge_review.search_for_display(db_path, query_text, limit, session_id, author, full)
    results, _, query_vector, query_model = knowledge_review.search_and_log(db_path, query_text, limit, true, session_id, author)
    conf = config.load()
    budget = conf.agent_search_excerpt_length
    if full == true then
        budget = conf.agent_search_excerpt_full_length
    end
    excerpts = {}
    if conf.search_passages == true then
        excerpts = passage_lib.excerpts(db_path, results, query_text, query_vector, query_model, budget, full == true)
    end
    title_counts = {}
    for _, r in ipairs(results) do
        current = title_counts[r.title]
        if current == nil then
            current = 0
        end
        title_counts[r.title] = current + 1
    end
    shown = {}
    for _, r in ipairs(results) do
        excerpt = excerpts[tonumber(r.id)]
        if excerpt == nil then
            excerpt = document.search_snippet(r.content, query_text, budget)
        end
        table.insert(shown, {id = tonumber(r.id), title = r.title, created_at = r.created_at, external_id = r.external_id,
            excerpt = excerpt, same_title_count = title_counts[r.title]})
    end
    return shown
end

return knowledge_review
