-- Public knowledge-pool facade, delegating to focused submodules under src/knowledge/:
--   knowledge.store      - schema DDL, pool document helpers, and session transcript projection
--   knowledge.links      - co-retrieval link evaluation, passage gating, and connection repair
--   knowledge.review     - retrieval logging, spreading activation, and deferred/inline review
--   knowledge.curate     - tier-1 curation of used sources and quiet chat conversations
--   knowledge.synthesize - tier-2 tag reference synthesis
--   knowledge.distill    - tier-3 atomic record distillation

const config = require("config")
const curate_lib = require("knowledge.curate")
const db = require("database")
const distill_lib = require("knowledge.distill")
const document = require("document")
const knowledge_links = require("knowledge.links")
const knowledge_review = require("knowledge.review")
const knowledge_store = require("knowledge.store")
const synthesize_lib = require("knowledge.synthesize")

const knowledge = {}

const KNOWLEDGE_MEMBER_WHERE = knowledge_store.KNOWLEDGE_MEMBER_WHERE

-- Storage & note creation (knowledge.store)
knowledge.ensure_retrieval_review_columns = knowledge_store.ensure_retrieval_review_columns
knowledge.init_schema = knowledge_store.init_schema
knowledge.hand_rolled_sql_columns_text = knowledge_store.hand_rolled_sql_columns_text
knowledge.get_document = knowledge_store.get_document
knowledge.create_document_note = knowledge_store.create_document_note
knowledge.session_document_for = knowledge_store.session_document_for
knowledge.sync_session_document = knowledge_store.sync_session_document
knowledge.set_tier = knowledge_store.set_tier
knowledge.due_for_review = knowledge_store.due_for_review

-- Retrieval logging & review (knowledge.review)
knowledge.distill_document = knowledge_review.distill_document
knowledge.begin_retrieval = knowledge_review.begin_retrieval
knowledge.queue_retrieval_hits = knowledge_review.queue_retrieval_hits
knowledge.record_retrieval_hit = knowledge_review.record_retrieval_hit
knowledge.duplication_status = knowledge_review.duplication_status
knowledge.review_retrieval = knowledge_review.review_retrieval
knowledge.reply_has_visible_reasoning = knowledge_review.reply_has_visible_reasoning
knowledge.classify_reply = knowledge_review.classify_reply
knowledge.can_hold_tier = knowledge_review.can_hold_tier
knowledge.spread_activation = knowledge_review.spread_activation
knowledge.search_and_log = knowledge_review.search_and_log
knowledge.apply_retrieval = knowledge_review.apply_retrieval
knowledge.run_pending_reviews = knowledge_review.run_pending_reviews
knowledge.search_for_display = knowledge_review.search_for_display

-- Co-retrieval links & connection repair (knowledge.links)
knowledge.co_retrieval_eligible = knowledge_links.co_retrieval_eligible
knowledge.co_retrieval_pairs = knowledge_links.co_retrieval_pairs
knowledge.get_link_review = knowledge_links.get_link_review
knowledge.record_link_review = knowledge_links.record_link_review
knowledge.link_reason_too_thin = knowledge_links.link_reason_too_thin
knowledge.parse_link_judgment = knowledge_links.parse_link_judgment
knowledge.link_pair_prompt = knowledge_links.link_pair_prompt
knowledge.documents_connected = knowledge_links.documents_connected
knowledge.reinforce_link_strength = knowledge_links.reinforce_link_strength
knowledge.due_for_link_review = knowledge_links.due_for_link_review
knowledge.maybe_link_co_retrieved = knowledge_links.maybe_link_co_retrieved
knowledge.reason_claims = knowledge_links.reason_claims
knowledge.unverified_claims = knowledge_links.unverified_claims
knowledge.judge_link = knowledge_links.judge_link
knowledge.link_similarity = knowledge_links.link_similarity
knowledge.passes_passage_gate = knowledge_links.passes_passage_gate
knowledge.evaluate_co_retrieval_pair = knowledge_links.evaluate_co_retrieval_pair
knowledge.connection_reason = knowledge_links.connection_reason
knowledge.repair_connections = knowledge_links.repair_connections

--------------------------------------------------------------------------
-- Stats, listings, graph nodes & CLI
--------------------------------------------------------------------------

function count_rows(db_path, query)
    rows = db.query(db_path, query)
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

function knowledge.stats(db_path)
    tier_counts = {}
    for tier = 0, 3 do
        tier_counts[tier] = count_rows(db_path, string.format(
            "SELECT COUNT(*) AS n FROM document WHERE tier = %d AND %s AND (archived_at IS NULL OR archived_at = '');",
            tier, KNOWLEDGE_MEMBER_WHERE
        ))
    end
    session_count = 0
    if db.table_exists(db_path, "agent_session") then
        session_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM agent_session;")
    end
    return {
        tier_counts = tier_counts,
        note_count = count_rows(db_path, string.format(
            "SELECT COUNT(*) AS n FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '');", KNOWLEDGE_MEMBER_WHERE
        )),
        retrieval_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM knowledge_retrieval;"),
        reviewed_note_count = count_rows(db_path, "SELECT COUNT(DISTINCT document_id) AS n FROM knowledge_retrieval_hit WHERE reviewed_at IS NOT NULL;"),
        session_count = session_count,
    }
end

function knowledge.recent_retrievals(db_path, limit)
    if limit == nil then
        limit = 10
    end
    rows = db.query(db_path, string.format(
        "SELECT id, query_text, hit_count, created_at FROM knowledge_retrieval ORDER BY id DESC LIMIT %d;",
        tonumber(limit)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function attach_and_sort_by_pool_heat(db_path, rows)
    document.ensure_pool_state(db_path)
    state_rows = db.query(db_path, "SELECT log_pool_scale FROM knowledge_pool_state WHERE id = 1;")
    log_pool_scale = 0.0
    if state_rows != nil and state_rows[1] != nil then
        log_pool_scale = tonumber(state_rows[1].log_pool_scale)
    end
    for _, row in ipairs(rows) do
        row.effective_heat = document.pool_effective_heat(row.raw_heat, row.log_scale_at_write, log_pool_scale)
    end
    table.sort(rows, function(a, b)
        return a.effective_heat > b.effective_heat
    end)
    return rows
end

function knowledge.list_documents(db_path, tier)
    query = string.format(
        "SELECT * FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '')", KNOWLEDGE_MEMBER_WHERE
    )
    if tier != nil then
        query = query .. " AND tier = " .. tostring(tonumber(tier))
    end
    query = query .. " ORDER BY retrieval_count DESC;"
    rows = db.query(db_path, query)
    if rows == nil then
        return {}
    end
    return attach_and_sort_by_pool_heat(db_path, rows)
end

function knowledge.reviewed_documents(db_path)
    rows = db.query(db_path, """
        SELECT * FROM document
        WHERE id IN (SELECT DISTINCT document_id FROM knowledge_retrieval_hit WHERE reviewed_at IS NOT NULL)
          AND (archived_at IS NULL OR archived_at = '')
        ORDER BY retrieval_count DESC;
    """)
    if rows == nil then
        return {}
    end
    return attach_and_sort_by_pool_heat(db_path, rows)
end

function json_array()
    return setmetatable({}, {__jsontype = "array"})
end

function knowledge.document_tag_labels(db_path)
    rows = db.query(db_path, """
        SELECT dt.document AS document_id, t.label AS label, p.label AS parent_label
        FROM document_tag dt
        JOIN tag t ON t.id = dt.tag
        LEFT JOIN tag p ON p.id = t.parent AND (p.archived_at IS NULL OR p.archived_at = '')
        WHERE dt.decision IN ('computed', 'pinned')
          AND (dt.archived_at IS NULL OR dt.archived_at = '')
          AND (t.archived_at IS NULL OR t.archived_at = '')
        ORDER BY dt.document, CASE WHEN dt.decision = 'pinned' THEN 0 ELSE 1 END, dt.score DESC;
    """)
    labels = {}
    groups = {}
    seen_group = {}
    if rows == nil then
        return labels, groups
    end
    for _, row in ipairs(rows) do
        doc_id = tonumber(row.document_id)
        if labels[doc_id] == nil then
            labels[doc_id] = json_array()
            groups[doc_id] = json_array()
            seen_group[doc_id] = {}
        end
        table.insert(labels[doc_id], row.label)
        group = row.parent_label
        if group == nil or group == "" then
            group = row.label
        end
        if seen_group[doc_id][group] == nil then
            seen_group[doc_id][group] = true
            table.insert(groups[doc_id], group)
        end
    end
    return labels, groups
end

function knowledge.graph_nodes(db_path)
    rows = db.query(db_path, """
        SELECT id, title, tier, raw_heat, log_scale_at_write FROM document
        WHERE (archived_at IS NULL OR archived_at = '') AND merged_into IS NULL;
    """)
    if rows == nil then
        return {}
    end
    rows = attach_and_sort_by_pool_heat(db_path, rows)
    tags, groups = knowledge.document_tag_labels(db_path)
    nodes = {}
    for _, row in ipairs(rows) do
        node_tags = tags[tonumber(row.id)]
        if node_tags == nil then
            node_tags = json_array()
        end
        node_groups = groups[tonumber(row.id)]
        if node_groups == nil then
            node_groups = json_array()
        end
        table.insert(nodes, {id = tonumber(row.id), title = row.title, tier = tonumber(row.tier), heat = row.effective_heat,
            tags = node_tags, groups = node_groups})
    end
    return nodes
end

function knowledge.do_knowledge(cmd_args, db_path)
    action = cmd_args[1]

    if action == "stats" then
        s = knowledge.stats(db_path)
        print(string.format("tier0=%d tier1=%d tier2=%d tier3=%d",
            s.tier_counts[0], s.tier_counts[1], s.tier_counts[2], s.tier_counts[3]))
        print("notes=" .. tostring(s.note_count) .. " retrievals=" .. tostring(s.retrieval_count) ..
            " reviewed=" .. tostring(s.reviewed_note_count) .. " sessions=" .. tostring(s.session_count))
        return
    end

    if action == "list" then
        tier = tonumber(cmd_args[2])
        rows = knowledge.list_documents(db_path, tier)
        for _, row in ipairs(rows) do
            print(string.format("#%s [tier %s] %s (raw_heat=%s, effective=%.2f, retrievals=%s)",
                tostring(row.id), tostring(row.tier), tostring(row.title), tostring(row.raw_heat),
                row.effective_heat, tostring(row.retrieval_count)))
        end
        return
    end

    if action == "show" then
        document_id = tonumber(cmd_args[2])
        if document_id == nil then
            print("Usage: daat knowledge show <document_id>")
            return
        end
        doc = knowledge.get_document(db_path, document_id)
        if doc == nil then
            print("Error: no such document #" .. tostring(document_id))
            return
        end
        print("id: " .. tostring(doc.id))
        print("tier: " .. tostring(doc.tier))
        print("title: " .. tostring(doc.title))
        print("raw_heat: " .. tostring(doc.raw_heat) .. " (effective: " .. string.format("%.2f", doc.effective_heat) .. ")")
        print("retrieval_count: " .. tostring(doc.retrieval_count))
        if doc.source_type != nil and doc.source_type != "" then
            print("source: " .. tostring(doc.source_type) .. " #" .. tostring(doc.source_id))
        end
        print("duplicate_of: " .. tostring(doc.duplicate_of))
        print("body:")
        print(tostring(doc.content))
        return
    end

    if action == "review-pending" then
        limit = tonumber(cmd_args[2])
        for _, line in ipairs(knowledge.run_pending_reviews(db_path, limit)) do
            print(line)
        end
        return
    end

    if action == "curate-pending" then
        limit = tonumber(cmd_args[2])
        for _, line in ipairs(curate_lib.run_pending(db_path, limit, "system")) do
            print(line)
        end
        return
    end

    if action == "synthesize-due" then
        limit = tonumber(cmd_args[2])
        if limit == nil then
            limit = 1
        end
        for _, line in ipairs(synthesize_lib.repair(db_path, limit, false, "system", false)) do
            print(line)
        end
        return
    end

    if action == "distill-due" then
        limit = tonumber(cmd_args[2])
        if limit == nil then
            limit = 1
        end
        for _, line in ipairs(distill_lib.repair(db_path, limit, false, "system", false)) do
            print(line)
        end
        return
    end

    if action == "promote" then
        document_id = tonumber(cmd_args[2])
        tier = tonumber(cmd_args[3])
        if document_id == nil or tier == nil then
            print("Usage: daat knowledge promote <document_id> <tier>")
            return
        end
        doc = knowledge.get_document(db_path, document_id)
        if doc == nil then
            print("Error: no document #" .. tostring(document_id))
            return
        end
        if tier != 0 and not knowledge.can_hold_tier(doc.source_type) then
            print("Error: document #" .. tostring(document_id) .. " is a source; only documents the curation wrote hold tiers 1-3 (doc/tier-curation-ladder.md)")
            return
        end
        knowledge.set_tier(db_path, document_id, tier)
        print("Document #" .. tostring(document_id) .. " set to tier " .. tostring(tier))
        return
    end

    if action == "link-score" then
        pairs_file = nil
        wanted = {}
        if cmd_args[2] == "--pairs" and cmd_args[3] != nil then
            pairs_file = io.open(cmd_args[3], "r")
            if pairs_file == nil then
                print("Error: can't read " .. tostring(cmd_args[3]))
                return
            end
            for line in io.lines(cmd_args[3]) do
                a, b = string.match(line, "^%s*(%d+)%s+(%d+)")
                if a != nil then
                    table.insert(wanted, {tonumber(a), tonumber(b)})
                end
            end
            io.close(pairs_file)
        elseif tonumber(cmd_args[2]) != nil and tonumber(cmd_args[3]) != nil then
            table.insert(wanted, {tonumber(cmd_args[2]), tonumber(cmd_args[3])})
        else
            print("Usage: daat knowledge link-score <document_id> <document_id> | --pairs <file>")
            return
        end
        for _, pair in ipairs(wanted) do
            doc_a = knowledge.get_document(db_path, pair[1])
            doc_b = knowledge.get_document(db_path, pair[2])
            score = nil
            pa = nil
            pb = nil
            if doc_a == nil or doc_b == nil then
                pa = "no such document"
            else
                score, pa, pb = knowledge.link_similarity(db_path, doc_a, doc_b)
            end
            if pairs_file != nil then
                shown = "NA"
                if score != nil then
                    shown = string.format("%.4f", score)
                end
                print(string.format("%d %d %s", pair[1], pair[2], shown))
            elseif score == nil then
                print("Can't measure: " .. tostring(pa))
            else
                threshold = config.load().link_passage_gate
                verdict = "stops it"
                if threshold <= 0 or score >= threshold then
                    verdict = "passes"
                end
                print(string.format("best passage pair similarity: %.4f (gate %.3f: %s)", score, threshold, verdict))
                print("#" .. tostring(pair[1]) .. " at character " .. tostring(pa.offset - 1) .. ":\n" .. string.sub(pa.text, 1, 600))
                print("#" .. tostring(pair[2]) .. " at character " .. tostring(pb.offset - 1) .. ":\n" .. string.sub(pb.text, 1, 600))
            end
        end
        return
    end

    print("Usage: daat knowledge <stats|list [tier]|show <document_id>|promote <document_id> <tier>|review-pending [N]|curate-pending [N]|synthesize-due [N]|distill-due [N]|link-score <id> <id>|distill>")
end

return knowledge
