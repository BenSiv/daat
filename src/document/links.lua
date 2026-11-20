-- Cross-document [[link]] parsing, code-fence-aware extraction,
-- resolution, fuzzy autocomplete, backlinks, graph edges, and repair.

const db = require("database")
const doc_pool = require("document.schema_pool")
const doc_text = require("document.text")
const entity = require("entity")

const doc_links = {}

const LINK_PATTERN = "%[%[([^%[%]\n]+)%]%]"
const CONTEXT_MAX_LENGTH = 500
const SPREADING_ACTIVATION_FACTOR = 0.35
const RESYNC_LINKS_PAGE = 200
const CONNECTION_TITLE_SEPARATOR = doc_text.CONNECTION_TITLE_SEPARATOR

doc_links.LINK_PATTERN = LINK_PATTERN

function doc_links.parse_link_ref(raw_link)
    trimmed = string.gsub(raw_link, "^%s*(.-)%s*$", "%1")
    slash_pos = string.find(trimmed, "/", 1, true)
    if slash_pos != nil then
        return string.sub(trimmed, 1, slash_pos - 1), string.sub(trimmed, slash_pos + 1)
    end
    return nil, trimmed
end

function doc_links.resolve_link(db_path, subject, title)
    rows = db.query(db_path, string.format(
        "SELECT id, parent_id FROM document WHERE title = %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC;",
        db.quote(title)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    if subject == nil then
        return rows[1].id
    end
    for _, row in ipairs(rows) do
        if tonumber(row.parent_id) != nil then
            parent = entity.get(db_path, "document", tonumber(row.parent_id))
            if parent != nil and parent.title == subject then
                return row.id
            end
        end
    end
    return nil
end

function doc_links.resolve_link_text(db_path, raw_link)
    trimmed = string.gsub(raw_link, "^%s*(.-)%s*$", "%1")
    target_id = doc_links.resolve_link(db_path, nil, trimmed)
    if target_id != nil then
        return target_id
    end
    subject, title = doc_links.parse_link_ref(trimmed)
    if subject == nil then
        return nil
    end
    return doc_links.resolve_link(db_path, subject, title)
end

function doc_links.link_ref(db_path, document_id)
    doc = entity.get(db_path, "document", tonumber(document_id))
    if doc == nil or doc.title == nil or string.find(doc.title, "[%[%]\n]") != nil then
        return nil
    end
    if tonumber(doc_links.resolve_link_text(db_path, doc.title)) == tonumber(document_id) then
        return "[[" .. doc.title .. "]]"
    end
    if doc.parent_id == nil or doc.parent_id == "" then
        return nil
    end
    parent = entity.get(db_path, "document", tonumber(doc.parent_id))
    if parent == nil or string.find(parent.title, "[/%[%]\n]") != nil then
        return nil
    end
    if tonumber(doc_links.resolve_link_text(db_path, parent.title .. "/" .. doc.title)) == tonumber(document_id) then
        return "[[" .. parent.title .. "/" .. doc.title .. "]]"
    end
    return nil
end

function fuzzy_link_score(query_lower, candidate)
    cand_lower = string.lower(candidate)
    q_len = #query_lower
    c_len = #cand_lower
    qi = 1
    score = 0
    last_match = -2
    ti = 1
    while ti <= c_len and qi <= q_len do
        if string.byte(cand_lower, ti) == string.byte(query_lower, qi) then
            if ti == last_match + 1 then
                score = score + 3
            else
                score = score + 1
            end
            last_match = ti
            qi = qi + 1
        end
        ti = ti + 1
    end
    if qi <= q_len then
        return -1
    end
    at = string.find(cand_lower, query_lower, 1, true)
    if at == 1 then
        score = score + 2000
    elseif at != nil then
        score = score + 1000
    end
    return score
end

function doc_links.search_for_link(db_path, query_text, limit, exclude_id)
    max_results = tonumber(limit)
    if max_results == nil or max_results < 1 then
        max_results = 20
    end
    excluded = tonumber(exclude_id)
    rows = doc_pool.all_active(db_path)
    by_id = {}
    for _, row in ipairs(rows) do
        by_id[tonumber(row.id)] = row
    end
    query_str = ""
    if query_text != nil then
        query_str = string.gsub(tostring(query_text), "^%s*(.-)%s*$", "%1")
    end
    query_lower = string.lower(query_str)
    scored = {}
    for _, row in ipairs(rows) do
        doc_id = tonumber(row.id)
        if (excluded == nil or doc_id != excluded)
                and row.title != nil and row.title != ""
                and string.find(row.title, "[%[%]\n]") == nil then
            parent_title = nil
            if row.parent_id != nil and row.parent_id != "" then
                parent_row = by_id[tonumber(row.parent_id)]
                if parent_row != nil and parent_row.title != nil and parent_row.title != "" then
                    parent_title = parent_row.title
                end
            end
            score = 0
            if query_lower != "" then
                score = fuzzy_link_score(query_lower, row.title)
                if parent_title != nil then
                    path_score = fuzzy_link_score(query_lower, parent_title .. "/" .. row.title)
                    if path_score >= 0 then
                        adjusted = path_score - 200
                        if adjusted < 0 then
                            adjusted = 0
                        end
                        if score < 0 or adjusted > score then
                            score = adjusted
                        end
                    end
                end
            end
            if score >= 0 then
                table.insert(scored, {row = row, doc_id = doc_id, parent_title = parent_title, score = score})
            end
        end
    end
    if query_lower != "" then
        table.sort(scored, function(a, b)
            if a.score != b.score then
                return a.score > b.score
            end
            if a.row.title != b.row.title then
                return a.row.title < b.row.title
            end
            return a.doc_id < b.doc_id
        end)
    end
    results = {}
    for _, entry in ipairs(scored) do
        if #results >= max_results then
            break
        end
        ref = doc_links.link_ref(db_path, entry.doc_id)
        if ref != nil then
            table.insert(results, {
                id = entry.doc_id,
                title = entry.row.title,
                parent_title = entry.parent_title,
                link_ref = ref,
            })
        end
    end
    return results
end

function doc_links.clip_text(text)
    if text == nil then
        return nil
    end
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil
    end
    if #text <= CONTEXT_MAX_LENGTH then
        return text
    end
    cut = CONTEXT_MAX_LENGTH
    while cut > 1 and string.byte(text, cut + 1) != nil and string.byte(text, cut + 1) >= 0x80 and string.byte(text, cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return string.sub(text, 1, cut) .. "..."
end

function doc_links.clean_link_context(text)
    text = string.gsub(text, "^%s*>%s*", "")
    text = string.gsub(text, "^%s*#+%s+", "")
    text = string.gsub(text, "^%s*[-*+]%s+%[[ xX]%]%s+", "")
    text = string.gsub(text, "^%s*[-*+]%s+", "")
    text = string.gsub(text, "^%s*%d+[.)]%s+", "")
    text = string.gsub(text, "|", " ")
    text = string.gsub(text, "%s+", " ")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil
    end
    return text
end

function doc_links.link_context(content, raw_link)
    if content == nil then
        return nil
    end
    marker = "[[" .. raw_link .. "]]"
    start_pos = string.find(content, marker, 1, true)
    if start_pos == nil then
        return nil
    end

    line_start = start_pos
    while line_start > 1 and string.sub(content, line_start - 1, line_start - 1) != "\n" do
        line_start = line_start - 1
    end
    line_end = string.find(content, "\n", start_pos, true)
    if line_end == nil then
        line_end = #content
    else
        line_end = line_end - 1
    end
    line = string.sub(content, line_start, line_end)
    offset = start_pos - line_start + 1

    sentence_start = 1
    search_from = 1
    while true do
        boundary_start, boundary_end = string.find(line, "[%.!?]%s", search_from)
        if boundary_start == nil or boundary_start >= offset then
            break
        end
        sentence_start = boundary_end + 1
        search_from = boundary_end + 1
    end
    sentence_end = #line
    boundary_start = string.find(line, "[%.!?]%s", offset + #marker)
    if boundary_start != nil then
        sentence_end = boundary_start
    end
    sentence = doc_links.clean_link_context(string.sub(line, sentence_start, sentence_end))

    residue = ""
    if sentence != nil then
        residue = string.gsub(string.gsub(sentence, LINK_PATTERN, ""), "[%s%p]", "")
    end
    if #residue >= 3 then
        return doc_links.clip_text((string.gsub(sentence, LINK_PATTERN, "%1")))
    end

    heading = nil
    for heading_line in string.gmatch(string.sub(content, 1, line_start - 1), "[^\n]+") do
        heading_text = string.match(heading_line, "^%s*#+%s+(.-)%s*$")
        if heading_text != nil and heading_text != "" then
            heading = heading_text
        end
    end
    if heading == nil then
        return nil
    end
    return doc_links.clip_text("Listed under \"" .. string.gsub(heading, LINK_PATTERN, "%1") .. "\"")
end

function transform_inline_code_spans(text, fn)
    parts = {}
    len = string.len(text)
    pos = 1
    plain_start = 1
    while pos <= len do
        if string.byte(text, pos) == 96 then
            tick_end = pos
            while tick_end <= len and string.byte(text, tick_end) == 96 do
                tick_end = tick_end + 1
            end
            tick_len = tick_end - pos
            close_start = nil
            search_pos = tick_end
            blank_pos = string.find(text, "\n\n", tick_end, true)
            search_limit = len
            if blank_pos != nil then
                search_limit = blank_pos - 1
            end
            while search_pos <= search_limit do
                if string.byte(text, search_pos) == 96 then
                    run_end = search_pos
                    while run_end <= len and string.byte(text, run_end) == 96 do
                        run_end = run_end + 1
                    end
                    if (run_end - search_pos) == tick_len then
                        close_start = search_pos
                        break
                    end
                    search_pos = run_end
                else
                    search_pos = search_pos + 1
                end
            end
            if close_start != nil then
                if pos > plain_start then
                    table.insert(parts, fn(string.sub(text, plain_start, pos - 1)))
                end
                close_after = close_start + tick_len
                table.insert(parts, string.sub(text, pos, close_after - 1))
                pos = close_after
                plain_start = pos
            else
                pos = tick_end
            end
        else
            pos = pos + 1
        end
    end
    if plain_start <= len then
        table.insert(parts, fn(string.sub(text, plain_start, len)))
    end
    return table.concat(parts)
end

function doc_links.transform_outside_code(content, fn)
    if content == nil or content == "" then
        return ""
    end
    out_parts = {}
    prose_buf = {}
    in_fence = false
    fence_char = nil
    fence_len = 0

    len = string.len(content)
    line_start = 1
    while line_start <= len do
        nl = string.find(content, "\n", line_start, true)
        line_end = len
        if nl != nil then
            line_end = nl
        end
        line = string.sub(content, line_start, line_end)
        trimmed_line = string.gsub(line, "\r?\n$", "")

        if not in_fence then
            ticks = string.match(trimmed_line, "^%s*(```+)")
            if ticks == nil then
                ticks = string.match(trimmed_line, "^%s*(~~~+)")
            end
            if ticks != nil then
                if #prose_buf > 0 then
                    table.insert(out_parts, transform_inline_code_spans(table.concat(prose_buf), fn))
                    prose_buf = {}
                end
                in_fence = true
                fence_char = string.sub(ticks, 1, 1)
                fence_len = string.len(ticks)
                table.insert(out_parts, line)
            else
                table.insert(prose_buf, line)
            end
        else
            table.insert(out_parts, line)
            closing = string.match(trimmed_line, "^%s*(" .. fence_char .. "+)%s*$")
            if closing != nil and string.len(closing) >= fence_len then
                in_fence = false
                fence_char = nil
                fence_len = 0
            end
        end
        line_start = line_end + 1
    end

    if #prose_buf > 0 then
        table.insert(out_parts, transform_inline_code_spans(table.concat(prose_buf), fn))
    end
    return table.concat(out_parts)
end

function doc_links.extract_links(content)
    seen = {}
    ordered = {}
    function collect_segment_links(segment)
        for raw_link in string.gmatch(segment, LINK_PATTERN) do
            if seen[raw_link] == nil then
                seen[raw_link] = true
                table.insert(ordered, raw_link)
            end
        end
        return segment
    end
    doc_links.transform_outside_code(content, collect_segment_links)
    return ordered
end

function doc_links.upsert_link(db_path, from_id, to_id, link_text)
    link_hash = doc_pool.link_hash(link_text)
    rows = db.query(db_path, string.format(
        "SELECT id, to_document_id FROM document_link WHERE from_document_id = %d AND link_hash = %s;",
        tonumber(from_id), db.quote(link_hash)
    ))
    if rows == nil or #rows == 0 then
        db.exec(db_path, string.format(
            "INSERT INTO document_link (from_document_id, to_document_id, link_text, link_hash, created_at) VALUES (%d, %s, %s, %s, %s);",
            tonumber(from_id), db.literal(to_id), db.quote(link_text), db.quote(link_hash), db.now_expr(db_path)
        ))
        return
    end
    db.exec(db_path, string.format(
        "UPDATE document_link SET archived_at = NULL, to_document_id = %s WHERE id = %d;",
        db.literal(to_id), tonumber(rows[1].id)
    ))
end

function doc_links.sync_links(db_path, document_id, content)
    if content == nil then
        content = ""
    end
    ordered = doc_links.extract_links(content)
    seen = {}
    for _, raw_link in ipairs(ordered) do
        seen[raw_link] = true
    end

    existing = db.query(db_path, string.format(
        "SELECT id, link_text FROM document_link WHERE from_document_id = %d AND (archived_at IS NULL OR archived_at = '');",
        tonumber(document_id)
    ))
    if existing == nil then
        existing = {}
    end
    for _, row in ipairs(existing) do
        if seen[row.link_text] == nil then
            db.exec(db_path, string.format(
                "UPDATE document_link SET archived_at = %s WHERE id = %d;", db.now_expr(db_path), tonumber(row.id)
            ))
        end
    end

    for _, raw_link in ipairs(ordered) do
        doc_links.upsert_link(db_path, document_id, doc_links.resolve_link_text(db_path, raw_link), raw_link)
    end

    db.exec(db_path, string.format(
        "%s document_link_sync (document_id, content_hash) VALUES (%d, %s);",
        db.replace_into(db_path), tonumber(document_id), db.quote(doc_pool.link_sync_hash(content))
    ))
end

function doc_links.linked_neighbors(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT id, SUM(raw_strength) AS raw_strength FROM (
            SELECT to_document_id AS id, raw_strength FROM document_link WHERE from_document_id = %d AND to_document_id IS NOT NULL AND (archived_at IS NULL OR archived_at = '')
            UNION ALL
            SELECT from_document_id AS id, raw_strength FROM document_link WHERE to_document_id = %d AND (archived_at IS NULL OR archived_at = '')
        ) AS neighbor_links
        GROUP BY id;
    """, tonumber(document_id), tonumber(document_id)))
    if rows == nil then
        return {}
    end
    return rows
end

function doc_links.graph_edges(db_path)
    rows = db.query(db_path, """
        SELECT dl.from_document_id AS from_id, dl.to_document_id AS to_id, dl.raw_strength AS strength
        FROM document_link dl
        JOIN document d1 ON d1.id = dl.from_document_id
        JOIN document d2 ON d2.id = dl.to_document_id
        WHERE dl.to_document_id IS NOT NULL
          AND (dl.archived_at IS NULL OR dl.archived_at = '')
          AND (d1.archived_at IS NULL OR d1.archived_at = '') AND d1.merged_into IS NULL
          AND (d2.archived_at IS NULL OR d2.archived_at = '') AND d2.merged_into IS NULL;
    """)
    if rows == nil then
        return {}
    end
    edges = {}
    for _, row in ipairs(rows) do
        table.insert(edges, {from = tonumber(row.from_id), to = tonumber(row.to_id), strength = tonumber(row.strength)})
    end
    return edges
end

function doc_links.weighted_spreading_delta(base_delta, edge_strength, total_strength)
    if total_strength == nil or total_strength <= 0 then
        return 0
    end
    return (base_delta * SPREADING_ACTIVATION_FACTOR) * (tonumber(edge_strength) / total_strength)
end

function doc_links.links(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT 'out' AS direction, d.id AS id, d.title AS title, dl.link_text AS link_text,
               dl.raw_strength AS raw_strength, dl.created_at AS created_at, src.content AS holder_content
        FROM document_link dl
        JOIN document d ON d.id = dl.to_document_id
        JOIN document src ON src.id = dl.from_document_id
        WHERE dl.from_document_id = %d AND (dl.archived_at IS NULL OR dl.archived_at = '') AND (d.archived_at IS NULL OR d.archived_at = '')
        UNION ALL
        SELECT 'in' AS direction, d.id AS id, d.title AS title, dl.link_text AS link_text,
               dl.raw_strength AS raw_strength, dl.created_at AS created_at, d.content AS holder_content
        FROM document_link dl
        JOIN document d ON d.id = dl.from_document_id
        WHERE dl.to_document_id = %d AND (dl.archived_at IS NULL OR dl.archived_at = '') AND (d.archived_at IS NULL OR d.archived_at = '')
        ORDER BY title;
    """, tonumber(document_id), tonumber(document_id)))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.context = doc_links.link_context(row.holder_content, row.link_text)
        row.holder_content = nil
    end
    return rows
end

function doc_links.connection_draft(db_path, document_a_id, document_b_id, reason)
    ref_a = doc_links.link_ref(db_path, document_a_id)
    ref_b = doc_links.link_ref(db_path, document_b_id)
    if ref_a == nil or ref_b == nil then
        return nil
    end
    doc_a = entity.get(db_path, "document", tonumber(document_a_id))
    doc_b = entity.get(db_path, "document", tonumber(document_b_id))
    if reason == nil then
        reason = ""
    end
    return {
        title = doc_a.title .. CONNECTION_TITLE_SEPARATOR .. doc_b.title,
        content = ref_a .. " and " .. ref_b .. ": " .. reason,
        parent_id = doc_pool.ensure_knowledge_pool_folder(db_path),
    }
end

function doc_links.resolve_dangling_links(db_path)
    rows = db.query(db_path,
        "SELECT id, link_text FROM document_link WHERE to_document_id IS NULL AND (archived_at IS NULL OR archived_at = '');")
    if rows == nil then
        return
    end
    for _, row in ipairs(rows) do
        to_id = doc_links.resolve_link_text(db_path, row.link_text)
        if to_id != nil then
            db.exec(db_path, string.format(
                "UPDATE document_link SET to_document_id = %d WHERE id = %d AND to_document_id IS NULL;",
                tonumber(to_id), tonumber(row.id)
            ))
        end
    end
end

function doc_links.resync_links(db_path, document_id)
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    doc_links.sync_links(db_path, document_id, doc.content)
    return true
end

function doc_links.resync_all_links(db_path, all)
    stored = {}
    if all != true then
        rows = db.query(db_path, "SELECT document_id, content_hash FROM document_link_sync;")
        if rows == nil then
            rows = {}
        end
        for _, row in ipairs(rows) do
            stored[tonumber(row.document_id)] = row.content_hash
        end
    end
    resynced = 0
    unchanged = 0
    last_id = 0
    while true do
        page = db.query(db_path, string.format(
            "SELECT id, content FROM document WHERE (archived_at IS NULL OR archived_at = '') AND id > %d ORDER BY id ASC LIMIT %d;",
            last_id, RESYNC_LINKS_PAGE))
        if page == nil or #page == 0 then
            break
        end
        for _, row in ipairs(page) do
            id = tonumber(row.id)
            content = doc_pool.sql_null_to_nil(row.content)
            if stored[id] != nil and stored[id] == doc_pool.link_sync_hash(content) then
                unchanged = unchanged + 1
            else
                doc_links.sync_links(db_path, id, content)
                resynced = resynced + 1
            end
            last_id = id
        end
    end
    doc_links.resolve_dangling_links(db_path)
    return resynced, unchanged
end

return doc_links
