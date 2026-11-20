-- Co-retrieval link evaluation, passage-similarity gating, claim
-- verification, edge reinforcement, and `daat repair connections`.

const agent_provider_lib = require("agent_provider")
const config = require("config")
const db = require("database")
const document = require("document")
const entity = require("entity")
const knowledge_store = require("knowledge.store")
const passage_lib = require("document.passage")

const knowledge_links = {}

const CO_RETRIEVAL_LINK_THRESHOLD = 3
const CO_RETRIEVAL_HUB_RATIO = 0.25
const CO_RETRIEVAL_REEVALUATION_STEP = 3
const LINK_REINFORCEMENT_DELTA = 0.15
const LINK_REASON_MIN_WORDS = 8
const CLAIM_REFERENCE_WORDS = {"Experiment", "Exp", "Sample", "Table", "Figure", "Chapter"}

const LINK_EVALUATION_SYSTEM_PROMPT = """
Two documents from the same knowledge pool have repeatedly been retrieved together in the same searches. Judge whether they describe a genuinely meaningful connection (the same topic, a real dependency, one explains or extends the other) as opposed to just coincidental overlap in unrelated searches. Reply on a single line: YES or NO, a colon, then one sentence. For YES, the sentence states the specific connection in terms of the documents' content (what one says about, uses from, or adds to the other) and names the information both share (the experiment, sample, method, result or decision) -- not merely that they are related, of the same kind ("both are meeting notes") or were retrieved together; if you can't name what they share, answer NO. For NO, the sentence says why the overlap is coincidental. A YES sentence is written into a note that links both documents right before it, so refer to them by what they are, never as "Document A" or "Document B". Example: "YES: the subculture protocol calls for exactly this medium recipe."
"""

function knowledge_links.co_retrieval_eligible(co_count, retrieval_count_a, retrieval_count_b)
    if co_count < CO_RETRIEVAL_LINK_THRESHOLD then
        return false
    end
    larger_retrieval_count = retrieval_count_a
    if retrieval_count_b > larger_retrieval_count then
        larger_retrieval_count = retrieval_count_b
    end
    if larger_retrieval_count <= 0 then
        return false
    end
    return (co_count / larger_retrieval_count) >= CO_RETRIEVAL_HUB_RATIO
end

function knowledge_links.co_retrieval_pairs(db_path, document_ids)
    if document_ids == nil or #document_ids < 2 then
        return {}
    end
    id_list = {}
    for _, id in ipairs(document_ids) do
        table.insert(id_list, tostring(tonumber(id)))
    end
    id_list_sql = table.concat(id_list, ", ")

    rows = db.query(db_path, string.format("""
        SELECT a.document_id AS doc_a, b.document_id AS doc_b, COUNT(DISTINCT a.retrieval_id) AS co_count
        FROM knowledge_retrieval_hit a
        JOIN knowledge_retrieval_hit b ON a.retrieval_id = b.retrieval_id AND a.document_id < b.document_id
        WHERE a.document_id IN (%s) AND b.document_id IN (%s)
          AND a.reinforcement_delta IS NOT NULL AND b.reinforcement_delta IS NOT NULL
        GROUP BY a.document_id, b.document_id;
    """, id_list_sql, id_list_sql))
    if rows == nil then
        return {}
    end
    return rows
end

function knowledge_links.get_link_review(db_path, document_a_id, document_b_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_link_review WHERE document_a_id = %d AND document_b_id = %d;",
        tonumber(document_a_id), tonumber(document_b_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function knowledge_links.record_link_review(db_path, document_a_id, document_b_id, co_count, decision, reason)
    db.exec(db_path, string.format(
        "%s knowledge_link_review (document_a_id, document_b_id, last_co_count, decision, reason, evaluated_at) VALUES (%d, %d, %d, %s, %s, %s);",
        db.replace_into(db_path), tonumber(document_a_id), tonumber(document_b_id),
        tonumber(co_count), db.quote(decision), db.literal(document.clip_text(reason)), db.now_expr(db_path)
    ))
end

function knowledge_links.link_reason_too_thin(reason)
    if reason == nil then
        return true
    end
    words = 0
    for _ in string.gmatch(reason, "%S+") do
        words = words + 1
    end
    return words < LINK_REASON_MIN_WORDS
end

function knowledge_links.parse_link_judgment(answer)
    if answer == nil then
        return nil, nil
    end
    text = string.gsub(answer, "^%s*(.-)%s*$", "%1")
    text = string.gsub(text, "^[%*\"']+", "")
    word, rest = string.match(text, "^(%a+)(.*)$")
    if word == nil then
        return nil, nil
    end
    word = string.upper(word)
    if word != "YES" and word != "NO" then
        return nil, nil
    end
    rest = string.gsub(rest, "^[%*\"']*%s*[:%-]?%s*", "")
    rest = string.gsub(rest, "^%s*(.-)%s*$", "%1")
    if rest == "" then
        rest = nil
    end
    return word, rest
end

function knowledge_links.link_pair_prompt(doc_a, doc_b)
    body_a = doc_a.content
    if body_a == nil then
        body_a = ""
    end
    body_b = doc_b.content
    if body_b == nil then
        body_b = ""
    end
    return string.format(
        "Document A -- %s:\n%s\n\nDocument B -- %s:\n%s",
        tostring(doc_a.title), body_a, tostring(doc_b.title), body_b
    )
end

function knowledge_links.documents_connected(db_path, document_a_id, document_b_id)
    a = tonumber(document_a_id)
    b = tonumber(document_b_id)
    rows = db.query(db_path, string.format("""
        SELECT 1 FROM document_link
        WHERE ((from_document_id = %d AND to_document_id = %d) OR (from_document_id = %d AND to_document_id = %d))
          AND (archived_at IS NULL OR archived_at = '')
        LIMIT 1;
    """, a, b, b, a))
    if rows != nil and rows[1] != nil then
        return "direct"
    end
    rows = db.query(db_path, string.format("""
        SELECT 1 FROM document_link la
        JOIN document_link lb ON lb.from_document_id = la.from_document_id
        JOIN document holder ON holder.id = la.from_document_id
        WHERE la.to_document_id = %d AND lb.to_document_id = %d
          AND (la.archived_at IS NULL OR la.archived_at = '') AND (lb.archived_at IS NULL OR lb.archived_at = '')
          AND (holder.archived_at IS NULL OR holder.archived_at = '')
        LIMIT 1;
    """, a, b))
    if rows != nil and rows[1] != nil then
        return "through_document"
    end
    return nil
end

function knowledge_links.reinforce_link_strength(db_path, document_a_id, document_b_id)
    db.exec(db_path, string.format("""
        UPDATE document_link SET raw_strength = raw_strength + %.17g
        WHERE ((from_document_id = %d AND to_document_id = %d) OR (from_document_id = %d AND to_document_id = %d))
          AND (archived_at IS NULL OR archived_at = '');
    """, LINK_REINFORCEMENT_DELTA, tonumber(document_a_id), tonumber(document_b_id), tonumber(document_b_id), tonumber(document_a_id)))
end

function knowledge_links.due_for_link_review(review, co_count)
    if review == nil then
        return true
    end
    if review.decision == "linked" or review.decision == "unlinkable" then
        return false
    end
    return co_count >= (tonumber(review.last_co_count) + CO_RETRIEVAL_REEVALUATION_STEP)
end

function knowledge_links.reason_claims(reason)
    claims = {}
    seen = {}
    add = function(kind, value)
        key = kind .. ":" .. string.lower(value)
        if seen[key] == nil then
            seen[key] = true
            table.insert(claims, {kind = kind, value = value})
        end
    end
    if reason == nil then
        return claims
    end
    for surname in string.gmatch(reason, "(%u[%a'%-]+) et al") do
        add("text", surname)
    end
    for group in string.gmatch(reason, "%b()") do
        for year in string.gmatch(group, "%f[%d](1[89]%d%d)%f[%D]") do
            add("text", year)
        end
        for year in string.gmatch(group, "%f[%d](20%d%d)%f[%D]") do
            add("text", year)
        end
    end
    for token in string.gmatch(reason, "[%w]+") do
        is_reference = false
        for _, word in ipairs(CLAIM_REFERENCE_WORDS) do
            if string.match(string.lower(token), "^" .. string.lower(word) .. "%d+$") != nil then
                is_reference = true
            end
        end
        if not is_reference and string.len(token) >= 3 and string.find(token, "%a%d") != nil then
            add("text", token)
        end
    end
    for _, word in ipairs(CLAIM_REFERENCE_WORDS) do
        for number in string.gmatch(reason, "%f[%a]" .. word .. "%.? ?#?(%d+)") do
            add("reference", word .. " " .. number)
        end
    end
    return claims
end

function claim_in_text(claim, text)
    text = string.gsub(string.lower(text), ",", "")
    if claim.kind == "text" then
        return string.find(text, string.lower(claim.value), 1, true) != nil
    end
    word, number = string.match(claim.value, "^(%a+) (%d+)$")
    prefix = string.sub(string.lower(word), 1, 3)
    return string.find(text, "%f[%a]" .. prefix .. "%a*%.?[ #]*0*" .. number .. "%f[%D]") != nil
end

function knowledge_links.unverified_claims(reason, doc_a, doc_b)
    text_a = tostring(doc_a.title) .. "\n" .. tostring(doc_a.content)
    text_b = tostring(doc_b.title) .. "\n" .. tostring(doc_b.content)
    missing = {}
    for _, claim in ipairs(knowledge_links.reason_claims(reason)) do
        if not (claim_in_text(claim, text_a) and claim_in_text(claim, text_b)) then
            table.insert(missing, claim.value)
        end
    end
    return missing
end

function knowledge_links.judge_link(doc_a, doc_b)
    answer, err = agent_provider_lib.generate(nil, LINK_EVALUATION_SYSTEM_PROMPT, knowledge_links.link_pair_prompt(doc_a, doc_b))
    if answer == nil then
        return nil, err
    end
    verdict, reason = knowledge_links.parse_link_judgment(answer)
    if verdict != "YES" then
        return "declined", reason
    end
    if knowledge_links.link_reason_too_thin(reason) then
        return "thin", "no sentence saying what both share: " .. tostring(reason)
    end
    missing = knowledge_links.unverified_claims(reason, doc_a, doc_b)
    if #missing > 0 then
        return "unverified", "not in both documents: " .. table.concat(missing, ", ") .. " -- " .. tostring(reason)
    end
    return "linked", reason
end

function knowledge_links.link_similarity(db_path, doc_a, doc_b, every_passage)
    conf = config.load()
    per_document = conf.link_gate_passages_per_document
    max_new = conf.link_gate_max_embeds
    if every_passage == true then
        per_document = math.huge
        max_new = math.huge
    end
    for _, doc in ipairs({doc_a, doc_b}) do
        content = tostring(doc.content)
        if string.len(content) - document.preamble_end(content) + 1 < conf.passage_min_chars then
            return nil, "too little text to compare in #" .. tostring(doc.id)
        end
    end
    return passage_lib.best_pair(db_path, agent_provider_lib.embedding_model(),
        tostring(doc_a.title) .. "\n\n" .. tostring(doc_a.content),
        tostring(doc_b.title) .. "\n\n" .. tostring(doc_b.content),
        per_document, max_new)
end

function knowledge_links.passes_passage_gate(db_path, doc_a, doc_b, every_passage)
    threshold = config.load().link_passage_gate
    if threshold <= 0 then
        return true, nil, nil
    end
    score, pa, pb = knowledge_links.link_similarity(db_path, doc_a, doc_b, every_passage)
    if score == nil then
        io.write(io.stderr, "link passage gate skipped: " .. tostring(pa) .. "\n")
        return true, tostring(pa), false
    end
    if score < threshold then
        return false, string.format("best passage pair similarity %.3f is below %.3f", score, threshold), true, pa, pb
    end
    return true, nil, true, pa, pb
end

function knowledge_links.evaluate_co_retrieval_pair(db_path, author, doc_a, doc_b, co_count)
    passed, why = knowledge_links.passes_passage_gate(db_path, doc_a, doc_b)
    if passed == false then
        knowledge_links.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "dissimilar", why)
        return
    end
    decision, reason = knowledge_links.judge_link(doc_a, doc_b)
    if decision == nil then
        return
    end
    if decision != "linked" then
        knowledge_links.record_link_review(db_path, doc_a.id, doc_b.id, co_count, decision, reason)
        return
    end
    draft = document.connection_draft(db_path, doc_a.id, doc_b.id, reason)
    if draft == nil then
        knowledge_links.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "unlinkable", reason)
        return
    end
    document.create_page(db_path, author, draft.title, draft.parent_id, draft.content, nil)
    knowledge_links.record_link_review(db_path, doc_a.id, doc_b.id, co_count, "linked", reason)
end

function knowledge_links.maybe_link_co_retrieved(db_path, author, document_ids)
    pairs_found = knowledge_links.co_retrieval_pairs(db_path, document_ids)
    if #pairs_found == 0 then
        return
    end

    id_list = {}
    for _, id in ipairs(document_ids) do
        table.insert(id_list, tostring(tonumber(id)))
    end
    id_list_sql = table.concat(id_list, ", ")
    direct_pairs = {}
    direct_rows = db.query(db_path, string.format("""
        SELECT from_document_id, to_document_id FROM document_link
        WHERE from_document_id IN (%s) AND to_document_id IN (%s)
          AND (archived_at IS NULL OR archived_at = '');
    """, id_list_sql, id_list_sql))
    if direct_rows != nil then
        for _, r in ipairs(direct_rows) do
            fa = tonumber(r.from_document_id)
            tb = tonumber(r.to_document_id)
            if fa != nil and tb != nil then
                if fa < tb then
                    direct_pairs[tostring(fa) .. ":" .. tostring(tb)] = true
                else
                    direct_pairs[tostring(tb) .. ":" .. tostring(fa)] = true
                end
            end
        end
    end

    docs_by_id = {}
    function get_cached_doc(doc_id)
        cached = docs_by_id[doc_id]
        if cached == false then
            return nil
        end
        if cached != nil then
            return cached
        end
        fetched = knowledge_store.get_document(db_path, doc_id)
        if fetched == nil then
            docs_by_id[doc_id] = false
            return nil
        end
        docs_by_id[doc_id] = fetched
        return fetched
    end

    for _, pair in ipairs(pairs_found) do
        doc_a_id = tonumber(pair.doc_a)
        doc_b_id = tonumber(pair.doc_b)
        co_count = tonumber(pair.co_count)
        pair_key = tostring(doc_a_id) .. ":" .. tostring(doc_b_id)

        if direct_pairs[pair_key] == true then
            knowledge_links.reinforce_link_strength(db_path, doc_a_id, doc_b_id)
        elseif co_count >= CO_RETRIEVAL_LINK_THRESHOLD then
            connected = knowledge_links.documents_connected(db_path, doc_a_id, doc_b_id)
            if connected == "direct" then
                knowledge_links.reinforce_link_strength(db_path, doc_a_id, doc_b_id)
            elseif connected == nil then
                review = knowledge_links.get_link_review(db_path, doc_a_id, doc_b_id)
                if knowledge_links.due_for_link_review(review, co_count) then
                    doc_a = get_cached_doc(doc_a_id)
                    doc_b = get_cached_doc(doc_b_id)
                    if doc_a != nil and doc_b != nil and not document.is_connection_title(doc_a.title)
                            and not document.is_connection_title(doc_b.title) then
                        if knowledge_links.co_retrieval_eligible(co_count, tonumber(doc_a.retrieval_count), tonumber(doc_b.retrieval_count)) then
                            knowledge_links.evaluate_co_retrieval_pair(db_path, author, doc_a, doc_b, co_count)
                        end
                    end
                end
            end
        end
    end
end

function knowledge_links.connection_reason(content)
    if content == nil then
        return nil
    end
    reason = string.match(content, "^%s*%[%[.-%]%]%s+and%s+%[%[.-%]%]%s*:%s*(.-)%s*$")
    if reason == nil then
        reason = string.gsub(content, "%[%[.-%]%]", "")
        reason = string.gsub(reason, "^%s*(.-)%s*$", "%1")
    end
    if reason == "" then
        return nil
    end
    return reason
end

function revoke_connection(db_path, connection_id, why)
    entity.archive(db_path, "document", tonumber(connection_id), "system", nil, "repair connections: " .. why)
end

function knowledge_links.repair_connections(db_path, dry_run, all)
    rows = db.query(db_path, string.format(
        "SELECT id FROM document WHERE title LIKE %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id;",
        db.quote("%" .. document.CONNECTION_TITLE_SEPARATOR .. "%")))
    if rows == nil then
        rows = {}
    end
    report = {}
    counts = {explained = 0, revoked = 0, dissimilar = 0, kept = 0, failed = 0}
    function snippet(p)
        return "@" .. tostring(p.offset - 1) .. " " .. string.gsub(string.sub(p.text, 1, 160), "%s+", " ")
    end
    function record(doc_a, doc_b, decision, reason)
        review = knowledge_links.get_link_review(db_path, doc_a.id, doc_b.id)
        co_count = 0
        if review != nil then
            co_count = tonumber(review.last_co_count)
        end
        knowledge_links.record_link_review(db_path, doc_a.id, doc_b.id, co_count, decision, reason)
    end
    for _, row in ipairs(rows) do
        connection = entity.get(db_path, "document", tonumber(row.id))
        label = "#" .. tostring(connection.id) .. " " .. tostring(connection.title)
        ends = db.query(db_path, string.format(
            "SELECT DISTINCT l.to_document_id AS id, d.title FROM document_link l JOIN document d ON d.id = l.to_document_id " ..
            "WHERE l.from_document_id = %d AND (l.archived_at IS NULL OR l.archived_at = '') " ..
            "AND (d.archived_at IS NULL OR d.archived_at = '') ORDER BY l.to_document_id;", tonumber(connection.id)))
        if ends == nil then
            ends = {}
        end
        chained = document.connection_title_count(connection.title) > 1
        for _, e in ipairs(ends) do
            if document.is_connection_title(e.title) then
                chained = true
            end
        end
        why = nil
        if chained then
            why = "it connects another connection document"
        elseif #ends != 2 then
            why = "its two documents aren't both active"
        end
        if why != nil then
            if dry_run then
                table.insert(report, "would revoke " .. label .. ": " .. why)
            else
                revoke_connection(db_path, connection.id, why)
                table.insert(report, "revoked " .. label .. ": " .. why)
            end
            counts.revoked = counts.revoked + 1
        else
            doc_a = knowledge_store.get_document(db_path, tonumber(ends[1].id))
            doc_b = knowledge_store.get_document(db_path, tonumber(ends[2].id))
            passed, gate_why, measured, pa, pb = knowledge_links.passes_passage_gate(db_path, doc_a, doc_b, true)
            if passed == false then
                detail = label .. ": " .. gate_why .. " | #" .. tostring(doc_a.id) .. " " .. snippet(pa) .. " | #" .. tostring(doc_b.id) .. " " .. snippet(pb)
                if dry_run then
                    table.insert(report, "would revoke " .. detail)
                else
                    revoke_connection(db_path, connection.id, gate_why)
                    record(doc_a, doc_b, "dissimilar", gate_why)
                    table.insert(report, "revoked " .. detail)
                end
                counts.dissimilar = counts.dissimilar + 1
            elseif all == true or measured == false or knowledge_links.link_reason_too_thin(knowledge_links.connection_reason(connection.content)) then
                if dry_run then
                    because = "asked to re-check every one"
                    if measured == false then
                        because = "the gate can't measure it: " .. tostring(gate_why)
                    elseif all != true then
                        because = "its reason doesn't say what both share"
                    end
                    table.insert(report, "would explain or revoke " .. label .. " (" .. because .. ")")
                else
                    decision, reason = knowledge_links.judge_link(doc_a, doc_b)
                    if decision == nil then
                        counts.failed = counts.failed + 1
                        table.insert(report, "left " .. label .. ": model call failed: " .. tostring(reason))
                    elseif decision == "linked" and document.connection_draft(db_path, doc_a.id, doc_b.id, reason) != nil then
                        draft = document.connection_draft(db_path, doc_a.id, doc_b.id, reason)
                        document.update_page(db_path, "system", tonumber(connection.id), connection.title, connection.parent_id, draft.content, nil)
                        record(doc_a, doc_b, "linked", reason)
                        counts.explained = counts.explained + 1
                        table.insert(report, "explained " .. label .. ": " .. reason)
                    else
                        revoke_connection(db_path, connection.id, decision .. " -- " .. tostring(reason))
                        record(doc_a, doc_b, decision, reason)
                        counts.revoked = counts.revoked + 1
                        table.insert(report, "revoked " .. label .. ": " .. decision .. " -- " .. tostring(reason))
                    end
                end
            else
                counts.kept = counts.kept + 1
            end
        end
    end
    if dry_run then
        table.insert(report, string.format("%d would be revoked by the passage gate, %d kept as they are (dry run: no model calls)",
            counts.dissimilar, counts.kept))
    else
        table.insert(report, string.format("%d explained, %d revoked by the passage gate, %d revoked, %d kept as they are, %d left (model call failed)",
            counts.explained, counts.dissimilar, counts.revoked, counts.kept, counts.failed))
    end
    return report
end

return knowledge_links
